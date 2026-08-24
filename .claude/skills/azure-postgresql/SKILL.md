---
name: azure-postgresql
description: Read-only Azure Database for PostgreSQL (Flexible Server) investigation via Azure CLI and read-only psql/SQL queries — CPU/memory/storage/IOPS metrics, active connections and connection limits, slow queries via pg_stat_statements, blocking/locks via pg_locks and pg_stat_activity, replication lag, autovacuum/bloat health, and server logs. Use whenever the user reports "Postgres is slow", "connection refused / too many connections", "query taking forever", "replica lag", "high CPU on the database", or wants to check server config/metrics for a service using Azure Database for PostgreSQL. Sibling skill to azure-sql-database (SQL Server) — same role, different engine; complements azure-cosmos-db and azure-cache-redis as the fourth data-layer skill. NEVER runs INSERT/UPDATE/DELETE/DDL/VACUUM/ANALYZE/kill-connection commands, and never changes server config or scaling — SELECT-only queries and read-only Azure CLI commands only.
---

# Azure Database for PostgreSQL (read-only)

Investigates PostgreSQL-backed issues: connection exhaustion, slow queries, locking, replication lag, and storage/vacuum health. Sibling to `azure-sql-database` (same layer of the stack, different engine) — use this one if the product has a service on Azure Database for PostgreSQL rather than, or alongside, Azure SQL.

## Hard rule: read-only, no exceptions

**Azure CLI**: only `list`, `show`, `list-metrics`, and log/metric reads. Never `create`, `update`, `delete`, `az postgres flexible-server restart`, `az postgres flexible-server parameter set`, or scaling/failover operations.

