---
name: log-analytics-workspace
description: Query the Azure Log Analytics Workspace using KQL via Azure CLI to debug platform-level and cross-resource issues — App Service platform/HTTP/console/app logs, diagnostic settings data, Azure SQL diagnostics (if wired to this workspace), Activity Log entries, and any resource sending logs/metrics into this workspace. Use this skill whenever the user asks about App Service platform logs, HTTP logs, container/console logs, deployment logs, restarts, scaling events, resource health, or wants a query that spans multiple Azure resources rather than a single Application Insights app. Strictly read-only — never runs any az command that creates, updates, or deletes a resource or its data.
---

# Log Analytics Workspace Debugging

Read-only KQL investigation against the shared Log Analytics Workspace using
`az monitor log-analytics query` (Azure CLI). Same KQL language as
Application Insights, but a different scope: this workspace aggregates
platform/diagnostic logs from multiple resources (App Service, Azure SQL if
configured, Activity Log, etc.), not just app-level telemetry.

Use the **app-insights-kql** skill instead when the question is about
application-level telemetry (exceptions, custom traces, request timings)
that already lives in App Insights — many App Insights resources are
actually backed by this same workspace, so check with the user or query
`AppTraces`/`AppExceptions` here first if unsure.

## Read-only rule

Only ever use:
- `az monitor log-analytics query ...`
- `az monitor log-analytics workspace show ...`
- `az monitor log-analytics workspace table list/show ...` (schema
  discovery)

Never use `az monitor log-analytics workspace create/update/delete`,
`workspace-table create/update/delete`, saved-search or data-export mutating
commands. If the task seems to need a write operation (e.g. creating a
saved query), stop and tell the user this skill is read-only.

## Config resolution

This skill needs to know which Azure resources to look at, and — critically
— which **environment** (`qa` or `production`) to point at. Getting the
environment wrong can produce a misleading timeline, so:

1. **Determine the environment first.** If the user or the calling
   instruction hasn't specified `qa` or `production` (or it's ambiguous
   which they mean), **ask before proceeding.** Do not default to
   production or guess.

2. **Resolve config for that environment:**

   ```bash
   scripts/resolve_config.sh --env qa         # or: --env production
   ```

   This checks, in order:
   - `<repo-root>/.claude/log-analytics-workspace.json` — project-specific
     override, found by walking up from the current directory to the git
     root.
   - `~/.claude/log-analytics-workspace.json` — personal/global default, if
     the project file doesn't exist or doesn't define that environment.

   On success it prints the resolved JSON object with fields
   `subscriptionId`, `resourceGroup`, `logAnalyticsWorkspaceName` (all
   required — the script validates this), and optionally
   `appServiceBackendName` and `appServiceFrontendName` (needed only for the
   backend/frontend filtering examples in `references/commands.md`, not for
   general queries).

3. **On failure (non-zero exit), do not guess values.** Follow the
   discovery flow in `references/discovery.md`: list candidate resources
   with read-only commands, confirm with the user, and offer (never
   assume) to save the result to the project config for next time.

See `assets/config.example.json` for the expected shape of both environment
blocks.

## Investigation reference

Once config is resolved and the workspace's customer ID (GUID) is looked up,
the full query playbook lives in `references/commands.md`:

- **Core query command shape** and the requirement to bound every query
  with a time filter.
- **Table discovery** — which tables actually have data in this workspace.
- **Investigation playbook (A–F)**: correlating an incident with a
  deployment/restart, App Service HTTP-level errors, platform-level
  crashes/restarts, console/stdout logs, workspace-based App Insights
  tables, and a cross-resource timeline query.
- **Filtering to backend vs. frontend App Service** by resource.
- **Hand-off guidance** to `app-insights-kql`, the Storage App Service logs
  skill, `azure-sql-database`, `azure-monitor`, and browser devtools for
  what this skill can't answer directly.
- **Output format** — always report the time range queried, exact KQL used,
  tables queried, and a summary; never claim a fix was applied.
