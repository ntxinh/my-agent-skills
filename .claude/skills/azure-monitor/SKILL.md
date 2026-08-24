---
name: azure-monitor
description: Read-only Azure Monitor investigation via Azure CLI — activity log (who/what/when changed a resource), platform metrics (CPU, memory, HTTP errors, DTU/DB metrics, storage throttling), configured alert rules and their firing history, diagnostic settings (verifying where logs/metrics are routed), autoscale history, and App Service resource health. Use this whenever the user asks "is X down", "why did it restart", "what changed", "check CPU/memory", "any alerts fired", "check resource health", or wants a cross-resource timeline correlating App Service + SQL + Storage around an incident. This is the control-plane / platform-metrics layer — hand off to app-insights-kql for application traces/exceptions, to log-analytics-workspace for KQL log queries, to storage-app-service-logs for raw daily log files, and to azure-sql-database for query-level DB diagnostics. NEVER runs any create/update/delete/set/restart command — strictly list/show/get.
---

# Azure Monitor (read-only)

Investigates infrastructure-level signals across the whole stack using `az monitor` and related read-only `az` subcommands: **what changed** (Activity Log), **how the resource is behaving** (Metrics), **what's already been flagged** (Alerts), **where telemetry is routed** (Diagnostic Settings), and **is Azure itself reporting a problem** (Resource Health).

This is usually the *first* skill to reach for when triaging "something's wrong in prod" — it gives a fast timeline before diving into `app-insights-kql` (traces/exceptions), `log-analytics-workspace` (KQL over logs), `storage-app-service-logs` (raw Serilog files), or `azure-sql-database` (query plans/blocking).

## Hard rule: read-only, no exceptions

Only ever use: `list`, `show`, `get`, `list-metrics`, `metrics list`, `activity-log list`, `alert list`, `diagnostic-settings list/show`, `autoscale show/list-history`, `resource-health` reads.

**Never** run: `set`, `create`, `update`, `delete`, `restart`, `stop`, `start`, `deploy`, `az webapp restart`, `az sql db update`, `az monitor alert create`, `az monitor diagnostic-settings create`, or anything mutating. If the user asks for a fix/change, propose the command but do not execute it — say so explicitly and wait for confirmation outside this skill.

## Setup

Load resource identifiers from the shared env file at the start of every session:

```bash
set -a; source ~/.agents/.env; set +a
az account show --query name -o tsv 2>/dev/null || az login
az account set --subscription "$SUBSCRIPTION"
```

Resolve resource IDs once and reuse them (cheaper than repeated name lookups):

```bash
BACKEND_ID=$(az webapp show -g "$RESOURCE_GROUP" -n "$AZURE_APP_SERVICE_BACKEND" --query id -o tsv)
FRONTEND_ID=$(az webapp show -g "$RESOURCE_GROUP" -n "$AZURE_APP_SERVICE_FRONTEND" --query id -o tsv)
SQL_DB_ID=$(az sql db show -g "$RESOURCE_GROUP" -s "$AZURE_SQL_SERVER" -n "$AZURE_SQL_DATABASE" --query id -o tsv)
STORAGE_ID=$(az storage account show -g "$RESOURCE_GROUP" -n "$AZURE_STORAGE_ACCOUNT" --query id -o tsv)
```

## 1. Activity Log — "what changed, and who/what triggered it"

Control-plane events: restarts, config changes, deployments, scaling operations, role assignments. Always check this first for "it broke at time X".

```bash
# Everything in the resource group in the last N hours
az monitor activity-log list -g "$RESOURCE_GROUP" \
  --start-time "$(date -u -d '6 hours ago' +%Y-%m-%dT%H:%MZ)" \
  --query "[].{time:eventTimestamp, resource:resourceId, op:operationName.value, status:status.value, caller:caller}" \
  -o table

# Scoped to one resource (e.g. backend App Service) around an incident window
az monitor activity-log list --resource-id "$BACKEND_ID" \
  --start-time "2026-08-20T00:00:00Z" --end-time "2026-08-21T00:00:00Z" \
  -o table

# Only failures/warnings
az monitor activity-log list -g "$RESOURCE_GROUP" --status Failed -o table
```

## 2. Metrics — "how is it behaving right now / over time"

Platform metrics don't need App Insights and cover the last 93 days by default.