**SQL**: only `SELECT` statements, including against system catalogs and stats views (`pg_stat_activity`, `pg_stat_statements`, `pg_locks`, `pg_stat_user_tables`, `pg_stat_replication`). Never `INSERT`/`UPDATE`/`DELETE`/`TRUNCATE`/any DDL (`CREATE`/`ALTER`/`DROP`), never `VACUUM`/`ANALYZE`/`REINDEX` (these mutate storage/stats even though they're "maintenance," and never `pg_terminate_backend`/`pg_cancel_backend` (kills another session — a mutating, disruptive action). If a fix requires killing a blocking session or running `VACUUM`, propose it explicitly and get confirmation — don't execute it.

## Setup

Add these to `~/.agents/.env` if not already present (ask the user for real values):

```ini
AZURE_POSTGRESQL_SERVER=
AZURE_POSTGRESQL_DATABASE=
AZURE_POSTGRESQL_USER=
AZURE_POSTGRESQL_PASSWORD=
```

```bash
set -a; source ~/.agents/.env; set +a
az account set --subscription "$SUBSCRIPTION"

PG_ID=$(az postgres flexible-server show -g "$RESOURCE_GROUP" -n "$AZURE_POSTGRESQL_SERVER" --query id -o tsv)
```

Connect (read-only role recommended at the database level, in addition to only ever issuing `SELECT`):

```bash
PGPASSWORD="$AZURE_POSTGRESQL_PASSWORD" psql \
  "host=$AZURE_POSTGRESQL_SERVER.postgres.database.azure.com port=5432 dbname=$AZURE_POSTGRESQL_DATABASE user=$AZURE_POSTGRESQL_USER sslmode=require" \
  -c "SELECT 1;"
```

## 1. Server config & health — "what are we actually running"

```bash
az postgres flexible-server show -g "$RESOURCE_GROUP" -n "$AZURE_POSTGRESQL_SERVER" \
  --query "{sku:sku.name, tier:sku.tier, storageGb:storage.storageSizeGb, version:version, ha:highAvailability.mode, state:state}" -o json

# Key server parameters that explain a lot of incidents
az postgres flexible-server parameter show -g "$RESOURCE_GROUP" -s "$AZURE_POSTGRESQL_SERVER" -n max_connections -o json
az postgres flexible-server parameter show -g "$RESOURCE_GROUP" -s "$AZURE_POSTGRESQL_SERVER" -n shared_buffers -o json
az postgres flexible-server parameter show -g "$RESOURCE_GROUP" -s "$AZURE_POSTGRESQL_SERVER" -n log_min_duration_statement -o json
```

`max_connections` is a fixed value per SKU tier — check it before assuming "connection refused" is an app bug; a small tier can have a surprisingly low ceiling.

## 2. CPU / memory / storage / IOPS — via Metrics

```bash
az monitor metrics list --resource "$PG_ID" \
  --metric "cpu_percent" "memory_percent" "storage_percent" "iops" "active_connections" \
  --interval PT5M --start-time "$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%MZ)" \
  -o table
```

`storage_percent` climbing toward 100% is urgent — Flexible Server can go read-only when storage fills. `active_connections` near `max_connections` (step 1) is the direct explanation for connection-refused errors.

## 3. Active sessions & blocking — live, read-only

```sql
-- What's running right now, and for how long
SELECT pid, usename, application_name, state, wait_event_type, wait_event,
       now() - query_start AS duration, query
FROM pg_stat_activity
WHERE state != 'idle'
ORDER BY duration DESC;

-- Blocking chains: who is blocking whom
SELECT blocked.pid AS blocked_pid, blocked.query AS blocked_query,
       blocking.pid AS blocking_pid, blocking.query AS blocking_query
FROM pg_locks bl
JOIN pg_stat_activity blocked ON blocked.pid = bl.pid
JOIN pg_locks bl2 ON bl2.locktype = bl.locktype AND bl2.database IS NOT DISTINCT FROM bl.database
  AND bl2.relation IS NOT DISTINCT FROM bl.relation AND bl2.pid != bl.pid AND bl2.granted
JOIN pg_stat_activity blocking ON blocking.pid = bl2.pid
WHERE NOT bl.granted;
```

Long-running `idle in transaction` sessions are a classic cause of both blocking and autovacuum being unable to clean up dead rows — flag these specifically.

## 4. Slow queries — pg_stat_statements

Requires the `pg_stat_statements` extension to be enabled (check first — it's opt-in via `shared_preload_libraries`):

```sql
SELECT query, calls, total_exec_time, mean_exec_time, rows
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
LIMIT 20;
```

If the extension isn't enabled, say so explicitly — enabling it requires a server restart (a change, not something this skill applies) so flag it as a proposed improvement rather than assuming query-level data is available.

## 5. Table/index health — bloat & autovacuum

```sql
-- Dead tuple ratio per table — high values mean autovacuum is falling behind
SELECT relname, n_live_tup, n_dead_tup,
       round(n_dead_tup::numeric / NULLIF(n_live_tup + n_dead_tup, 0) * 100, 1) AS dead_pct,
       last_autovacuum, last_autoanalyze
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC
LIMIT 20;

-- Unused indexes (candidates for review, not action here) and missing-index hints via seq scans
SELECT relname, seq_scan, seq_tup_read, idx_scan, seq_scan - idx_scan AS scan_diff
FROM pg_stat_user_tables
WHERE seq_scan > 0
ORDER BY scan_diff DESC
LIMIT 20;
```

A table with high `seq_scan` relative to `idx_scan` on a large table is a strong signal of a missing index — propose it, don't create it.

## 6. Replication (if HA / read replicas configured)

```bash
az postgres flexible-server replica list -g "$RESOURCE_GROUP" -n "$AZURE_POSTGRESQL_SERVER" -o table
```

```sql
-- On the primary: replay lag per replica
SELECT application_name, client_addr, state,
       pg_wal_lsn_diff(sent_lsn, replay_lsn) AS replay_lag_bytes
FROM pg_stat_replication;
```

Growing `replay_lag_bytes` explains stale-read symptoms on read-replica-routed traffic.

## 7. Logs & diagnostic settings

```bash
az monitor diagnostic-settings list --resource "$PG_ID" -o table
```

If routed to the shared Log Analytics workspace, hand off to `log-analytics-workspace` with a starting query against `AzureDiagnostics` filtered to `Category == "PostgreSQLLogs"`, looking for `ERROR`, `FATAL`, or `deadlock detected` entries, and correlate timestamps with the Azure Monitor activity log for restarts/failovers/scaling events.

## Suggested triage workflow

1. **"Connection refused / too many connections"** → step 2 (`active_connections` vs. step 1's `max_connections`) → step 3 (any long-idle or idle-in-transaction sessions hogging slots).
2. **"Query taking forever"** → step 3 (is it blocked, or just slow) → step 4 (pg_stat_statements, if enabled) → step 5 (missing index / bloat check).
3. **"High CPU / storage filling up"** → step 2 (metrics) → step 5 (bloat/dead tuples driving both CPU from re-reads and storage growth) → step 1 (confirm SKU/storage tier is actually sized for current load).
4. **"Replica returning stale data"** → step 6 (replication lag).

## Output hygiene

- Always state whether the server is single-instance or HA-enabled, and whether replicas exist — changes what "check replication" even means.
- Report `pg_stat_statements` and dead-tuple figures with the *scope* (per-table/per-query), not aggregated across the whole database, so the proposed fix can be targeted.
- Flag anything requiring `shared_preload_libraries` changes, parameter changes, or session termination as a proposed action for a human/coding agent — this skill only observes.
