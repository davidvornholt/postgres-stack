# Postgres stack

Postgres Stack is a reusable Docker Compose starter that runs two independent PostgreSQL 18 instances in one project:

- `postgres-prod` on host port `5432`
- `postgres-dev` on host port `5433`

It is designed for robust single-host use with persistent storage, health checks, restart policies, safe network defaults, and optional shared-network access for container-to-container connectivity.

## What you get

- PostgreSQL 18 pinned in Compose
- Separate production and development database instances
- Named Docker volumes for persistent data
- Health checks with `pg_isready`
- `restart: unless-stopped` for both services
- Configurable host bind addresses with `127.0.0.1` as the default
- Optional shared external Docker network support, either internal-only or combined with localhost access

## Quick start

1. Copy the environment template:

   ```bash
   cp .env.example .env
   ```

2. Update the passwords in `.env`.

3. Start both databases:

   ```bash
   docker compose --profile prod --profile dev up -d
   ```

4. Check status:

   ```bash
   docker compose ps
   ```

## Selective startup

The project includes Compose profiles so you can start one instance by profile when needed.

Start only production:

```bash
docker compose --profile prod up -d
```

Start only development:

```bash
docker compose --profile dev up -d
```

You can also target service names directly, for example `docker compose up -d postgres-prod postgres-dev`, but this README recommends enabling profiles instead. Profiles match how the stack is organized, keep the commands symmetric with `down`, and continue to work cleanly if more services are later added to either profile.

Stop everything:

```bash
docker compose --profile prod --profile dev down
```

Remove containers and volumes:

```bash
docker compose --profile prod --profile dev down -v
```

## Networking modes

By default, this stack publishes PostgreSQL only to `127.0.0.1` on the host:

```bash
docker compose --profile prod --profile dev up -d
```

If you also want other Docker workloads on the same host to reach the databases by service name, add the shared-network override on top of the base Compose file:

```bash
docker network create postgres-shared
docker compose -f compose.yaml -f compose.shared-network.yaml --profile prod --profile dev up -d
```

In this combined mode:

- the host can still use `127.0.0.1:5432` and `127.0.0.1:5433`
- containers on the shared external network can use `postgres-prod:5432` and `postgres-dev:5432`

If you want the databases reachable only from other Docker containers and not from the host machine at all, use the shared-network file by itself.

## Shared-network-only mode

Use this mode when you want container-to-container access on the shared external network without publishing PostgreSQL ports to the host.

1. Create the external Docker network once:

   ```bash
   docker network create postgres-shared
   ```

2. Set the network name in `.env` if you do not want the default:

   ```dotenv
   POSTGRES_SHARED_NETWORK=postgres-shared
   ```

3. Start the stack with only the shared-network file:

   ```bash
   docker compose -f compose.shared-network.yaml --profile prod --profile dev up -d
   ```

   You can also start the same services by naming them explicitly, for example `docker compose -f compose.shared-network.yaml up -d postgres-prod postgres-dev`. The recommended form is enabling both profiles, because both database services are profile-gated and the profile-based command better reflects the intended prod-plus-dev startup mode.

In this mode, Docker does not publish PostgreSQL ports to the host, so `127.0.0.1:5432` and `127.0.0.1:5433` are not available.

To stop this mode later, use the same file combination:

```bash
docker compose -f compose.shared-network.yaml --profile prod --profile dev down
```

### Connecting other Docker workloads

Other Docker workloads on the same host can reach these databases by joining the same external Docker network. This applies to both shared-network-only mode and the combined mode above.

For another Docker Compose project, add the shared network as an external network:

```yaml
services:
   app:
      image: ghcr.io/example/app:latest
      networks:
         - postgres-shared

networks:
   postgres-shared:
      external: true
      name: postgres-shared
```

If you use a custom network name, replace `postgres-shared` with the value of `POSTGRES_SHARED_NETWORK`.

