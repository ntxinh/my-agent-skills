# Azure Monitor — Command Reference

This file holds the full command examples for each investigation area. SKILL.md
tells you when to reach for each section; this file has the actual commands.

All commands below assume you've already resolved config for the target
environment (see SKILL.md "Config resolution") and exported it into shell
variables, e.g.:

```bash
CONFIG_JSON="$(scripts/resolve_config.sh --env "$ENV_NAME")"

SUBSCRIPTION_ID=$(jq -r '.subscriptionId' <<<"$CONFIG_JSON")
RESOURCE_GROUP=$(jq -r '.resourceGroup' <<<"$CONFIG_JSON")
APP_SERVICE_BACKEND_NAME=$(jq -r '.appServiceBackendName // empty' <<<"$CONFIG_JSON")
APP_SERVICE_FRONTEND_NAME=$(jq -r '.appServiceFrontendName // empty' <<<"$CONFIG_JSON")
SQL_SERVER_NAME=$(jq -r '.sqlServerName // empty' <<<"$CONFIG_JSON")
SQL_DATABASE_NAME=$(jq -r '.sqlDatabaseName // empty' <<<"$CONFIG_JSON")
STORAGE_ACCOUNT_NAME=$(jq -r '.storageAccountName // empty' <<<"$CONFIG_JSON")

az account show --query name -o tsv 2>/dev/null || az login
az account set --subscription "$SUBSCRIPTION_ID"
```

Then resolve resource IDs once and reuse them (cheaper than repeated name lookups):

```bash
BACKEND_ID=$(az webapp show -g "$RESOURCE_GROUP" -n "$APP_SERVICE_BACKEND_NAME" --query id -o tsv)
FRONTEND_ID=$(az webapp show -g "$RESOURCE_GROUP" -n "$APP_SERVICE_FRONTEND_NAME" --query id -o tsv)
SQL_DB_ID=$(az sql db show -g "$RESOURCE_GROUP" -s "$SQL_SERVER_NAME" -n "$SQL_DATABASE_NAME" --query id -o tsv)
STORAGE_ID=$(az storage account show -g "$RESOURCE_GROUP" -n "$STORAGE_ACCOUNT_NAME" --query id -o tsv)
```

Only resolve the resource IDs you actually need for the investigation at hand —
skip any whose name field wasn't present in the config (e.g. no SQL resource
configured for a static-site project).

## 1. Activity Log — "what changed, and who/what triggered it"

Control-plane events: restarts, config changes, deployments, scaling operations,
role assignments. Always check this first for "it broke at time X".

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

Firing history for metric alerts lives in the Activity Log under category `Alert`
— reuse the activity-log command above with `--caller` or filter by resourceId
of the alert.

## 4. Diagnostic Settings — "where is this resource's telemetry actually going"

Useful when logs/metrics you expect in Log Analytics or App Insights aren't
showing up — confirms the routing before you go debug the query.

```bash
az monitor diagnostic-settings list --resource "$BACKEND_ID" -o table
az monitor diagnostic-settings list --resource "$SQL_DB_ID" -o table
az monitor diagnostic-settings list --resource "$STORAGE_ID" -o table

# Full detail incl. which log categories / metrics + destination workspace or storage
az monitor diagnostic-settings show --resource "$BACKEND_ID" --name <setting-name> -o json
```

If nothing is returned, that resource has no diagnostic settings configured —
flag this to the user rather than assuming the query in another skill is wrong.

## 5. Autoscale — "did scaling cause or fail to prevent this"

Only relevant if the App Service plan has autoscale configured (many small
deployments don't).

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
7. If you need the actual raw log lines for that day → hand off to **storage-app-service-logs** (path pattern under the configured storage account/container).

## Output hygiene

- Default to `-o table` for human scanning; switch to `-o json` + `jq`/`--query` (JMESPath) when correlating multiple resources programmatically.
- Always state the UTC time window used, since App Service/SQL/Storage timestamps are UTC and the user may think in local time.
- When summarizing, lead with the Activity Log finding (if any) before metrics — a config change is a more actionable root cause than "CPU was high."
