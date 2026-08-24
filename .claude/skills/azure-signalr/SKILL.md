---
name: azure-signalr
description: Read-only Azure SignalR Service investigation via Azure CLI — connection counts and limits, message throughput and throttling, service mode (Default/Serverless/Classic) and unit/replica scale, CORS and upstream (serverless) config, health endpoint status, and resource/connectivity/messaging logs. Use whenever the user reports "clients keep disconnecting", "SignalR connection refused / 429", "real-time updates not arriving", "negotiate failing", "hub method not firing", or wants to check SignalR config/metrics for the ASP.NET Core backend's real-time features. Complements app-insights-kql (server-side hub exceptions) and chrome-devtools-frontend (client-side WebSocket/negotiate failures in the Angular app). NEVER restarts, scales, regenerates keys, or changes CORS/upstream config — list/show/metrics/log reads only.
---

# Azure SignalR Service (read-only)

Investigates real-time-connectivity issues between the Angular frontend and the ASP.NET Core backend's SignalR hubs. Sits between `chrome-devtools-frontend` (what the browser's WebSocket/negotiate call actually did) and `app-insights-kql` (what the hub method did server-side) — this skill covers the managed SignalR service itself: capacity, connection state, and service-level errors.

## Hard rule: read-only, no exceptions

Only ever use: `list`, `show`, `list-keys` (reading, not rotating), metrics/log reads, and GET requests to the service's own `/api/health` endpoint.

**Never** run: `az signalr create/update/delete`, `az signalr key renew`, `az signalr restart`, `az signalr scale`, `az signalr cors update`, `az signalr upstream update`, or `az signalr network-rule update`. If a fix requires scaling units, changing CORS, or updating upstream URLs (serverless mode), propose it — don't execute it.

## Setup

Add this to `~/.agents/.env` if not already present:

```ini
AZURE_SIGNALR_SERVICE=
```

```bash
set -a; source ~/.agents/.env; set +a
az account set --subscription "$SUBSCRIPTION"

SIGNALR_ID=$(az signalr show -g "$RESOURCE_GROUP" -n "$AZURE_SIGNALR_SERVICE" --query id -o tsv)
```

## 1. Service config — "what mode/scale are we actually running"

```bash
az signalr show -g "$RESOURCE_GROUP" -n "$AZURE_SIGNALR_SERVICE" \
  --query "{sku:sku.name, unitCount:sku.capacity, serviceMode:features[?properties.ServiceMode].properties.ServiceMode | [0], hostName:hostName, state:provisioningState}" -o json

# CORS allowed origins — mismatch here explains a lot of "connection refused" from the Angular app
az signalr cors show -g "$RESOURCE_GROUP" -n "$AZURE_SIGNALR_SERVICE" -o json

# Upstream settings — only relevant in Serverless mode (Functions-based hubs)
az signalr upstream show -g "$RESOURCE_GROUP" -n "$AZURE_SIGNALR_SERVICE" -o json
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
curl -s -o /dev/null -w "%{http_code}\n" "https://$(az signalr show -g "$RESOURCE_GROUP" -n "$AZURE_SIGNALR_SERVICE" --query hostName -o tsv)/api/health"
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

## Output hygiene

- Always state the **service mode** (Default/Serverless/Classic) up front — it changes which other skill has the relevant server-side logs.
- Report `ConnectionQuotaUtilization` alongside the actual unit count/SKU — "at 100%" means something different at Unit=1 vs Unit=10.
- Flag scaling/CORS/upstream config changes as proposed fixes for a human to apply — this skill only reads the current state.
