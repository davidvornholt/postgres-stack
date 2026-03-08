#!/usr/bin/env bash
set -Eeuo pipefail

BOOTSTRAP_ROOT="${POSTGRES_STACK_BOOTSTRAP_DIR:-/postgres-stack/bootstrap}"
ROLE_DIR="${BOOTSTRAP_ROOT}/roles"
DATABASE_DIR="${BOOTSTRAP_ROOT}/databases"
BOOTSTRAP_CLEANED_UP_ON_ERROR="false"

log() {
  printf '[postgres-stack bootstrap] %s\n' "$*"
}

fail() {
  log "ERROR: $*"
  cleanup_incomplete_cluster
  exit 1
}

cleanup_incomplete_cluster() {
  if [[ "$BOOTSTRAP_CLEANED_UP_ON_ERROR" == "true" ]]; then
    return 0
  fi

  if [[ -z "${PGDATA:-}" || ! -d "${PGDATA:-}" ]]; then
    return 0
  fi

  case "$PGDATA" in
    /var/lib/postgresql/*)
      ;;
    *)
      log "Refusing to remove unexpected PGDATA path: ${PGDATA}"
      return 0
      ;;
  esac

  BOOTSTRAP_CLEANED_UP_ON_ERROR="true"
  log "Cleaning up incomplete cluster contents at ${PGDATA} after bootstrap failure"
  pg_ctl -D "$PGDATA" -m immediate stop >/dev/null 2>&1 || true
  find "$PGDATA" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
}

on_error() {
  local exit_code=$?
  cleanup_incomplete_cluster
  return "$exit_code"
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

parse_bool() {
  local key="$1"
  local value
  value="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"

  case "$value" in
    true|yes|1)
      printf 'true'
      ;;
    false|no|0)
      printf 'false'
      ;;
    *)
      fail "Invalid boolean for ${key}: ${2}"
      ;;
  esac
}

validate_name() {
  local kind="$1"
  local value="$2"

  [[ -n "$value" ]] || fail "${kind} name cannot be empty"
  [[ ${#value} -le 63 ]] || fail "${kind} name '${value}' exceeds PostgreSQL's 63-byte identifier limit"
  [[ "$value" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || fail "${kind} name '${value}' contains unsupported characters"
  [[ "$value" != pg_* ]] || fail "${kind} name '${value}' cannot start with the reserved 'pg_' prefix"
}

validate_role_name() {
  local value="$1"

  validate_name "Role" "$value"
  [[ "$value" != "$POSTGRES_USER" ]] || fail "Role '${value}' matches POSTGRES_USER; manage the bootstrap superuser through POSTGRES_USER instead"
}

validate_database_name() {
  local value="$1"

  validate_name "Database" "$value"

  case "$value" in
    postgres|template0|template1)
      fail "Database name '${value}' is reserved"
      ;;
  esac
}

validate_setting_name() {
  local key="$1"
  local value="$2"

  [[ -n "$value" ]] || fail "${key} cannot be empty"
  [[ "$value" =~ ^[A-Za-z0-9_.-]+$ ]] || fail "${key} value '${value}' contains unsupported characters"
}

resolve_secret_file() {
  local relative_path="$1"
  local full_path

  [[ -n "$relative_path" ]] || fail "ROLE_PASSWORD_FILE cannot be empty"
  [[ "$relative_path" != /* ]] || fail "ROLE_PASSWORD_FILE must be relative to ${BOOTSTRAP_ROOT}"
  [[ "$relative_path" != *".."* ]] || fail "ROLE_PASSWORD_FILE cannot contain '..'"

  full_path="${BOOTSTRAP_ROOT}/${relative_path}"
  [[ -f "$full_path" ]] || fail "Password file '${relative_path}' does not exist"
  [[ -r "$full_path" ]] || fail "Password file '${relative_path}' is not readable"

  printf '%s' "$full_path"
}

ensure_allowed_keys() {
  local manifest_path="$1"
  local -n target="$2"
  shift 2
  local allowed_key
  local found

  for allowed_key in "${!target[@]}"; do
    found="false"
    for expected_key in "$@"; do
      if [[ "$allowed_key" == "$expected_key" ]]; then
        found="true"
        break
      fi
    done

    [[ "$found" == "true" ]] || fail "Unexpected key '${allowed_key}' in ${manifest_path}"
  done
}

parse_manifest() {
  local manifest_path="$1"
  local prefix="$2"
  local -n target="$3"
  local line_number=0

  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    local line trimmed key value
    line_number=$((line_number + 1))
    line="${raw_line%$'\r'}"
    trimmed="$(trim "$line")"

    [[ -n "$trimmed" ]] || continue
    [[ "${trimmed:0:1}" != "#" ]] || continue
    [[ "$trimmed" == *=* ]] || fail "Invalid line in ${manifest_path}:${line_number}; expected KEY=VALUE"

    key="$(trim "${trimmed%%=*}")"
    value="$(trim "${trimmed#*=}")"

    if [[ "$value" =~ ^\".*\"$ ]] || [[ "$value" =~ ^\'.*\'$ ]]; then
      value="${value:1:${#value}-2}"
    fi

    [[ "$key" == "${prefix}"* ]] || fail "Unexpected key '${key}' in ${manifest_path}; expected keys starting with ${prefix}"
    [[ -z "${target[$key]+x}" ]] || fail "Duplicate key '${key}' in ${manifest_path}"

    target["$key"]="$value"
  done < "$manifest_path"
}

psql_exec() {
  psql --username "$POSTGRES_USER" --dbname postgres --set ON_ERROR_STOP=1 "$@"
}

role_exists() {
  local role_name="$1"
  local result

  result="$(
    psql_exec \
      --tuples-only \
      --no-align \
      --set=role_name="$role_name" \
      <<'SQL'
SELECT 1
FROM pg_catalog.pg_roles
WHERE rolname = :'role_name';
SQL
  )"
  [[ "$result" == "1" ]]
}

database_exists() {
  local database_name="$1"
  local result

  result="$(
    psql_exec \
      --tuples-only \
      --no-align \
      --set=database_name="$database_name" \
      <<'SQL'
SELECT 1
FROM pg_database
WHERE datname = :'database_name';
SQL
  )"
  [[ "$result" == "1" ]]
}

apply_role_manifest() {
  local manifest_path="$1"
  declare -A role=()
  local role_name role_password password_file
  local login superuser createdb createrole replication bypassrls
  local login_sql superuser_sql createdb_sql createrole_sql replication_sql bypassrls_sql role_options
  local action

  parse_manifest "$manifest_path" "ROLE_" role
  ensure_allowed_keys "$manifest_path" role \
    ROLE_NAME \
    ROLE_PASSWORD \
    ROLE_PASSWORD_FILE \
    ROLE_LOGIN \
    ROLE_SUPERUSER \
    ROLE_CREATEDB \
    ROLE_CREATEROLE \
    ROLE_REPLICATION \
    ROLE_BYPASSRLS

  role_name="${role[ROLE_NAME]:-}"
  role_password="${role[ROLE_PASSWORD]:-}"
  password_file="${role[ROLE_PASSWORD_FILE]:-}"
  login="$(parse_bool ROLE_LOGIN "${role[ROLE_LOGIN]:-true}")"
  superuser="$(parse_bool ROLE_SUPERUSER "${role[ROLE_SUPERUSER]:-false}")"
  createdb="$(parse_bool ROLE_CREATEDB "${role[ROLE_CREATEDB]:-false}")"
  createrole="$(parse_bool ROLE_CREATEROLE "${role[ROLE_CREATEROLE]:-false}")"
  replication="$(parse_bool ROLE_REPLICATION "${role[ROLE_REPLICATION]:-false}")"
  bypassrls="$(parse_bool ROLE_BYPASSRLS "${role[ROLE_BYPASSRLS]:-false}")"

  [[ -n "$role_name" ]] || fail "Manifest ${manifest_path} is missing ROLE_NAME"
  validate_role_name "$role_name"

  if [[ -n "$role_password" && -n "$password_file" ]]; then
    fail "Manifest ${manifest_path} sets both ROLE_PASSWORD and ROLE_PASSWORD_FILE"
  fi

  if [[ -n "$password_file" ]]; then
    role_password="$(<"$(resolve_secret_file "$password_file")")"
  fi

  if [[ "$login" == "true" && -z "$role_password" ]]; then
    fail "Manifest ${manifest_path} defines a LOGIN role without ROLE_PASSWORD or ROLE_PASSWORD_FILE"
  fi

  if [[ "$login" == "false" && -n "$role_password" ]]; then
    fail "Manifest ${manifest_path} sets a password for a NOLOGIN role"
  fi

  login_sql="NOLOGIN"
  superuser_sql="NOSUPERUSER"
  createdb_sql="NOCREATEDB"
  createrole_sql="NOCREATEROLE"
  replication_sql="NOREPLICATION"
  bypassrls_sql="NOBYPASSRLS"

  [[ "$login" == "true" ]] && login_sql="LOGIN"
  [[ "$superuser" == "true" ]] && superuser_sql="SUPERUSER"
  [[ "$createdb" == "true" ]] && createdb_sql="CREATEDB"
  [[ "$createrole" == "true" ]] && createrole_sql="CREATEROLE"
  [[ "$replication" == "true" ]] && replication_sql="REPLICATION"
  [[ "$bypassrls" == "true" ]] && bypassrls_sql="BYPASSRLS"

  role_options="${login_sql} ${superuser_sql} ${createdb_sql} ${createrole_sql} ${replication_sql} ${bypassrls_sql}"
  action="created"
  role_exists "$role_name" && action="updated"

  if [[ "$login" == "true" ]]; then
    psql_exec \
      --set=role_name="$role_name" \
      --set=role_options="$role_options" \
      --set=role_password="$role_password" <<'SQL'
SELECT CASE
  WHEN EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = :'role_name')
    THEN format('ALTER ROLE %I WITH %s PASSWORD %L', :'role_name', :'role_options', :'role_password')
  ELSE format('CREATE ROLE %I WITH %s PASSWORD %L', :'role_name', :'role_options', :'role_password')
END;
\gexec
SQL
  else
    psql_exec \
      --set=role_name="$role_name" \
      --set=role_options="$role_options" <<'SQL'
SELECT CASE
  WHEN EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = :'role_name')
    THEN format('ALTER ROLE %I WITH %s', :'role_name', :'role_options')
  ELSE format('CREATE ROLE %I WITH %s', :'role_name', :'role_options')
END;
\gexec
SQL
  fi

  log "Role ${action}: ${role_name}"
}

apply_database_manifest() {
  local manifest_path="$1"
  declare -A database=()
  local database_name database_owner database_template database_encoding database_lc_collate database_lc_ctype
  local action create_settings_applied database_already_exists

  parse_manifest "$manifest_path" "DATABASE_" database
  ensure_allowed_keys "$manifest_path" database \
    DATABASE_NAME \
    DATABASE_OWNER \
    DATABASE_TEMPLATE \
    DATABASE_ENCODING \
    DATABASE_LC_COLLATE \
    DATABASE_LC_CTYPE

  database_name="${database[DATABASE_NAME]:-}"
  database_owner="${database[DATABASE_OWNER]:-$POSTGRES_USER}"
  database_template="${database[DATABASE_TEMPLATE]:-}"
  database_encoding="${database[DATABASE_ENCODING]:-}"
  database_lc_collate="${database[DATABASE_LC_COLLATE]:-}"
  database_lc_ctype="${database[DATABASE_LC_CTYPE]:-}"

  [[ -n "${database[DATABASE_NAME]:-}" ]] || fail "Manifest ${manifest_path} is missing DATABASE_NAME"

  validate_database_name "$database_name"
  validate_name "Role" "$database_owner"
  [[ "$database_owner" == "$POSTGRES_USER" ]] || role_exists "$database_owner" || fail "Database owner '${database_owner}' in ${manifest_path} does not exist"

  [[ -z "$database_template" ]] || validate_setting_name "DATABASE_TEMPLATE" "$database_template"
  [[ -z "$database_encoding" ]] || validate_setting_name "DATABASE_ENCODING" "$database_encoding"
  [[ -z "$database_lc_collate" ]] || validate_setting_name "DATABASE_LC_COLLATE" "$database_lc_collate"
  [[ -z "$database_lc_ctype" ]] || validate_setting_name "DATABASE_LC_CTYPE" "$database_lc_ctype"

  database_already_exists="false"
  database_exists "$database_name" && database_already_exists="true"
  action="created"
  create_settings_applied="yes"
  [[ "$database_already_exists" == "true" ]] && action="updated"
  [[ "$database_already_exists" == "true" ]] && create_settings_applied="no"

  psql_exec \
    --set=database_name="$database_name" \
    --set=database_owner="$database_owner" \
    --set=database_template="$database_template" \
    --set=database_encoding="$database_encoding" \
    --set=database_lc_collate="$database_lc_collate" \
    --set=database_lc_ctype="$database_lc_ctype" <<'SQL'
SELECT CASE
  WHEN EXISTS (SELECT 1 FROM pg_database WHERE datname = :'database_name')
    THEN NULL
  WHEN :'database_template' <> '' AND :'database_encoding' <> '' AND :'database_lc_collate' <> '' AND :'database_lc_ctype' <> ''
    THEN format(
      'CREATE DATABASE %I OWNER %I TEMPLATE %I ENCODING %L LC_COLLATE %L LC_CTYPE %L',
      :'database_name',
      :'database_owner',
      :'database_template',
      :'database_encoding',
      :'database_lc_collate',
      :'database_lc_ctype'
    )
  WHEN :'database_template' <> '' AND :'database_encoding' <> '' AND :'database_lc_collate' <> ''
    THEN format(
      'CREATE DATABASE %I OWNER %I TEMPLATE %I ENCODING %L LC_COLLATE %L',
      :'database_name',
      :'database_owner',
      :'database_template',
      :'database_encoding',
      :'database_lc_collate'
    )
  WHEN :'database_template' <> '' AND :'database_encoding' <> '' AND :'database_lc_ctype' <> ''
    THEN format(
      'CREATE DATABASE %I OWNER %I TEMPLATE %I ENCODING %L LC_CTYPE %L',
      :'database_name',
      :'database_owner',
      :'database_template',
      :'database_encoding',
      :'database_lc_ctype'
    )
  WHEN :'database_template' <> '' AND :'database_lc_collate' <> '' AND :'database_lc_ctype' <> ''
    THEN format(
      'CREATE DATABASE %I OWNER %I TEMPLATE %I LC_COLLATE %L LC_CTYPE %L',
      :'database_name',
      :'database_owner',
      :'database_template',
      :'database_lc_collate',
      :'database_lc_ctype'
    )
  WHEN :'database_encoding' <> '' AND :'database_lc_collate' <> '' AND :'database_lc_ctype' <> ''
    THEN format(
      'CREATE DATABASE %I OWNER %I ENCODING %L LC_COLLATE %L LC_CTYPE %L',
      :'database_name',
      :'database_owner',
      :'database_encoding',
      :'database_lc_collate',
      :'database_lc_ctype'
    )
  WHEN :'database_template' <> ''
    THEN format('CREATE DATABASE %I OWNER %I TEMPLATE %I', :'database_name', :'database_owner', :'database_template')
  WHEN :'database_encoding' <> ''
    THEN format('CREATE DATABASE %I OWNER %I ENCODING %L', :'database_name', :'database_owner', :'database_encoding')
  WHEN :'database_lc_collate' <> ''
    THEN format('CREATE DATABASE %I OWNER %I LC_COLLATE %L', :'database_name', :'database_owner', :'database_lc_collate')
  WHEN :'database_lc_ctype' <> ''
    THEN format('CREATE DATABASE %I OWNER %I LC_CTYPE %L', :'database_name', :'database_owner', :'database_lc_ctype')
  ELSE format('CREATE DATABASE %I OWNER %I', :'database_name', :'database_owner')
END;
\gexec

SELECT format('ALTER DATABASE %I OWNER TO %I', :'database_name', :'database_owner')
WHERE EXISTS (
  SELECT 1
  FROM pg_database
  WHERE datname = :'database_name'
    AND pg_catalog.pg_get_userbyid(datdba) <> :'database_owner'
);
\gexec
SQL

  log "Database ${action}: ${database_name} (owner: ${database_owner})"
  if [[ "$create_settings_applied" == "no" && ( -n "$database_template" || -n "$database_encoding" || -n "$database_lc_collate" || -n "$database_lc_ctype" ) ]]; then
    log "Database ${database_name} already existed; creation-only settings were not reapplied"
  fi
}

main() {
  trap on_error ERR
  shopt -s nullglob
  local role_files=("${ROLE_DIR}"/*.conf)
  local database_files=("${DATABASE_DIR}"/*.conf)

  if [[ ! -d "$ROLE_DIR" && ! -d "$DATABASE_DIR" ]]; then
    log "No bootstrap directory mounted at ${BOOTSTRAP_ROOT}; skipping extra roles and databases"
    return 0
  fi

  if [[ ${#role_files[@]} -eq 0 && ${#database_files[@]} -eq 0 ]]; then
    log "No role or database manifests found under ${BOOTSTRAP_ROOT}; skipping"
    return 0
  fi

  log "Applying declarative bootstrap manifests from ${BOOTSTRAP_ROOT}"

  local manifest_path
  for manifest_path in "${role_files[@]}"; do
    apply_role_manifest "$manifest_path"
  done

  for manifest_path in "${database_files[@]}"; do
    apply_database_manifest "$manifest_path"
  done

  log "Bootstrap manifest processing complete"
}

main "$@"
