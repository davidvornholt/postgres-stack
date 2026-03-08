# Postgres Stack

Postgres Stack is a reusable Docker Compose starter that runs two independent PostgreSQL 18 instances in one project:

- `postgres-prod` on host port `5423`
- `postgres-dev` on host port `5433`

It is designed for robust single-host use with persistent storage, health checks, restart policies, safe network defaults, and an opt-in internal-only shared-network mode.

## What You Get

- PostgreSQL 18 pinned in Compose
- Separate production and development database instances
- Named Docker volumes for persistent data
- Health checks with `pg_isready`
- `restart: unless-stopped` for both services
- Configurable host bind addresses with `127.0.0.1` as the default
- Optional internal-only mode on a shared external Docker network
- Optional declarative bootstrap manifests for extra roles and databases

## Quick Start

1. Copy the environment template:

   ```bash
   cp .env.example .env
   ```

2. Update the passwords in `.env`.

3. Optionally add declarative bootstrap manifests under `bootstrap/prod` or `bootstrap/dev` if you want extra roles or databases on first startup.

4. Start both databases:

   ```bash
   docker compose up -d postgres-prod postgres-dev
   ```

5. Check status:

   ```bash
   docker compose ps
   ```

## Selective Startup

The project includes Compose profiles so you can start one instance by profile when needed.

Start only production:

```bash
docker compose --profile prod up -d postgres-prod
```

Start only development:

```bash
docker compose --profile dev up -d postgres-dev
```

Stop everything:

```bash
docker compose --profile prod --profile dev down
```

Remove containers and volumes:

```bash
docker compose --profile prod --profile dev down -v
```

## Shared-Network Mode

If you want the databases reachable only from other Docker containers and not from the host machine at all, use the dedicated shared-network Compose file.

1. Create the external Docker network once:

   ```bash
   docker network create postgres-shared
   ```

2. Set the network name in `.env` if you do not want the default:

   ```dotenv
   POSTGRES_SHARED_NETWORK=postgres-shared
   ```

3. Start the stack with the shared-network file:

   ```bash
   docker compose -f compose.shared-network.yaml up -d postgres-prod postgres-dev
   ```

In this mode, Docker does not publish PostgreSQL ports to the host, so `127.0.0.1:5423` and `127.0.0.1:5433` are not available.

To stop this mode later, use the same file combination:

```bash
docker compose -f compose.shared-network.yaml --profile prod --profile dev down
```

## Configuration

Set these values in `.env`:

| Variable | Purpose | Default |
| --- | --- | --- |
| `POSTGRES_PROD_BIND_HOST` | Host/IP for the production port binding | `127.0.0.1` |
| `POSTGRES_DEV_BIND_HOST` | Host/IP for the development port binding | `127.0.0.1` |
| `POSTGRES_PROD_PORT` | Published production port | `5423` |
| `POSTGRES_DEV_PORT` | Published development port | `5433` |
| `POSTGRES_SHARED_NETWORK` | External Docker network name for internal-only mode | `postgres-shared` |
| `POSTGRES_PROD_USER` | Production database user | `postgres` |
| `POSTGRES_DEV_USER` | Development database user | `postgres` |
| `POSTGRES_PROD_PASSWORD` | Production database password | `change-me-prod` |
| `POSTGRES_DEV_PASSWORD` | Development database password | `change-me-dev` |

Extra roles and databases are configured with manifest files, not additional environment variables:

- Production roles: `bootstrap/prod/roles/*.conf`
- Production databases: `bootstrap/prod/databases/*.conf`
- Development roles: `bootstrap/dev/roles/*.conf`
- Development databases: `bootstrap/dev/databases/*.conf`

## Connection Details

From the host machine:

- Production: `postgresql://POSTGRES_PROD_USER:POSTGRES_PROD_PASSWORD@POSTGRES_PROD_BIND_HOST:POSTGRES_PROD_PORT/postgres`
- Development: `postgresql://POSTGRES_DEV_USER:POSTGRES_DEV_PASSWORD@POSTGRES_DEV_BIND_HOST:POSTGRES_DEV_PORT/postgres`

Examples with default host bindings:

```text
postgresql://postgres:change-me-prod@127.0.0.1:5423/postgres
postgresql://postgres:change-me-dev@127.0.0.1:5433/postgres
```

The stack does not create an application-specific database name for you. Users can create whatever databases they need after startup with standard PostgreSQL tooling.

From another container in the same Compose project, connect to the service name on internal port `5432`:

- `postgres-prod:5432`
- `postgres-dev:5432`

From another container on the shared external network, use the same service names:

- `postgres-prod:5432`
- `postgres-dev:5432`

For example, if another Compose project joins the same external network, it can connect with URLs like:

```text
postgresql://postgres:change-me-prod@postgres-prod:5432/postgres
postgresql://postgres:change-me-dev@postgres-dev:5432/postgres
```

## Declarative Bootstrap

This stack can optionally create extra PostgreSQL roles and databases during cluster initialization by reading manifest files from the `bootstrap/` directory tree.

