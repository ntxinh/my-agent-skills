---
name: azure-signalr
description: Read-only Azure SignalR Service investigation via Azure CLI — connection counts and limits, message throughput and throttling, service mode (Default/Serverless/Classic) and unit/replica scale, CORS and upstream (serverless) config, health endpoint status, and resource/connectivity/messaging logs. Use whenever the user reports "clients keep disconnecting", "SignalR connection refused / 429", "real-time updates not arriving", "negotiate failing", "hub method not firing", or wants to check SignalR config/metrics for the ASP.NET Core backend's real-time features. Complements app-insights-kql (server-side hub exceptions) and chrome-devtools-frontend (client-side WebSocket/negotiate failures in the Angular app). NEVER restarts, scales, regenerates keys, or changes CORS/upstream config — list/show/metrics/log reads only.
---

# Azure SignalR Service (read-only)

Investigates real-time-connectivity issues between the Angular frontend and the ASP.NET Core backend's SignalR hubs. Sits between `chrome-devtools-frontend` (what the browser's WebSocket/negotiate call actually did) and `app-insights-kql` (what the hub method did server-side) — this skill covers the managed SignalR service itself: capacity, connection state, and service-level errors.

## Hard rule: read-only, no exceptions

Only ever use: `list`, `show`, `list-keys` (reading, not rotating), metrics/log reads, and GET requests to the service's own `/api/health` endpoint.

**Never** run: `az signalr create/update/delete`, `az signalr key renew`, `az signalr restart`, `az signalr scale`, `az signalr cors update`, `az signalr upstream update`, or `az signalr network-rule update`. If a fix requires scaling units, changing CORS, or updating upstream URLs (serverless mode), propose it — don't execute it.

## Configuration

Connection settings live in a small JSON config, resolved per environment — not in a `.env` file.

### Step 1 — determine the environment

Exactly two environments are supported: `qa` and `production`. Querying the wrong one can produce misleading results, so:

- If the user's instruction names the environment (`qa`, `production`, or an obvious equivalent like "prod"), use that.
- If it's unspecified or ambiguous, **ask the user which environment before running anything.** Do not guess.

### Step 2 — resolve config for that environment

```bash
scripts/resolve_config.sh --env qa        # or: --env production
```

The script checks, in order:
1. **Project override** — walks up from the current directory to the nearest git root, then reads `<repo-root>/.claude/azure-signalr.json`.
2. **Personal/global default** — `~/.claude/azure-signalr.json`.
3. If neither file defines the requested environment, it exits non-zero (exit code `1`). **Fall through to the discovery flow below — never fabricate values.**

On success, it prints one JSON object with the resolved fields on stdout (exit `0`), after validating that all required fields are present.

### Step 3 — discovery flow (only if resolution fails)

1. Run `az signalr list` (and `az group list` if the resource group is also unknown) to find likely candidate SignalR services for the requested environment.
2. Confirm the match with the user, or let them pick from a short list if there's more than one candidate.
3. Ask whether to save the resolved values to the **project-level** config (`<repo-root>/.claude/azure-signalr.json`) for next time.
4. **Never write the config file without the user's explicit confirmation.**

### Config fields

| Field | Required | Description |
|---|---|---|
| `subscriptionId` | Yes | Azure subscription ID or name containing the service, used for `az account set --subscription` |
| `resourceGroup` | Yes | Resource group containing the SignalR service |
| `serviceName` | Yes | The SignalR service name, used with `az signalr show/cors/upstream -n` |

All three fields are required — every step in this skill (config, CORS, upstream, metrics, health check, activity log) needs the resolved account context, so there's no meaningful "optional" field here.

See `assets/config.example.json` for a filled-in example covering both environments.

### Using the resolved config

```bash
CONFIG=$(scripts/resolve_config.sh --env qa) || {
  # resolution failed — run the discovery flow instead of guessing
  exit 1
}

SUBSCRIPTION_ID=$(jq -r '.subscriptionId' <<<"$CONFIG")
RESOURCE_GROUP=$(jq -r '.resourceGroup'   <<<"$CONFIG")
SERVICE_NAME=$(jq -r '.serviceName'       <<<"$CONFIG")

az account set --subscription "$SUBSCRIPTION_ID"
SIGNALR_ID=$(az signalr show -g "$RESOURCE_GROUP" -n "$SERVICE_NAME" --query id -o tsv)
```

With `$SIGNALR_ID`, `$RESOURCE_GROUP`, and `$SERVICE_NAME` set, proceed to the investigation commands.

## Investigation playbook

The full command set — service config/CORS/upstream, connection count & limit metrics, message throughput, connectivity/messaging logs, health check, and activity log — plus the suggested triage workflow (which step to start with for a given symptom) live in `references/investigation-playbook.md`. Load that file once the environment and config are resolved.

## Output hygiene

- Always state the **service mode** (Default/Serverless/Classic) up front — it changes which other skill has the relevant server-side logs.
- Report `ConnectionQuotaUtilization` alongside the actual unit count/SKU — "at 100%" means something different at Unit=1 vs Unit=10.
- Flag scaling/CORS/upstream config changes as proposed fixes for a human to apply — this skill only reads the current state.
