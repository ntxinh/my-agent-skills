---
name: app-insights-kql
description: Query Azure Application Insights using KQL (Kusto Query Language) via Azure CLI to debug backend/frontend issues — exceptions, failed requests, slow dependencies, custom traces/logs, and distributed traces (OpenTelemetry spans, Serilog structured logs). Use this skill whenever the user wants to investigate an error, exception, 500/timeout, slow API, failed request, or "what happened around time X" for the ASP.NET Core backend or Angular frontend, or explicitly mentions Application Insights, App Insights, KQL, traces, or requests telemetry. Strictly read-only — never runs any az command that creates, updates, or deletes a resource.
---

# Application Insights KQL Debugging

Read-only investigation of Application Insights telemetry (requests, dependencies,
exceptions, traces, customEvents) using `az monitor app-insights query` (Azure CLI).
No write/mutating Azure commands are ever used by this skill.

## 0. Load config

Resource identifiers live in `~/.agents/.env`. Always source it first (don't hardcode
names you find in this file into memory across sessions — re-read each time):

```bash
set -a; source ~/.agents/.env; set +a
echo "App Insights: $AZURE_APPLICATION_INSIGHTS | RG: $RESOURCE_GROUP | Sub: $SUBSCRIPTION"
```

Confirm the right subscription/login context before querying:

```bash
az account show --query "{name:name, id:id}" -o table
# If needed:
az account set --subscription "$SUBSCRIPTION"
```

## 1. Read-only rule

Only ever use:
- `az monitor app-insights query ...`
- `az monitor app-insights component show ...`
- `az monitor app-insights metrics show ...` (if needed for aggregate metrics)

Never use `az monitor app-insights component create/update/delete`,
`az monitor app-insights api-key create`, or any `az ... create|update|delete|set`
command against any resource. If a task seems to require a write operation, stop and
tell the user this skill is read-only and ask how they'd like to proceed.

## 2. Core query command shape

```bash
az monitor app-insights query \
  --app "$AZURE_APPLICATION_INSIGHTS" \
  --resource-group "$RESOURCE_GROUP" \
  --analytics-query "<KQL HERE>" \
  -o table
```

Tips:
- Wrap the KQL string in single quotes at the shell level if it contains double quotes,
  or use a heredoc/variable to avoid escaping headaches for long queries.
- Default output `-o table` is good for scanning; use `-o json` when you need to
  pass fields (like `operation_Id`) into a follow-up query.
- Always bound queries with a `timespan`/`ago()` filter — App Insights data volume can
  be large. Default to a recent, narrow window (last 1–6 hours) unless the user
  specifies a time range or incident time.

## 3. Investigation playbook

### A. "Something broke around time X" — start broad, then narrow

1. **Failed requests overview**
```kql
requests
| where timestamp between (datetime(2026-08-21T02:00:00Z) .. datetime(2026-08-21T03:00:00Z))
| where success == false
| summarize count() by resultCode, name
| order by count_ desc
```

2. **Exceptions in that window**
```kql
exceptions
| where timestamp between (datetime(2026-08-21T02:00:00Z) .. datetime(2026-08-21T03:00:00Z))
| summarize count() by type, method, outerMessage
| order by count_ desc
```

3. **Pick one `operation_Id` and pull the full trace** (correlates across
   requests/dependencies/traces/exceptions — this is the key OpenTelemetry/App
   Insights correlation field):
```kql
union requests, dependencies, exceptions, traces
| where operation_Id == "<paste operation_Id>"
| order by timestamp asc
| project timestamp, itemType, name, message, resultCode, duration, severityLevel, customDimensions
```

### B. Slow / latency investigation

```kql
requests
| where timestamp > ago(2h)
| summarize p50=percentile(duration,50), p95=percentile(duration,95), p99=percentile(duration,99), count() by name
| order by p95 desc
```

Then drill into dependencies (Azure SQL calls, HTTP calls to other services) for the
slow operation:
```kql
dependencies
| where timestamp > ago(2h)
| where operation_Name == "<slow operation name>"
| summarize p50=percentile(duration,50), p95=percentile(duration,95), count() by target, type, name
| order by p95 desc
```

### C. Serilog structured logs / custom traces (traces table)

Serilog + OpenTelemetry typically lands in `traces` with `severityLevel` and structured
properties in `customDimensions`.

```kql
traces
| where timestamp > ago(1h)
| where severityLevel >= 3  // 3=Error, 4=Critical (0=Verbose,1=Info,2=Warning)
| project timestamp, message, severityLevel, customDimensions
| order by timestamp desc
```

Search log messages for a keyword (e.g. a user id, order id, correlation id used in
Serilog enrichers):
```kql
traces
| where timestamp > ago(6h)
| where message has "OrderId=12345" or tostring(customDimensions.OrderId) == "12345"
| order by timestamp asc
```

### D. Exceptions deep-dive (stack trace + inner exception)

```kql
exceptions
| where timestamp > ago(6h)
| where type == "System.Data.SqlClient.SqlException" // adjust
| project timestamp, outerMessage, innermostMessage, details, operation_Id
| order by timestamp desc
| take 20
```
`details` contains the parsed stack frames as a dynamic array — use `-o json` to
inspect it fully rather than the truncated table view.

### E. Frontend (Angular) telemetry, if App Insights JS SDK is wired in

```kql
pageViews
| where timestamp > ago(2h)
| summarize count() by name, client_Browser

exceptions
| where timestamp > ago(2h)
| where cloud_RoleName == "<frontend role name>" or client_Type == "Browser"
| project timestamp, outerMessage, url
```
If the frontend isn't emitting its own App Insights telemetry, rely on the Chrome
DevTools MCP/plugin instead (network tab, console errors) — see note in section 5.

## 4. Correlating with the backend App Service

Requests' `cloud_RoleName` should match `$AZURE_APP_SERVICE_BACKEND` (or the
`APPLICATIONINSIGHTS_ROLE_NAME` set on the App Service). Filter by it when the App
Insights resource is shared across multiple apps:

```kql
requests
| where cloud_RoleName == "<value of AZURE_APP_SERVICE_BACKEND>"
| where timestamp > ago(1h)
```

## 5. When to hand off to other skills/tools

- Raw daily log files (not in App Insights) → use the **Azure Storage App Service logs**
  skill.
- Need to correlate with platform-level logs (App Service platform logs, container
  logs) or run saved Log Analytics queries across multiple resources → use the
  **Log Analytics Workspace** skill (same KQL language, different scope/tables:
  `AppServiceHTTPLogs`, `AppServiceConsoleLogs`, `AppServiceAppLogs`, etc.).
- Need DB-side evidence (blocking, query duration, errors in SQL itself) → use the
  **Azure SQL Database** skill.
- Suspect the issue is only reproducible in-browser (rendering, console errors, failed
  network calls, CORS) → use Chrome DevTools MCP/plugin if connected; don't try to
  force this into App Insights KQL if the frontend isn't instrumented.
- Need resource health / alerts / activity log → use the **Azure Monitor** skill.

## 6. Output format for the user

When reporting findings, always include:
1. The time range queried.
2. The exact KQL used (so it's reproducible).
3. A short summary of what was found (counts, top offenders, a representative
   `operation_Id` or exception message).
4. Suggested next KQL query or next skill to use if the root cause isn't yet clear.

Never claim a fix was applied — this skill only observes and reports.