Once attached, connect to either database by service name on port `5432`:

- `postgres-prod:5432`
- `postgres-dev:5432`

For example:

```dotenv
DATABASE_URL=postgresql://postgres:change-me-prod@postgres-prod:5432/postgres
```

## Configuration

Set these values in `.env`:

| Variable | Purpose | Default |
| --- | --- | --- |
| `POSTGRES_PROD_BIND_HOST` | Host/IP for the production port binding | `127.0.0.1` |
| `POSTGRES_DEV_BIND_HOST` | Host/IP for the development port binding | `127.0.0.1` |
| `POSTGRES_PROD_PORT` | Published production port | `5432` |
| `POSTGRES_DEV_PORT` | Published development port | `5433` |
| `POSTGRES_SHARED_NETWORK` | External Docker network name for shared-network modes | `postgres-shared` |
| `POSTGRES_PROD_USER` | Production database user | `postgres` |
| `POSTGRES_DEV_USER` | Development database user | `postgres` |
| `POSTGRES_PROD_PASSWORD` | Production database password | `change-me-prod` |
| `POSTGRES_DEV_PASSWORD` | Development database password | `change-me-dev` |

## Connection details

From the host machine:

- Production: `postgresql://POSTGRES_PROD_USER:POSTGRES_PROD_PASSWORD@POSTGRES_PROD_BIND_HOST:POSTGRES_PROD_PORT/postgres`
- Development: `postgresql://POSTGRES_DEV_USER:POSTGRES_DEV_PASSWORD@POSTGRES_DEV_BIND_HOST:POSTGRES_DEV_PORT/postgres`

Examples with default host bindings:

```text
postgresql://postgres:change-me-prod@127.0.0.1:5432/postgres
postgresql://postgres:change-me-dev@127.0.0.1:5433/postgres
```

The stack does not create an application-specific database name for you. Users can create whatever databases they need after startup with standard PostgreSQL tooling.

From another container in the same Compose project, connect to the service name on internal port `5432`:

- `postgres-prod:5432`
- `postgres-dev:5432`

From another container on the shared external network, use the same service names when you start the stack with `compose.shared-network.yaml`, either by itself or layered with `compose.yaml`:

- `postgres-prod:5432`
- `postgres-dev:5432`

For example, if another Compose project joins the same external network, it can connect with URLs like:

```text
postgresql://postgres:change-me-prod@postgres-prod:5432/postgres
postgresql://postgres:change-me-dev@postgres-dev:5432/postgres
```

## Changing the bind host

By default, both PostgreSQL ports are only reachable from the same machine.

To expose an instance on a server's private IP, set the bind host explicitly in `.env`, for example:

```dotenv
POSTGRES_PROD_BIND_HOST=192.168.1.50
POSTGRES_DEV_BIND_HOST=192.168.1.50
```

Use this only when you intend to accept connections from other machines on your network, and make sure your firewall rules and passwords are appropriate for that exposure.

If you use only `compose.shared-network.yaml`, these bind host settings and host ports are ignored because the services are no longer published to the host.

If you layer `compose.shared-network.yaml` on top of `compose.yaml`, the host bindings still apply and the services also join the shared external network.

## Persistence

Data is stored in named Docker volumes:

- `postgres_prod_data`
- `postgres_dev_data`

With PostgreSQL 18, the volumes are mounted at `/var/lib/postgresql` to match the official image's versioned on-disk layout.

Recreating containers does not remove database contents. Use `docker compose down -v` only when you intentionally want to delete all stored data for both instances.

## Operational notes

- This project is a production-oriented Compose starter, not a high-availability PostgreSQL cluster.
- It does not include replication, automated backups, failover, or secrets management.
- If you expose the databases beyond `127.0.0.1`, replace the default passwords before starting the stack.
- Any mode that includes `compose.shared-network.yaml` assumes the external Docker network already exists before `docker compose up`.
