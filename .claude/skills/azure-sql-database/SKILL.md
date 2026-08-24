---
name: azure-sql-database
description: Investigate Azure SQL Database issues — connection errors, blocking/deadlocks, slow queries, timeouts, resource throttling (DTU/vCore limits), recent errors — using Azure CLI (az sql) for resource-level info and sqlcmd for read-only T-SQL (DMV) queries against the database itself. Use this skill whenever the user suspects the database is the cause of an API error/timeout, asks about slow queries, blocking, deadlocks, connection pool exhaustion, SQL errors, or wants to inspect table/schema/data as part of debugging (SELECT only). Strictly read-only — never runs INSERT/UPDATE/DELETE/DDL/ALTER or any az sql command that creates, updates, scales, or deletes a resource.
---

# Azure SQL Database Debugging (Read-Only)

Two layers of investigation:
1. **Resource/control-plane** via `az sql` — server/database config, firewall,
   resource limits, recent resource-level metrics.
2. **Query/data-plane** via `sqlcmd` — DMVs for blocking, slow queries, wait stats,
   and ad-hoc `SELECT` queries against application data for debugging.

## 0. Load config

```bash
set -a; source ~/.agents/.env; set +a
echo "Server: $AZURE_SQL_SERVER | DB: $AZURE_SQL_DATABASE | RG: $RESOURCE_GROUP"
az account set --subscription "$SUBSCRIPTION"
```

## 1. Read-only rule — this is critical for this skill in particular

**az cli**: only use `show`/`list`/`get-*` style commands, e.g.
`az sql db show`, `az sql server show`, `az sql db list-usages`,
`az sql db op list`, `az monitor metrics list` (for DB resource metrics).
Never use `az sql db create/update/delete`, `az sql server create/update/delete`,
`az sql db update --service-objective` (scaling), firewall-rule create/delete, etc.

**sqlcmd / T-SQL**: only ever run `SELECT` statements (including against DMVs/system
views) or read-only metadata commands. Never run `INSERT`, `UPDATE`, `DELETE`,
`MERGE`, `TRUNCATE`, `CREATE`, `ALTER`, `DROP`, `EXEC` of unknown/write procedures, or
anything that changes data or schema — even if asked "just to test something". If the
user asks for a write/fix, stop and clearly say this skill is read-only for the
database and the change should be made through the normal application/migration path.

Before running any query you're unsure about, mentally check: does this only read
data? If there's any doubt, don't run it — ask the user instead.

## 2. Connecting with sqlcmd

```bash
sqlcmd -S "$AZURE_SQL_SERVER.database.windows.net" \
  -d "$AZURE_SQL_DATABASE" \
  -U "$AZURE_SQL_USER" \
  -P "$AZURE_SQL_PASSWORD" \
  -N -C \
  -Q "SELECT @@VERSION"
```
(`-N -C` = encrypt connection, trust server cert — required for Azure SQL.)

For longer/multi-line queries, use a `.sql` file instead of `-Q`:
```bash
cat > /home/claude/sql/query.sql << 'EOF'
SELECT TOP 20 * FROM sys.dm_exec_requests ORDER BY start_time;
EOF
sqlcmd -S "$AZURE_SQL_SERVER.database.windows.net" -d "$AZURE_SQL_DATABASE" \
  -U "$AZURE_SQL_USER" -P "$AZURE_SQL_PASSWORD" -N -C -i /home/claude/sql/query.sql
```

If `sqlcmd` isn't installed, tell the user, or fall back to
`az sql db show-connection-string` plus a note that a SQL client is needed — don't try
to install packages that require network access outside the allowed domains.

## 3. Investigation playbook — data plane (sqlcmd)

### A. Current blocking / long-running requests

```sql
SELECT
    r.session_id, r.blocking_session_id, r.status, r.command,
    r.wait_type, r.wait_time, r.total_elapsed_time,
    r.cpu_time, s.login_name, s.host_name, s.program_name,
    t.text AS query_text
FROM sys.dm_exec_requests r
JOIN sys.dm_exec_sessions s ON r.session_id = s.session_id
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.session_id <> @@SPID
ORDER BY r.total_elapsed_time DESC;
```
A non-null `blocking_session_id` on a row means that session is blocked by another —
follow the chain to find the head blocker.

### B. Recent expensive/slow queries (query store, if enabled)

```sql
SELECT TOP 20
    qt.query_sql_text,
    rs.avg_duration/1000.0 AS avg_duration_ms,
    rs.avg_cpu_time/1000.0 AS avg_cpu_ms,
    rs.avg_logical_io_reads,
    rs.count_executions,
    rs.last_execution_time
FROM sys.query_store_query q
JOIN sys.query_store_query_text qt ON q.query_text_id = qt.query_text_id
JOIN sys.query_store_plan p ON q.query_id = p.query_id
JOIN sys.query_store_runtime_stats rs ON p.plan_id = rs.plan_id
WHERE rs.last_execution_time > DATEADD(HOUR, -6, GETUTCDATE())
ORDER BY rs.avg_duration DESC;
```
If Query Store isn't enabled (rare on Azure SQL, it's on by default), fall back to
`sys.dm_exec_query_stats` for cumulative stats since last cache clear/restart.

