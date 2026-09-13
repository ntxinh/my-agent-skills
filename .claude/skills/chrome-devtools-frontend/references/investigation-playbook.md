# Chrome DevTools Frontend Debugging — Investigation Playbook

This file contains the step-by-step browser investigation procedures and the handoff
checklist. Load it once the Chrome DevTools MCP tool is confirmed connected and (if
needed) config has been resolved via `scripts/resolve_config.sh` (see `SKILL.md`).

All steps below assume these shell variables are already set from the resolved
config, when a step needs them (see the "Using resolved config" section of
`SKILL.md`):

- `$SUBSCRIPTION_ID`
- `$RESOURCE_GROUP`
- `$FRONTEND_APP_SERVICE_NAME`
- `$BACKEND_APP_SERVICE_NAME`
- `$FRONTEND_HOSTNAME` / `$BACKEND_HOSTNAME` — the two origins (`az webapp show --query defaultHostName`), used to distinguish first-party calls from third-party noise in the Network tab

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
> Frontend sent `GET /api/orders/123` at 2026-08-21T09:14:02Z, got a 500, response body `traceId: 00-4bf9...-01`. Backend App Service is `$BACKEND_APP_SERVICE_NAME`. → passing this trace ID to `app-insights-kql` to pull the matching exception.

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
4. **Which App Service** (`$BACKEND_APP_SERVICE_NAME` vs `$FRONTEND_APP_SERVICE_NAME`) is involved — a frontend hosting issue (Angular files not served, wrong SPA fallback routing) is a different problem from a backend API failure, both live in App Service but need different follow-up skills (`azure-monitor` activity log for the frontend App Service vs `app-insights-kql` for the backend API).
