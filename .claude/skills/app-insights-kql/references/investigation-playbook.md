# Investigation Playbook

Load this file when you need one of the KQL patterns below. Resolve config
(`appInsightsName`, `resourceGroup`, `backendRoleName`) first — see SKILL.md section 0.

## A. "Something broke around time X" — start broad, then narrow

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

## B. Slow / latency investigation

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

## C. Serilog structured logs / custom traces (traces table)

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

## D. Exceptions deep-dive (stack trace + inner exception)

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

## E. Frontend (Angular) telemetry, if App Insights JS SDK is wired in

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
DevTools MCP/plugin instead (network tab, console errors) — don't force this into App
Insights KQL if the frontend isn't instrumented.

## F. Correlating with the backend App Service

Requests' `cloud_RoleName` should match the resolved `backendRoleName` (typically the
`APPLICATIONINSIGHTS_ROLE_NAME` set on the App Service). Filter by it when the App
Insights resource is shared across multiple apps:

```kql
requests
| where cloud_RoleName == "<backendRoleName>"
| where timestamp > ago(1h)
```
