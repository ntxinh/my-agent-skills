---
name: azure-postgresql
description: Read-only Azure Database for PostgreSQL (Flexible Server) investigation via Azure CLI and read-only psql/SQL queries — CPU/memory/storage/IOPS metrics, active connections and connection limits, slow queries via pg_stat_statements, blocking/locks via pg_locks and pg_stat_activity, replication lag, autovacuum/bloat health, and server logs. Use whenever the user reports "Postgres is slow", "connection refused / too many connections", "query taking forever", "replica lag", "high CPU on the database", or wants to check server config/metrics for a service using Azure Database for PostgreSQL. Sibling skill to azure-sql-database (SQL Server) — same role, different engine; complements azure-cosmos-db and azure-cache-redis as the fourth data-layer skill. NEVER runs INSERT/UPDATE/DELETE/DDL/VACUUM/ANALYZE/kill-connection commands, and never changes server config or scaling — SELECT-only queries and read-only Azure CLI commands only.
---

# Azure Database for PostgreSQL (read-only)

Investigates PostgreSQL-backed issues: connection exhaustion, slow queries,
locking, replication lag, and storage/vacuum health. Sibling to
`azure-sql-database` (same layer of the stack, different engine) — use this
one if the product has a service on Azure Database for PostgreSQL rather
than, or alongside, Azure SQL.

## Hard rule: read-only, no exceptions

**Azure CLI**: only `list`, `show`, `list-metrics`, and log/metric reads.
Never `create`, `update`, `delete`, `az postgres flexible-server restart`,
`az postgres flexible-server parameter set`, or scaling/failover operations.

**SQL**: only `SELECT` statements, including against system catalogs and
stats views (`pg_stat_activity`, `pg_stat_statements`, `pg_locks`,
`pg_stat_user_tables`, `pg_stat_replication`). Never
`INSERT`/`UPDATE`/`DELETE`/`TRUNCATE`/any DDL (`CREATE`/`ALTER`/`DROP`),
never `VACUUM`/`ANALYZE`/`REINDEX` (these mutate storage/stats even though
they're "maintenance"), and never `pg_terminate_backend`/`pg_cancel_backend`
(kills another session — a mutating, disruptive action). If a fix requires
killing a blocking session or running `VACUUM`, propose it explicitly and
get confirmation — don't execute it.

## Config resolution

This skill needs to know which Azure resources to look at, and — critically
— which **environment** (`qa` or `production`) to point at. Getting the
environment wrong can produce a misleading timeline, so:

1. **Determine the environment first.** If the user or the calling
   instruction hasn't specified `qa` or `production` (or it's ambiguous
   which they mean), **ask before proceeding.** Do not default to
   production or guess.

2. **Resolve config for that environment:**

   ```bash
   scripts/resolve_config.sh --env qa         # or: --env production
   ```

   This checks, in order:
   - `<repo-root>/.claude/azure-postgresql.json` — project-specific
     override, found by walking up from the current directory to the git
     root.
   - `~/.claude/azure-postgresql.json` — personal/global default, if the
     project file doesn't exist or doesn't define that environment.

   On success it prints the resolved JSON object with fields
   `subscriptionId`, `resourceGroup`, `postgresServerName` (all required —
   the script validates this), and optionally `postgresDatabaseName` and
   `postgresUsername` (needed only for the SQL-query workflows in
   `references/commands.md` sections 3–6, not for the CLI-only config/metric
   checks in sections 1–2 and 7).

3. **The password is never in this file.** Ask the user to export it as an
   environment variable (e.g. `export PGPASSWORD=...`) for the session
   before running any `psql` command. The resolver script actively rejects
   a config file that contains a password field, since these files are
   meant to be safe to commit at the project level.

4. **On failure (non-zero exit), do not guess values.** Follow the discovery
   flow in `references/discovery.md`: list candidate resources with
   read-only commands, confirm with the user, and offer (never assume) to
   save the non-secret parts to the project config for next time.

See `assets/config.example.json` for the expected shape of both environment
blocks.

## Investigation areas

Once config is resolved and the database connection is established, full
command examples for each area live in `references/commands.md`:

1. **Server config & health** — SKU, storage, version, HA mode, key parameters (`max_connections`, `shared_buffers`, `log_min_duration_statement`).
2. **Metrics** — CPU, memory, storage, IOPS, active connections.
3. **Active sessions & blocking** — `pg_stat_activity`, blocking chains via `pg_locks`.
4. **Slow queries** — `pg_stat_statements` (if enabled).
5. **Table/index health** — bloat, dead tuples, autovacuum lag, missing-index signals.
6. **Replication** — replica list, replay lag.
7. **Logs & diagnostic settings** — where PostgreSQL logs are routed.

`references/commands.md` also has the suggested triage workflow (mapped from
common symptoms — "connection refused", "query taking forever", "high
CPU/storage", "stale replica reads" — to the relevant sections above) and
output-hygiene notes (state HA/replica topology up front, scope
`pg_stat_statements`/dead-tuple figures per-table or per-query, flag any fix
that needs a parameter change or session kill as a proposed action rather
than executing it).
