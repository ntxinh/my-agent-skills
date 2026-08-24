---
name: log-analytics-workspace
description: Query the Azure Log Analytics Workspace using KQL via Azure CLI to debug platform-level and cross-resource issues — App Service platform/HTTP/console/app logs, diagnostic settings data, Azure SQL diagnostics (if wired to this workspace), Activity Log entries, and any resource sending logs/metrics into this workspace. Use this skill whenever the user asks about App Service platform logs, HTTP logs, container/console logs, deployment logs, restarts, scaling events, resource health, or wants a query that spans multiple Azure resources rather than a single Application Insights app. Strictly read-only — never runs any az command that creates, updates, or deletes a resource or its data.
---

# Log Analytics Workspace Debugging

Read-only KQL investigation against the shared Log Analytics Workspace using
`az monitor log-analytics query` (Azure CLI). Same KQL language as Application
Insights, but a different scope: this workspace aggregates platform/diagnostic logs
from multiple resources (App Service, Azure SQL if configured, Activity Log, etc.),
not just app-level telemetry.

Use the **app-insights-kql** skill instead when the question is about application-level
telemetry (exceptions, custom traces, request timings) that already lives in App
Insights — many App Insights resources are actually backed by this same workspace, so
check with the user or query `AppTraces`/`AppExceptions` here first if unsure.

## 0. Load config

```bash
set -a; source ~/.agents/.env; set +a
echo "Workspace: $AZURE_LOG_ANALYTICS_WORKSPACE | RG: $RESOURCE_GROUP | Sub: $SUBSCRIPTION"
az account set --subscription "$SUBSCRIPTION"
```

The CLI query command needs the workspace's **customer ID (GUID)**, not its name.
Resolve it once per session and reuse:

```bash
WORKSPACE_ID=$(az monitor log-analytics workspace show \
  --resource-group "$RESOURCE_GROUP" \
  --workspace-name "$AZURE_LOG_ANALYTICS_WORKSPACE" \
  --query customerId -o tsv)
echo "$WORKSPACE_ID"
```

## 1. Read-only rule

Only ever use:
- `az monitor log-analytics query ...`
- `az monitor log-analytics workspace show ...`
- `az monitor log-analytics workspace table list/show ...` (schema discovery)

Never use `az monitor log-analytics workspace create/update/delete`,
`workspace-table create/update/delete`, saved-search or data-export mutating commands.
If the task seems to need a write operation (e.g. creating a saved query), stop and
tell the user this skill is read-only.

## 2. Core query command shape

```bash
az monitor log-analytics query \
  --workspace "$WORKSPACE_ID" \
  --analytics-query "<KQL HERE>" \
  -o table
```

Bound every query with a time filter (`ago()` or explicit `datetime` range) — this
workspace can hold logs from many resources and grow large.

## 3. Discover what's actually flowing into the workspace

If unsure which tables have data (depends on which diagnostic settings are enabled):

```bash
az monitor log-analytics query \
  --workspace "$WORKSPACE_ID" \
  --analytics-query "union withsource=TableName * | where TimeGenerated > ago(1d) | summarize count() by TableName | order by count_ desc" \
  -o table
```

Common tables for this stack:
- `AppServiceHTTPLogs` — IIS/Kestrel-level HTTP access logs for the App Service (both
  backend and frontend apps, distinguish via `_ResourceId` or `Host`).
- `AppServiceConsoleLogs` — stdout/stderr from the app process (useful if Serilog
  console sink is enabled).
- `AppServiceAppLogs` — App Service's own application logging pipe (if enabled in
  App Service diagnostic logs settings, separate from Serilog/App Insights).
- `AppServicePlatformLogs` — container start/stop, deployment, platform-level events.
- `AppServiceAuditLogs` — auth/SCM access events.
- `AppTraces`, `AppExceptions`, `AppRequests`, `AppDependencies` — present if the
  Application Insights resource is workspace-based (i.e. backed by this workspace).
  If so, this is an alternative path to the same data the app-insights-kql skill
  queries directly.
- `AzureDiagnostics` / resource-specific diagnostic tables — if Azure SQL or other
  resources have diagnostic settings pointed at this workspace.
- `AzureActivity` — control-plane operations (deployments, config changes, restarts)
  against resources in `$RESOURCE_GROUP`. Very useful to correlate "something changed"
  with "something broke".

## 4. Investigation playbook

### A. Correlate an incident with a deployment/restart/config change

```kql
AzureActivity
| where TimeGenerated > ago(24h)
| where ResourceGroup =~ "<RESOURCE_GROUP>"
| where ActivityStatusValue == "Success"
| project TimeGenerated, OperationNameValue, Caller, ResourceId
| order by TimeGenerated desc
```
Look for `Microsoft.Web/sites/restart`, `Microsoft.Web/sites/write` (config/slot
changes), or deployment-related entries right before the incident window.

### B. App Service HTTP-level errors (5xx/4xx) — before app code even runs

```kql
AppServiceHTTPLogs
| where TimeGenerated > ago(2h)
| where ScStatus >= 500
| project TimeGenerated, CsMethod, CsUriStem, ScStatus, TimeTaken, CIp
| order by TimeGenerated desc
```
Useful when App Insights shows nothing (e.g. the app crashed before the SDK could
initialize, or the platform itself returned the error).

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
`ExceptionType` instead of `type`, `TimeGenerated` instead of `timestamp`. Check with
`AppExceptions | take 1` if a query returns no results, to confirm you're on the right
schema.)

### F. Cross-resource timeline for an incident window

```kql
union AppServiceHTTPLogs, AppServiceConsoleLogs, AppServicePlatformLogs, AzureActivity
| where TimeGenerated between (datetime(2026-08-21T02:00:00Z) .. datetime(2026-08-21T03:00:00Z))
| project TimeGenerated, Type, Message = coalesce(Message, ResultDescription, OperationNameValue)
| order by TimeGenerated asc
```

## 5. Filtering to backend vs frontend App Service

Both apps may log into the same workspace. Filter by resource:

```kql
AppServiceHTTPLogs
| where _ResourceId has "<value of AZURE_APP_SERVICE_BACKEND>"
```
or check `Host`/`CsHost` if `_ResourceId` isn't populated for the table.

## 6. When to hand off to other skills/tools

- App-level exceptions/custom traces/request timings with rich correlation
  (`operation_Id`) → prefer **app-insights-kql** unless this workspace is confirmed to
  be the same backing store and you need a cross-resource join it can't do alone.
- The actual raw daily text log file written by the app (not structured telemetry) →
  **Azure Storage App Service logs** skill.
- Suspect DB-side cause (locking, slow query, connection errors) → **Azure SQL
  Database** skill.
- Need alert rules, metric charts, or Azure Monitor alert history rather than raw logs
  → **Azure Monitor** skill.
- Frontend-only issue reproducible in browser → Chrome DevTools MCP/plugin.

## 7. Output format for the user

Always include: time range queried, exact KQL used, table(s) queried, a concise
summary of findings, and a suggested next query or next skill. Never claim a fix was
applied — this skill only observes and reports.