Key behavior:

- The bootstrap step is optional. Empty manifest directories are a no-op.
- Manifests are processed only when PostgreSQL initializes a fresh data directory. Restarting an existing container does not re-run them.
- Role manifests are applied before database manifests, so database owners can be declared as extra roles in the same instance.
- The bootstrap script validates keys and basic identifier safety before issuing SQL.
- A bootstrap failure clears the incomplete data directory so the container does not continue with a partially initialized cluster.

Production note:

- Keep secret material out of Git. The repo ignores `bootstrap/prod/secrets/*` and `bootstrap/dev/secrets/*`.
- For production roles, prefer `ROLE_PASSWORD_FILE` over inline `ROLE_PASSWORD`.

### Role Manifest Format

Create one file per extra role in `bootstrap/<instance>/roles/`, for example `bootstrap/prod/roles/app.conf`:

```dotenv
ROLE_NAME=app_prod
ROLE_PASSWORD_FILE=secrets/app_prod.password
ROLE_LOGIN=true
ROLE_SUPERUSER=false
ROLE_CREATEDB=false
ROLE_CREATEROLE=false
ROLE_REPLICATION=false
ROLE_BYPASSRLS=false
```

Supported keys:

- `ROLE_NAME` (required)
- `ROLE_PASSWORD` or `ROLE_PASSWORD_FILE` for `LOGIN` roles
- `ROLE_LOGIN` default `true`
- `ROLE_SUPERUSER` default `false`
- `ROLE_CREATEDB` default `false`
- `ROLE_CREATEROLE` default `false`
- `ROLE_REPLICATION` default `false`
- `ROLE_BYPASSRLS` default `false`

Behavior:

- Login roles must provide either `ROLE_PASSWORD` or `ROLE_PASSWORD_FILE`.
- `ROLE_PASSWORD_FILE` is resolved relative to the mounted instance bootstrap directory, so `secrets/app_prod.password` means `bootstrap/prod/secrets/app_prod.password`.
- The bootstrap superuser from `POSTGRES_*_USER` is intentionally managed only through `.env`, not through extra-role manifests.

### Database Manifest Format

Create one file per extra database in `bootstrap/<instance>/databases/`, for example `bootstrap/prod/databases/app.conf`:

```dotenv
DATABASE_NAME=app_prod
DATABASE_OWNER=app_prod
DATABASE_ENCODING=UTF8
```

Supported keys:

- `DATABASE_NAME` (required)
- `DATABASE_OWNER` default `POSTGRES_*_USER`
- `DATABASE_TEMPLATE` optional
- `DATABASE_ENCODING` optional
- `DATABASE_LC_COLLATE` optional
- `DATABASE_LC_CTYPE` optional

Behavior:

- The named owner must already exist, either as the bootstrap user or from a role manifest.
- `DATABASE_TEMPLATE`, `DATABASE_ENCODING`, `DATABASE_LC_COLLATE`, and `DATABASE_LC_CTYPE` are creation-time settings. If the database already exists at bootstrap time, they are not reapplied.
- Reserved database names such as `postgres`, `template0`, and `template1` are rejected.

### Example Layout

```text
bootstrap/
  prod/
    roles/
      app.conf
    databases/
      app.conf
    secrets/
      app_prod.password
  dev/
    roles/
      app.conf
    databases/
      app.conf
```

Working examples are included under `bootstrap/examples/`.

### Applying Changes Later

Manifest changes do not reconcile into an already-initialized data volume. To apply a changed bootstrap manifest:

1. Use a fresh data volume for that instance, or
2. Apply the equivalent SQL change manually to the running database.

This first-start-only behavior is deliberate because automatically reconciling live roles and databases can create production surprises.

## Changing the Bind Host

By default, both PostgreSQL ports are only reachable from the same machine.

To expose an instance on a server's private IP, set the bind host explicitly in `.env`, for example:

```dotenv
POSTGRES_PROD_BIND_HOST=192.168.1.50
POSTGRES_DEV_BIND_HOST=192.168.1.50
```

Use this only when you intend to accept connections from other machines on your network, and make sure your firewall rules and passwords are appropriate for that exposure.

If you use `compose.shared-network.yaml`, these bind host settings and host ports are ignored because the services are no longer published to the host.

## Persistence

Data is stored in named Docker volumes:

- `postgres_prod_data`
- `postgres_dev_data`

With PostgreSQL 18, the volumes are mounted at `/var/lib/postgresql` to match the official image's versioned on-disk layout.

Recreating containers does not remove database contents. Use `docker compose down -v` only when you intentionally want to delete all stored data for both instances.

## Operational Notes

- This project is a production-oriented Compose starter, not a high-availability PostgreSQL cluster.
- It does not include replication, automated backups, failover, or secrets management.
- If you expose the databases beyond `127.0.0.1`, replace the default passwords before starting the stack.
- Shared-network mode assumes the external Docker network already exists before `docker compose up`.
