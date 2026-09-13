# Log Analytics Workspace — Query & Investigation Reference

This file holds the full KQL investigation playbook. SKILL.md tells you when
to reach for each section; this file has the actual queries.

All commands below assume you've already resolved config for the target
environment (see SKILL.md "Config resolution") and exported it into shell
variables:

```bash
CONFIG_JSON="$(scripts/resolve_config.sh --env "$ENV_NAME")"

SUBSCRIPTION_ID=$(jq -r '.subscriptionId' <<<"$CONFIG_JSON")
RESOURCE_GROUP=$(jq -r '.resourceGroup' <<<"$CONFIG_JSON")
LOG_ANALYTICS_WORKSPACE_NAME=$(jq -r '.logAnalyticsWorkspaceName' <<<"$CONFIG_JSON")
APP_SERVICE_BACKEND_NAME=$(jq -r '.appServiceBackendName // empty' <<<"$CONFIG_JSON")
APP_SERVICE_FRONTEND_NAME=$(jq -r '.appServiceFrontendName // empty' <<<"$CONFIG_JSON")

az account set --subscription "$SUBSCRIPTION_ID"
```

The CLI query command needs the workspace's **customer ID (GUID)**, not its
name. Resolve it once per session and reuse:

```bash
WORKSPACE_ID=$(az monitor log-analytics workspace show \
  --resource-group "$RESOURCE_GROUP" \
  --workspace-name "$LOG_ANALYTICS_WORKSPACE_NAME" \
  --query customerId -o tsv)
echo "$WORKSPACE_ID"
```

## Core query command shape

```bash
az monitor log-analytics query \
  --workspace "$WORKSPACE_ID" \
  --analytics-query "<KQL HERE>" \
  -o table
```

Bound every query with a time filter (`ago()` or explicit `datetime` range)
— this workspace can hold logs from many resources and grow large.

## Discover what's actually flowing into the workspace

If unsure which tables have data (depends on which diagnostic settings are
enabled):

```bash
az monitor log-analytics query \
  --workspace "$WORKSPACE_ID" \
  --analytics-query "union withsource=TableName * | where TimeGenerated > ago(1d) | summarize count() by TableName | order by count_ desc" \
  -o table
```

Common tables for this stack:
- `AppServiceHTTPLogs` — IIS/Kestrel-level HTTP access logs for the App
  Service (both backend and frontend apps, distinguish via `_ResourceId` or
  `Host`).
- `AppServiceConsoleLogs` — stdout/stderr from the app process (useful if
  Serilog console sink is enabled).
- `AppServiceAppLogs` — App Service's own application logging pipe (if
  enabled in App Service diagnostic logs settings, separate from
  Serilog/App Insights).
- `AppServicePlatformLogs` — container start/stop, deployment,
  platform-level events.
- `AppServiceAuditLogs` — auth/SCM access events.
- `AppTraces`, `AppExceptions`, `AppRequests`, `AppDependencies` — present if
  the Application Insights resource is workspace-based (i.e. backed by this
  workspace). If so, this is an alternative path to the same data the
  app-insights-kql skill queries directly.
- `AzureDiagnostics` / resource-specific diagnostic tables — if Azure SQL or
  other resources have diagnostic settings pointed at this workspace.
- `AzureActivity` — control-plane operations (deployments, config changes,
  restarts) against resources in the resolved resource group. Very useful
  to correlate "something changed" with "something broke".

## Investigation playbook

### A. Correlate an incident with a deployment/restart/config change

```kql
AzureActivity
| where TimeGenerated > ago(24h)
| where ResourceGroup =~ "<RESOURCE_GROUP>"
| where ActivityStatusValue == "Success"
| project TimeGenerated, OperationNameValue, Caller, ResourceId
| order by TimeGenerated desc
```
Look for `Microsoft.Web/sites/restart`, `Microsoft.Web/sites/write`
(config/slot changes), or deployment-related entries right before the
incident window.

### B. App Service HTTP-level errors (5xx/4xx) — before app code even runs

```kql
AppServiceHTTPLogs
| where TimeGenerated > ago(2h)
| where ScStatus >= 500
| project TimeGenerated, CsMethod, CsUriStem, ScStatus, TimeTaken, CIp
| order by TimeGenerated desc
```
Useful when App Insights shows nothing (e.g. the app crashed before the SDK
could initialize, or the platform itself returned the error).

### C. Container/platform-level crashes or restarts

```kql
AppServicePlatformLogs
| where TimeGenerated > ago(6h)
| where Level in ("Error", "Critical") or Message has_any ("fail", "crash", "restart")
| project TimeGenerated, Message, Level
| order by TimeGenerated desc
```

### D. Console/stdout logs (if Serilog console sink + App Service logging enabled)

```kql
AppServiceConsoleLogs
| where TimeGenerated > ago(1h)
| where ResultDescription has "Exception" or ResultDescription has "Error"
| project TimeGenerated, ResultDescription
| order by TimeGenerated desc
```

### E. If App Insights is workspace-based, query app tables directly here

```kql
AppExceptions
| where TimeGenerated > ago(6h)
| summarize count() by ExceptionType, Method
| order by count_ desc
```
(Column names differ slightly from the classic App Insights schema — e.g.
`ExceptionType` instead of `type`, `TimeGenerated` instead of `timestamp`.
Check with `AppExceptions | take 1` if a query returns no results, to
confirm you're on the right schema.)

### F. Cross-resource timeline for an incident window

```kql
union AppServiceHTTPLogs, AppServiceConsoleLogs, AppServicePlatformLogs, AzureActivity
| where TimeGenerated between (datetime(2026-08-21T02:00:00Z) .. datetime(2026-08-21T03:00:00Z))
| project TimeGenerated, Type, Message = coalesce(Message, ResultDescription, OperationNameValue)
| order by TimeGenerated asc
```

## Filtering to backend vs frontend App Service

Both apps may log into the same workspace. Filter by resource:

```kql
AppServiceHTTPLogs
| where _ResourceId has "<value of APP_SERVICE_BACKEND_NAME>"
```
or check `Host`/`CsHost` if `_ResourceId` isn't populated for the table. Swap
in `APP_SERVICE_FRONTEND_NAME` for the frontend app's logs.

## When to hand off to other skills/tools

- App-level exceptions/custom traces/request timings with rich correlation
  (`operation_Id`) → prefer **app-insights-kql** unless this workspace is
  confirmed to be the same backing store and you need a cross-resource join
  it can't do alone.
- The actual raw daily text log file written by the app (not structured
  telemetry) → **Azure Storage App Service logs** skill.
- Suspect DB-side cause (locking, slow query, connection errors) → **Azure
  SQL Database** skill.
- Need alert rules, metric charts, or Azure Monitor alert history rather
  than raw logs → **Azure Monitor** skill.
- Frontend-only issue reproducible in browser → Chrome DevTools MCP/plugin.

## Output format for the user

Always include: time range queried, exact KQL used, table(s) queried, a
concise summary of findings, and a suggested next query or next skill.
Never claim a fix was applied — this skill only observes and reports.