```bash
# List available metric names for a resource type (do this once per resource type you haven't queried before)
az monitor metrics list-definitions --resource "$BACKEND_ID" --query "[].name.value" -o tsv

# App Service backend: CPU, memory, HTTP 5xx, response time, requests
az monitor metrics list --resource "$BACKEND_ID" \
  --metric "CpuPercentage" "MemoryPercentage" "Http5xx" "AverageResponseTime" "Requests" \
  --interval PT5M --start-time "$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%MZ)" \
  --aggregation Average Maximum \
  -o table

# Azure SQL Database: DTU/CPU, storage, deadlocks, connections
az monitor metrics list --resource "$SQL_DB_ID" \
  --metric "dtu_consumption_percent" "cpu_percent" "storage_percent" "deadlock" "connection_successful" "connection_failed" \
  --interval PT5M --start-time "$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%MZ)" \
  -o table

# Storage account: throttling, availability, latency (relevant when daily App Service logs write is failing)
az monitor metrics list --resource "$STORAGE_ID" \
  --metric "Availability" "SuccessServerLatency" "Transactions" \
  --interval PT1H --start-time "$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%MZ)" \
  -o table
```

Tips:
- Use `--dimension` to break metrics down (e.g. `ResponseCode` for `Http5xx`, `ApiName` for storage).
- `--interval` accepts PT1M/PT5M/PT15M/PT1H/P1D; narrower interval = more granularity but shorter max lookback.
- Add `-o json` and pipe to `jq` when you need to correlate exact timestamps across resources.

## 3. Alerts — "has this already been flagged"

```bash
# Configured alert rules (metric + activity-log based) in the resource group
az monitor metrics alert list -g "$RESOURCE_GROUP" -o table
az monitor activity-log alert list -g "$RESOURCE_GROUP" -o table

# Action groups wired to those alerts (who/what gets notified)
az monitor action-group list -g "$RESOURCE_GROUP" -o table
```

Firing history for metric alerts lives in the Activity Log under category `Alert` — reuse the activity-log command above with `--caller` or filter by resourceId of the alert.

## 4. Diagnostic Settings — "where is this resource's telemetry actually going"

Useful when logs/metrics you expect in Log Analytics or App Insights aren't showing up — confirms the routing before you go debug the query.

```bash
az monitor diagnostic-settings list --resource "$BACKEND_ID" -o table
az monitor diagnostic-settings list --resource "$SQL_DB_ID" -o table
az monitor diagnostic-settings list --resource "$STORAGE_ID" -o table

# Full detail incl. which log categories / metrics + destination workspace or storage
az monitor diagnostic-settings show --resource "$BACKEND_ID" --name <setting-name> -o json
```

If nothing is returned, that resource has no diagnostic settings configured — flag this to the user rather than assuming the query in another skill is wrong.

## 5. Autoscale — "did scaling cause or fail to prevent this"

Only relevant if the App Service plan has autoscale configured (many small deployments don't).

```bash
az monitor autoscale list -g "$RESOURCE_GROUP" -o table
az monitor autoscale show -g "$RESOURCE_GROUP" -n <autoscale-setting-name> -o json
```

## 6. Resource Health — "is this actually an Azure-side outage"

```bash
az rest --method get \
  --url "https://management.azure.com${BACKEND_ID}/providers/Microsoft.ResourceHealth/availabilityStatuses/current?api-version=2022-10-01"
```

Rules out "Azure platform issue" before spending time debugging application code.

## Suggested triage workflow

1. **Anchor the time window** from the user's report (error timestamp, ticket, alert notification).
2. **Activity Log** on the resource group for that window — look for deploys/restarts/config changes first; they explain most incidents outright.
3. **Metrics** on the affected resource(s) for the same window — CPU/memory/5xx for App Service, DTU/deadlocks/connections for SQL, availability/latency for Storage.
4. **Alerts** — check if something already fired and who was notified.
5. If metrics look fine but the app is still misbehaving → hand off to **app-insights-kql** for exception traces, or **log-analytics-workspace** for Serilog/OpenTelemetry structured logs.
6. If it's a slow SQL query, not an infra spike → hand off to **azure-sql-database**.
7. If you need the actual raw log lines for that day → hand off to **storage-app-service-logs** (path pattern `AZURE_STORAGE_ACCOUNT_CONTAINER_DIRECTORY_STRUCTURE`).

## Output hygiene

- Default to `-o table` for human scanning; switch to `-o json` + `jq`/`--query` (JMESPath) when correlating multiple resources programmatically.
- Always state the UTC time window used, since App Service/SQL/Storage timestamps are UTC and the user may think in local time.
- When summarizing, lead with the Activity Log finding (if any) before metrics — a config change is a more actionable root cause than "CPU was high."
