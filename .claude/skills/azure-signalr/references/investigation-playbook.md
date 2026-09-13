# Azure SignalR Service — Investigation Playbook

This file contains the full command set for investigating a SignalR-backed real-time
connectivity issue. Load it once you know the environment and have resolved config via
`scripts/resolve_config.sh` (see `SKILL.md`).

All commands below assume these shell variables are already set from the resolved
config (see the "Using resolved config in commands" section of `SKILL.md`):

- `$SUBSCRIPTION_ID`
- `$RESOURCE_GROUP`
- `$SERVICE_NAME`
- `$SIGNALR_ID` — the service's Azure resource ID (`az signalr show --query id`)

## 1. Service config — "what mode/scale are we actually running"

```bash
az signalr show -g "$RESOURCE_GROUP" -n "$SERVICE_NAME" \
  --query "{sku:sku.name, unitCount:sku.capacity, serviceMode:features[?properties.ServiceMode].properties.ServiceMode | [0], hostName:hostName, state:provisioningState}" -o json

# CORS allowed origins — mismatch here explains a lot of "connection refused" from the Angular app
az signalr cors show -g "$RESOURCE_GROUP" -n "$SERVICE_NAME" -o json

# Upstream settings — only relevant in Serverless mode (Functions-based hubs)
az signalr upstream show -g "$RESOURCE_GROUP" -n "$SERVICE_NAME" -o json
```

Service mode matters a lot for where to look next: **Default** mode means the ASP.NET Core app itself hosts hub logic (check `app-insights-kql` for hub exceptions); **Serverless** means an upstream (often Azure Functions) handles events — a failure there won't show up in the App Service's own logs at all.

## 2. Connection counts & limits — via Metrics

```bash
az monitor metrics list --resource "$SIGNALR_ID" \
  --metric "ConnectionCount" "ConnectionOpenCount" "ConnectionCloseCount" "ConnectionQuotaUtilization" \
  --interval PT5M --start-time "$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%MZ)" \
  -o table
```

`ConnectionQuotaUtilization` near 100% means the provisioned unit count's connection limit is hit — new clients get rejected, which surfaces to users as "real-time updates stopped working" with no obvious backend error. Check this before looking anywhere else if the report is "some users affected, others fine."

## 3. Message throughput & throttling

```bash
az monitor metrics list --resource "$SIGNALR_ID" \
  --metric "MessageCount" "InboundTraffic" "OutboundTraffic" "ServerLoad" \
  --interval PT5M --start-time "$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%MZ)" \
  -o table
```

SignalR Service enforces a per-unit message quota; if `MessageCount` is spiking (e.g. a hub method broadcasting too frequently or to too large a group) alongside client-visible delays, this is the first place it shows.

## 4. Connection close reasons — via diagnostic/connectivity logs

```bash
az monitor diagnostic-settings list --resource "$SIGNALR_ID" -o table
```

If routed to the shared Log Analytics workspace, hand off to `log-analytics-workspace` with starting queries against the SignalR resource-specific tables (category names typically `ConnectivityLogs`, `MessagingLogs`, `HttpRequestLogs`):

```kusto
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.SIGNALRSERVICE"
| where Category == "ConnectivityLogs"
| where TimeGenerated > ago(1h)
| project TimeGenerated, connectionId_s, userId_s, message_s
| order by TimeGenerated desc

AzureDiagnostics
| where ResourceProvider == "MICROSOFT.SIGNALRSERVICE"
| where Category == "HttpRequestLogs"
| where TimeGenerated > ago(1h)
| where statusCode_d >= 400
| project TimeGenerated, requestUri_s, statusCode_d, message_s
```

Connectivity logs give the actual disconnect reason (client-initiated, timeout, transport error, server shutdown/scale event) — this is usually more informative than App Insights, which only sees the ASP.NET Core side of the negotiate handshake.

## 5. Health check

```bash
curl -s -o /dev/null -w "%{http_code}\n" "https://$(az signalr show -g "$RESOURCE_GROUP" -n "$SERVICE_NAME" --query hostName -o tsv)/api/health"
```

A non-200 here means the service itself is unhealthy — cross-check with `azure-monitor`'s resource-health command before assuming an application bug.

## 6. Activity log — scale/restart/config-change events

```bash
az monitor activity-log list -g "$RESOURCE_GROUP" --resource-id "$SIGNALR_ID" \
  --start-time "$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%MZ)" -o table
```

A unit-count change or restart explains a mass-disconnect event far better than any application-side hypothesis — check this first if "everyone got disconnected at the same instant."

## Suggested triage workflow

1. **"Real-time updates stopped for some/all users"** → step 2 (`ConnectionQuotaUtilization`) → step 6 (was there a scale/restart event) → step 5 (health check).
2. **"Negotiate/connection refused from the browser"** → pair with `chrome-devtools-frontend` to see the actual negotiate response/status code first → step 1 (CORS config) → step 4 (HttpRequestLogs for 4xx on negotiate).
3. **"Messages delayed or dropped"** → step 3 (MessageCount/ServerLoad) → step 1 (confirm service mode — Serverless upstream failures won't show in App Insights).
4. **"Clients randomly disconnect"** → step 4 (ConnectivityLogs disconnect reason) is far more informative than guessing from client-side symptoms alone.