### C. Recent errors (via Azure Monitor / diagnostic logs, not a DMV)

Azure SQL doesn't keep a queryable in-database error log the way on-prem SQL Server
does. For SQL-side errors (deadlocks, timeouts, throttling), prefer:
```bash
az monitor metrics list \
  --resource "/subscriptions/$SUBSCRIPTION/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Sql/servers/$AZURE_SQL_SERVER/databases/$AZURE_SQL_DATABASE" \
  --metric "deadlock,connection_failed,errors" \
  --start-time "2026-08-21T02:00:00Z" --end-time "2026-08-21T03:00:00Z" \
  --interval PT1M -o table
```
For full error detail/text, deadlock graphs, and throttling reasons, hand off to
**log-analytics-workspace** (if SQL diagnostic settings feed logs there,
tables like `AzureDiagnostics`/`SQLInsights`/`Errors`) — this DB doesn't expose
those over sqlcmd directly.

### D. Deadlocks (if extended events / diagnostics aren't wired up)

```sql
SELECT TOP 10 *
FROM sys.dm_os_ring_buffers
WHERE ring_buffer_type = 'RING_BUFFER_XEVENT'
  AND record LIKE '%deadlock%'
ORDER BY timestamp DESC;
```
Better: check the Log Analytics workspace's deadlock diagnostics if available — the
XML in ring buffers is limited/truncated and this is a fallback only.

### E. Resource pressure (DTU/vCore, connections, storage)

```sql
SELECT * FROM sys.dm_db_resource_stats ORDER BY end_time DESC;  -- last hour, 15s intervals
```
```sql
SELECT COUNT(*) AS current_connections FROM sys.dm_exec_sessions WHERE is_user_process = 1;
```
Compare against limits:
```bash
az sql db show --name "$AZURE_SQL_DATABASE" --server "$AZURE_SQL_SERVER" \
  --resource-group "$RESOURCE_GROUP" \
  --query "{sku:currentSku, maxSizeBytes:maxSizeBytes, status:status}" -o table
```

### F. Wait stats since last restart (what's the DB spending time waiting on)

```sql
SELECT TOP 15 wait_type, wait_time_ms, waiting_tasks_count,
    wait_time_ms * 1.0 / NULLIF(waiting_tasks_count,0) AS avg_wait_ms
FROM sys.dm_db_wait_stats
WHERE wait_type NOT IN ('SLEEP_TASK','BROKER_TASK_STOP','SQLTRACE_INCREMENTAL_FLUSH_SLEEP')
ORDER BY wait_time_ms DESC;
```

### G. Ad-hoc data inspection (debugging a specific record)

Only `SELECT`. Example — checking what state an order is actually in:
```sql
SELECT TOP 50 * FROM dbo.Orders WHERE OrderId = 12345 ORDER BY ModifiedDate DESC;
```
Prefer `TOP N` / `WHERE` filters on any ad-hoc query against production data to avoid
scanning large tables.

## 4. Investigation playbook — control plane (az sql)

```bash
# Server/db config
az sql db show --name "$AZURE_SQL_DATABASE" --server "$AZURE_SQL_SERVER" --resource-group "$RESOURCE_GROUP" -o table

# Firewall rules (connectivity troubleshooting — e.g. App Service can't reach DB)
az sql server firewall-rule list --server "$AZURE_SQL_SERVER" --resource-group "$RESOURCE_GROUP" -o table

# Check if App Service's outbound IPs are allow-listed, or if "Allow Azure services" is on
az sql server show --name "$AZURE_SQL_SERVER" --resource-group "$RESOURCE_GROUP" -o json

# Recent long-running/failed operations against the DB (scaling, restores — not app queries)
az sql db op list --db-name "$AZURE_SQL_DATABASE" --server "$AZURE_SQL_SERVER" --resource-group "$RESOURCE_GROUP" -o table
```

## 5. Connectivity troubleshooting checklist

If the backend reports "cannot connect to SQL" / timeouts at connection time:
1. Check firewall rules include the App Service's outbound IPs or "Allow Azure
   services and resources" is enabled.
2. Check `sys.dm_exec_sessions` / current connection count vs. plan limits (connection
   pool exhaustion on the app side looks like this too — check both).
3. Check `az monitor metrics list` for `connection_failed`/`blocked_by_firewall` on the
   database resource around the incident time.
4. If TLS/cert issues are suspected, confirm the backend's connection string uses
   `Encrypt=True;TrustServerCertificate=False` (Azure SQL requires TLS).

## 6. When to hand off to other skills/tools

- Need the app-side view of a DB call (duration, exception message the app raised) →
  **app-insights-kql** (`dependencies` table, `type == "SQL"`).
- Need SQL diagnostic logs (deadlock graphs, detailed errors, auditing) shipped to a
  workspace → **log-analytics-workspace**.
- Need to see if a restart/scale/config change correlates with the incident →
  **azure-monitor** or **log-analytics-workspace** (`AzureActivity`).

## 7. Output format for the user

State exactly which queries/commands were run (so they're reproducible), summarize
findings (blocking chains, slow query text, resource pressure numbers), and propose
next steps. Never propose or run a fix query — only report findings and suggest the
appropriate team/skill/action for remediation.
