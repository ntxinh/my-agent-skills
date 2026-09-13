# Azure SQL Database — Command & Query Reference

This file holds the full investigation playbooks. SKILL.md tells you when to
reach for each section; this file has the actual commands and queries.

All commands below assume you've already resolved config for the target
environment (see SKILL.md "Config resolution") and exported it into shell
variables:

```bash
CONFIG_JSON="$(scripts/resolve_config.sh --env "$ENV_NAME")"

SUBSCRIPTION_ID=$(jq -r '.subscriptionId' <<<"$CONFIG_JSON")
RESOURCE_GROUP=$(jq -r '.resourceGroup' <<<"$CONFIG_JSON")
SQL_SERVER_NAME=$(jq -r '.sqlServerName' <<<"$CONFIG_JSON")
SQL_DATABASE_NAME=$(jq -r '.sqlDatabaseName // empty' <<<"$CONFIG_JSON")
SQL_USERNAME=$(jq -r '.sqlUsername // empty' <<<"$CONFIG_JSON")

az account set --subscription "$SUBSCRIPTION_ID"
```

**Password**: never read from the config file. Ask the user to export
`SQLCMDPASSWORD` for the session before any `sqlcmd` command runs —
`sqlcmd` reads this environment variable natively, so no `-P` flag or
custom plumbing is needed. This applies to both `qa` and `production`, and
the resolver script actively rejects a config file that contains a password
field (see SKILL.md "Config resolution").

## Connecting with sqlcmd

```bash
sqlcmd -S "$SQL_SERVER_NAME.database.windows.net" \
  -d "$SQL_DATABASE_NAME" \
  -U "$SQL_USERNAME" \
  -N -C \
  -Q "SELECT @@VERSION"
```
(`-N -C` = encrypt connection, trust server cert — required for Azure SQL.
Password comes from `SQLCMDPASSWORD` in the environment, not a flag.)

For longer/multi-line queries, use a `.sql` file instead of `-Q`:
```bash
cat > /home/claude/sql/query.sql << 'EOF'
SELECT TOP 20 * FROM sys.dm_exec_requests ORDER BY start_time;
EOF
sqlcmd -S "$SQL_SERVER_NAME.database.windows.net" -d "$SQL_DATABASE_NAME" \
  -U "$SQL_USERNAME" -N -C -i /home/claude/sql/query.sql
```

If `sqlcmd` isn't installed, tell the user, or fall back to
`az sql db show-connection-string` plus a note that a SQL client is needed —
don't try to install packages that require network access outside the
allowed domains.

## Investigation playbook — data plane (sqlcmd)

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
A non-null `blocking_session_id` on a row means that session is blocked by
another — follow the chain to find the head blocker.

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
If Query Store isn't enabled (rare on Azure SQL, it's on by default), fall
back to `sys.dm_exec_query_stats` for cumulative stats since last cache
clear/restart.

### C. Recent errors (via Azure Monitor / diagnostic logs, not a DMV)

Azure SQL doesn't keep a queryable in-database error log the way on-prem SQL
Server does. For SQL-side errors (deadlocks, timeouts, throttling), prefer:
```bash
az monitor metrics list \
  --resource "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Sql/servers/$SQL_SERVER_NAME/databases/$SQL_DATABASE_NAME" \
  --metric "deadlock,connection_failed,errors" \
  --start-time "2026-08-21T02:00:00Z" --end-time "2026-08-21T03:00:00Z" \
  --interval PT1M -o table
```
For full error detail/text, deadlock graphs, and throttling reasons, hand
off to **log-analytics-workspace** (if SQL diagnostic settings feed logs
there, tables like `AzureDiagnostics`/`SQLInsights`/`Errors`) — this DB
doesn't expose those over sqlcmd directly.

### D. Deadlocks (if extended events / diagnostics aren't wired up)

```sql
SELECT TOP 10 *
FROM sys.dm_os_ring_buffers
WHERE ring_buffer_type = 'RING_BUFFER_XEVENT'
  AND record LIKE '%deadlock%'
ORDER BY timestamp DESC;
```
Better: check the Log Analytics workspace's deadlock diagnostics if
available — the XML in ring buffers is limited/truncated and this is a
fallback only.

### E. Resource pressure (DTU/vCore, connections, storage)

```sql
SELECT * FROM sys.dm_db_resource_stats ORDER BY end_time DESC;  -- last hour, 15s intervals
```
```sql
SELECT COUNT(*) AS current_connections FROM sys.dm_exec_sessions WHERE is_user_process = 1;
```
Compare against limits:
```bash
az sql db show --name "$SQL_DATABASE_NAME" --server "$SQL_SERVER_NAME" \
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
Prefer `TOP N` / `WHERE` filters on any ad-hoc query against production data
to avoid scanning large tables.

## Investigation playbook — control plane (az sql)

```bash
# Server/db config
az sql db show --name "$SQL_DATABASE_NAME" --server "$SQL_SERVER_NAME" --resource-group "$RESOURCE_GROUP" -o table

# Firewall rules (connectivity troubleshooting — e.g. App Service can't reach DB)
az sql server firewall-rule list --server "$SQL_SERVER_NAME" --resource-group "$RESOURCE_GROUP" -o table

# Check if App Service's outbound IPs are allow-listed, or if "Allow Azure services" is on
az sql server show --name "$SQL_SERVER_NAME" --resource-group "$RESOURCE_GROUP" -o json

# Recent long-running/failed operations against the DB (scaling, restores — not app queries)
az sql db op list --db-name "$SQL_DATABASE_NAME" --server "$SQL_SERVER_NAME" --resource-group "$RESOURCE_GROUP" -o table
```

## Connectivity troubleshooting checklist

If the backend reports "cannot connect to SQL" / timeouts at connection time:
1. Check firewall rules include the App Service's outbound IPs or "Allow
   Azure services and resources" is enabled.
2. Check `sys.dm_exec_sessions` / current connection count vs. plan limits
   (connection pool exhaustion on the app side looks like this too — check
   both).
3. Check `az monitor metrics list` for `connection_failed`/`blocked_by_firewall`
   on the database resource around the incident time.
4. If TLS/cert issues are suspected, confirm the backend's connection string
   uses `Encrypt=True;TrustServerCertificate=False` (Azure SQL requires TLS).

## When to hand off to other skills/tools

- Need the app-side view of a DB call (duration, exception message the app
  raised) → **app-insights-kql** (`dependencies` table, `type == "SQL"`).
- Need SQL diagnostic logs (deadlock graphs, detailed errors, auditing)
  shipped to a workspace → **log-analytics-workspace**.
- Need to see if a restart/scale/config change correlates with the incident
  → **azure-monitor** or **log-analytics-workspace** (`AzureActivity`).

## Output format for the user

State exactly which queries/commands were run (so they're reproducible),
summarize findings (blocking chains, slow query text, resource pressure
numbers), and propose next steps. Never propose or run a fix query — only
report findings and suggest the appropriate team/skill/action for
remediation.
