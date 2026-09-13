---
name: app-insights-kql
description: Query Azure Application Insights using KQL (Kusto Query Language) via Azure CLI to debug backend/frontend issues — exceptions, failed requests, slow dependencies, custom traces/logs, and distributed traces (OpenTelemetry spans, Serilog structured logs). Use this skill whenever the user wants to investigate an error, exception, 500/timeout, slow API, failed request, or "what happened around time X" for the ASP.NET Core backend or Angular frontend, or explicitly mentions Application Insights, App Insights, KQL, traces, or requests telemetry. Strictly read-only — never runs any az command that creates, updates, or deletes a resource.
---

# Application Insights KQL Debugging

Read-only investigation of Application Insights telemetry (requests, dependencies,
exceptions, traces, customEvents) using `az monitor app-insights query` (Azure CLI).
No write/mutating Azure commands are ever used by this skill.

## 0. Resolve config

Config differs per environment (**QA** vs **Production**) and can also differ per
project/repo. Resolve it fresh every time — never reuse values you happened to see in
a previous session.

**Step 1 — Determine the environment.** The user's request should make clear whether
they mean QA or Production (e.g. an explicit `--env qa`, or wording like "check QA" /
"on prod"). If it's ambiguous, ask before proceeding — querying the wrong environment
can produce misleading results.

**Step 2 — Resolve the config file**, in this priority order:

1. `<repo-root>/.claude/app-insights-kql.json` — project-specific override. Found by
   walking up from the current working directory to the git root.
2. `~/.claude/app-insights-kql.json` — personal/global default, used when the repo has
   no override.

Run:
```bash
bash scripts/resolve_config.sh --env <qa|production>
```
The script checks both locations in that order and prints the resolved values for the
requested environment as JSON. It exits non-zero if neither file has that environment
defined.

**Step 3 — If resolution fails, go to 0.1 (discovery flow).** Don't ask the user to
type raw resource IDs before trying to find them yourself.

Confirm the right subscription/login context before querying:
```bash
az account show --query "{name:name, id:id}" -o table
az account set --subscription "<subscriptionId>"   # if needed
```

### 0.1 Discovery flow (no config found for this repo/env)

```bash
az monitor app-insights component show --query "[].{name:name, rg:resourceGroup}" -o table
```

- Prefer entries whose name resembles the current repo/folder name, the requested
  environment (qa/prod), or an already-active default resource group
  (`az config get defaults.group`).
- One clear match → confirm briefly with the user, then use it.
- Several plausible matches → list up to 5–8 and ask the user to pick.
- None found → ask the user for the App Insights name or resource group to narrow
  the search.

Once you have `appInsightsName` + `resourceGroup` (+ `subscriptionId` if the user has
more than one subscription), **ask if they want it saved**. Default suggestion:
`<repo-root>/.claude/app-insights-kql.json` under the resolved environment's key, so
the next run for this repo/env skips discovery (see `assets/config.example.json` for
the exact shape). Only write the file after they confirm.

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
  --app "<appInsightsName>" \
  --resource-group "<resourceGroup>" \
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

Detailed KQL patterns (failed requests, exception deep-dive, latency, Serilog traces,
frontend telemetry, correlating with the backend App Service) are in
`references/investigation-playbook.md`. Load that file when you actually need one of
these patterns rather than keeping it all in context up front.

## 4. When to hand off to other skills/tools

- Raw daily log files (not in App Insights) → **Azure Storage App Service logs** skill.
- Platform-level logs (App Service platform logs, container logs) or saved Log
  Analytics queries across multiple resources → **Log Analytics Workspace** skill
  (same KQL, different scope/tables: `AppServiceHTTPLogs`, `AppServiceConsoleLogs`,
  `AppServiceAppLogs`).
- DB-side evidence (blocking, query duration, errors in SQL itself) → **Azure SQL
  Database** skill.
- Issue only reproducible in-browser (rendering, console errors, failed network
  calls, CORS) → Chrome DevTools MCP/plugin if connected; don't force this into App
  Insights KQL if the frontend isn't instrumented.
- Resource health / alerts / activity log → **Azure Monitor** skill.

## 5. Output format for the user

When reporting findings, always include:
1. The environment and time range queried.
2. The exact KQL used (so it's reproducible).
3. A short summary of what was found (counts, top offenders, a representative
   `operation_Id` or exception message).
4. Suggested next KQL query or next skill to use if the root cause isn't yet clear.

Never claim a fix was applied — this skill only observes and reports.
