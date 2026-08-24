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

Know the two frontend/backend origins from the env file so you can distinguish first-party calls from third-party noise:

```bash
set -a; source ~/.agents/.env; set +a
az webapp show -g "$RESOURCE_GROUP" -n "$AZURE_APP_SERVICE_FRONTEND" --query defaultHostName -o tsv
az webapp show -g "$RESOURCE_GROUP" -n "$AZURE_APP_SERVICE_BACKEND" --query defaultHostName -o tsv
```

## 1. Reproduce and capture console errors

1. Navigate to the affected page/route.
2. Open the Console panel; perform the read-only interaction that triggers the bug (page load, non-destructive click, navigation).
3. Capture: error message, stack trace, source file/line, and whether it's an uncaught exception, an Angular `ExpressionChangedAfterItHasBeenCheckedError`, a `ChangeDetectionError`, a zone.js error, or a plain network failure surfacing as a console error.
4. Note the exact timestamp (browser local time) — you'll need to convert to UTC when cross-referencing backend logs.

## 2. Inspect the Network tab for the failing request

For the specific request that's failing or slow:

- **Status code** and whether it's client (4xx) or server (5xx).
- **Request headers** — especially any distributed tracing headers: `traceparent` (W3C Trace Context, standard with OpenTelemetry), `request-id` (older ASP.NET Core convention), or a custom correlation header if the app uses one. **This is the key artifact to extract** — it's the join key into Application Insights / Log Analytics.
- **Request payload** — confirm the Angular app is actually sending what's expected (correct shape, auth header present, correct API base URL for the environment).
- **Response body** — ASP.NET Core problem-details responses often include a `traceId` field directly; grab that too, it's usually the same as the `traceparent` trace ID.
- **Timing breakdown** — DNS/connect/TTFB/download — TTFB dominating means it's a backend/infra problem (hand off to `azure-monitor` or `app-insights-kql`), download dominating means payload size or client network.

Extract and hand off, e.g.:
> Frontend sent `GET /api/orders/123` at 2026-08-21T09:14:02Z, got a 500, response body `traceId: 00-4bf9...-01`. Backend App Service is `$AZURE_APP_SERVICE_BACKEND`. → passing this trace ID to `app-insights-kql` to pull the matching exception.

## 3. CORS / mixed-origin issues

Angular calling the backend App Service is a classic CORS surface. Check for:
- Console error text (`has been blocked by CORS policy...`) — note whether it's missing `Access-Control-Allow-Origin`, a preflight (`OPTIONS`) failure, or a credentials mismatch.
- In the Network tab, find the `OPTIONS` preflight request (if any) and check its response headers vs the actual request's `Origin` header.
- This is a config issue on the backend (CORS policy in `Program.cs`/`Startup.cs`), not fixable from the browser — report exactly which origin/header/method was rejected so it can be fixed server-side.

## 4. Angular-specific state inspection (read-only)

With Angular DevTools or plain console evaluation:
- Inspect component inputs/outputs and current change-detection state for a component that isn't updating.
- Check `NgRx`/service-level state (if used) via console (`ng.getComponent($0)` style APIs are read-only introspection, safe to use).
- Confirm environment config actually loaded (`environment.apiUrl` etc.) to rule out a build/deploy pointing at the wrong backend.

## 5. Performance / slow page

Use the Performance panel or Network waterfall for:
- Large bundle downloads (check for missing lazy-loading / large vendor chunks).
- Waterfall showing sequential requests that could be parallel.
- Long tasks blocking the main thread (zone.js change detection storms are a common Angular culprit).

## Handoff checklist

When escalating to a backend-side skill, always pass along:
1. **UTC timestamp** of the failing request (convert from browser local time).
2. **Trace ID / request ID** extracted from headers or response body, if present.
3. **Exact URL, method, and status code**.
4. **Which App Service** (`$AZURE_APP_SERVICE_BACKEND` vs `$AZURE_APP_SERVICE_FRONTEND`) is involved — a frontend hosting issue (Angular files not served, wrong SPA fallback routing) is a different problem from a backend API failure, both live in App Service but need different follow-up skills (`azure-monitor` activity log for the frontend App Service vs `app-insights-kql` for the backend API).
