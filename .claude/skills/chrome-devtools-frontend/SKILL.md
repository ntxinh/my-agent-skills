---
name: chrome-devtools-frontend
description: Read-only, live browser-side debugging of the Angular frontend using the Chrome DevTools MCP/plugin — console errors, failed network requests, request/response payloads, headers, timing/waterfall, and correlating a failing frontend call with its backend trace via distributed-tracing headers (traceparent / request-id / OpenTelemetry trace ID). Use this whenever the user reports something broken *in the browser* — a blank page, a button that does nothing, a form that won't submit, a CORS error, a slow page load, a 4xx/5xx surfaced in the UI — or asks to "check the network tab", "see the console", "reproduce this in the browser", or "trace this request end to end". This is the client-side layer of the debugging toolkit — once you have a trace ID or timestamp from here, hand off to app-insights-kql or log-analytics-workspace to pull the matching backend trace, and to azure-monitor for infra-level App Service metrics at that moment. NEVER submits forms, clicks destructive buttons, changes application state, or modifies data — observe and reproduce read-only interactions only (navigation, opening dev tools panels, reading network/console output).
---

# Chrome DevTools Frontend Debugging (read-only)

Investigates bugs that only show up **in the browser**, on the Angular app, using the Chrome DevTools MCP/plugin. This is the client-side counterpart to the other five skills: it tells you *what the browser actually sent and received*, then hands off a trace ID / timestamp so the backend-side skills can pick up the same request server-side.

## Hard rule: observe, don't mutate

Allowed: navigating to pages, opening the Console/Network/Performance panels, reading logs, reading request/response headers and bodies, reading timing data, taking screenshots, evaluating **read-only** expressions in the console (e.g. `localStorage.getItem(...)`, reading Angular component state via dev tools) to inspect state.

**Never**: submit forms that create/update/delete data, click buttons that trigger real mutations (checkout, delete, save) unless the user explicitly asks you to reproduce a specific bug and confirms it's safe to do so, clear storage/cookies, or run console expressions that write/delete data (`localStorage.clear()`, `fetch(..., {method:'POST'})`, etc.). If reproducing the bug requires a mutating action, say so and ask the user to confirm before doing it.

## When to reach for this vs. the other skills

| Symptom | Skill |
|---|---|
| "Page is broken / blank / button does nothing" | **this skill**, first |
| "API call fails in the browser, what happened server-side" | this skill to get the trace ID → then `app-insights-kql` |
| "Backend exception, need to know what the frontend sent" | this skill (Network tab) |
| "Slow page overall" | this skill (Performance/waterfall) → `azure-monitor` for backend metrics at that time |
| "Need historical/aggregated frontend errors" | frontend App Insights isn't in this env — check if `app-insights-kql`'s AI resource ingests browser telemetry; otherwise this skill is live-repro only |

## Setup

Confirm the Chrome DevTools MCP tool is connected before starting. If it isn't, say so and offer to fall back to asking the user to paste console/network output manually.

### Configuration

Connection settings (the two App Service names) live in a small JSON config, resolved per environment — not in a `.env` file.

**Step 1 — determine the environment.** Exactly two environments are supported: `qa` and `production`. If the user's instruction names one, use it. If it's unspecified or ambiguous, **ask before proceeding** — reading the wrong environment's App Service names means you'll compare origins against the wrong hosts and any CORS/trace-ID handoff will be wrong.

**Step 2 — resolve config:**

```bash
scripts/resolve_config.sh --env qa        # or: --env production
```

The script checks, in order:
1. **Project override** — walks up from the current directory to the nearest git root, then reads `<repo-root>/.claude/chrome-devtools-frontend.json`.
2. **Personal/global default** — `~/.claude/chrome-devtools-frontend.json`.
3. If neither file defines the requested environment, it exits non-zero (exit code `1`). **Fall through to the discovery flow below — never fabricate values.**

On success, it prints one JSON object with the resolved fields on stdout (exit `0`), after validating that all required fields are present.

**Step 3 — discovery flow (only if resolution fails):**
1. Run `az webapp list -g <resource-group>` (or `az group list` first if the resource group is also unknown) to find likely candidate frontend/backend App Services for the requested environment.
2. Confirm the match with the user, or let them pick from a short list if there's more than one candidate.
3. Ask whether to save the resolved values to the **project-level** config (`<repo-root>/.claude/chrome-devtools-frontend.json`) for next time.
4. **Never write the config file without the user's explicit confirmation.**

### Config fields

| Field | Required | Description |
|---|---|---|
| `subscriptionId` | Yes | Azure subscription ID or name containing the App Services, used for `az account set --subscription`. Included so origin lookups always target the intended subscription rather than whatever the CLI happens to have active. |
| `resourceGroup` | Yes | Resource group containing both App Services |
| `frontendAppServiceName` | Yes | The Angular app's App Service name, used with `az webapp show -n` |
| `backendAppServiceName` | Yes | The ASP.NET Core API's App Service name, used with `az webapp show -n` |

See `assets/config.example.json` for a filled-in example covering both environments.

### Using the resolved config

```bash
CONFIG=$(scripts/resolve_config.sh --env qa) || {
  # resolution failed — run the discovery flow instead of guessing
  exit 1
}

SUBSCRIPTION_ID=$(jq -r '.subscriptionId'            <<<"$CONFIG")
RESOURCE_GROUP=$(jq -r '.resourceGroup'              <<<"$CONFIG")
FRONTEND_APP_SERVICE_NAME=$(jq -r '.frontendAppServiceName' <<<"$CONFIG")
BACKEND_APP_SERVICE_NAME=$(jq -r '.backendAppServiceName'   <<<"$CONFIG")

az account set --subscription "$SUBSCRIPTION_ID"
FRONTEND_HOSTNAME=$(az webapp show -g "$RESOURCE_GROUP" -n "$FRONTEND_APP_SERVICE_NAME" --query defaultHostName -o tsv)
BACKEND_HOSTNAME=$(az webapp show -g "$RESOURCE_GROUP" -n "$BACKEND_APP_SERVICE_NAME" --query defaultHostName -o tsv)
```

With the two hostnames known, you can distinguish first-party calls from third-party noise in the Network tab.

## Investigation playbook

The step-by-step procedures — capturing console errors, inspecting the Network tab for a failing request, diagnosing CORS issues, Angular-specific state inspection, and performance/waterfall analysis — plus the handoff checklist for escalating to a backend-side skill, live in `references/investigation-playbook.md`. Load that file once the Chrome DevTools MCP tool is connected and (if needed) config is resolved.
