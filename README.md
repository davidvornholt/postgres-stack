# Postgres Stack

Postgres Stack is a reusable Docker Compose starter that runs two independent PostgreSQL 18 instances in one project:

- `postgres-prod` on host port `5423`
- `postgres-dev` on host port `5433`

It is designed for robust single-host use with persistent storage, health checks, restart policies, and safe network defaults.

## What You Get

- PostgreSQL 18 pinned in Compose
- Separate production and development database instances
- Named Docker volumes for persistent data
- Health checks with `pg_isready`
- `restart: unless-stopped` for both services
- Configurable host bind addresses with `127.0.0.1` as the default

## Quick Start

1. Copy the environment template:

   ```bash
   cp .env.example .env
   ```

2. Update the passwords in `.env`.

3. Start both databases:

   ```bash
   docker compose up -d postgres-prod postgres-dev
   ```

4. Check status:

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
docker compose down
```

Remove containers and volumes:

```bash
docker compose down -v
```

## Configuration

Set these values in `.env`:

| Variable | Purpose | Default |
| --- | --- | --- |
| `POSTGRES_PROD_BIND_HOST` | Host/IP for the production port binding | `127.0.0.1` |
| `POSTGRES_DEV_BIND_HOST` | Host/IP for the development port binding | `127.0.0.1` |
| `POSTGRES_PROD_PORT` | Published production port | `5423` |
| `POSTGRES_DEV_PORT` | Published development port | `5433` |
| `POSTGRES_PROD_USER` | Production database user | `postgres` |
| `POSTGRES_DEV_USER` | Development database user | `postgres` |
| `POSTGRES_PROD_PASSWORD` | Production database password | `change-me-prod` |
| `POSTGRES_DEV_PASSWORD` | Development database password | `change-me-dev` |

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

## Changing the Bind Host

By default, both PostgreSQL ports are only reachable from the same machine.

To expose an instance on a server's private IP, set the bind host explicitly in `.env`, for example:

```dotenv
POSTGRES_PROD_BIND_HOST=192.168.1.50
POSTGRES_DEV_BIND_HOST=192.168.1.50
```

Use this only when you intend to accept connections from other machines on your network, and make sure your firewall rules and passwords are appropriate for that exposure.

## Persistence

Data is stored in named Docker volumes:

- `postgres_prod_data`
- `postgres_dev_data`

Recreating containers does not remove database contents. Use `docker compose down -v` only when you intentionally want to delete all stored data for both instances.

## Operational Notes

- This project is a production-oriented Compose starter, not a high-availability PostgreSQL cluster.
- It does not include replication, automated backups, failover, or secrets management.
- If you expose the databases beyond `127.0.0.1`, replace the default passwords before starting the stack.
