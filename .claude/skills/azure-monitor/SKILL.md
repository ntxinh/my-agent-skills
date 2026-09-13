---
name: azure-monitor
description: Read-only Azure Monitor investigation via Azure CLI — activity log (who/what/when changed a resource), platform metrics (CPU, memory, HTTP errors, DTU/DB metrics, storage throttling), configured alert rules and their firing history, diagnostic settings (verifying where logs/metrics are routed), autoscale history, and App Service resource health. Use this whenever the user asks "is X down", "why did it restart", "what changed", "check CPU/memory", "any alerts fired", "check resource health", or wants a cross-resource timeline correlating App Service + SQL + Storage around an incident. This is the control-plane / platform-metrics layer — hand off to app-insights-kql for application traces/exceptions, to log-analytics-workspace for KQL log queries, to storage-app-service-logs for raw daily log files, and to azure-sql-database for query-level DB diagnostics. NEVER runs any create/update/delete/set/restart command — strictly list/show/get.
---

# Azure Monitor (read-only)

Investigates infrastructure-level signals across the whole stack using
`az monitor` and related read-only `az` subcommands: **what changed**
(Activity Log), **how the resource is behaving** (Metrics), **what's already
been flagged** (Alerts), **where telemetry is routed** (Diagnostic Settings),
and **is Azure itself reporting a problem** (Resource Health).

This is usually the *first* skill to reach for when triaging "something's
wrong in prod" — it gives a fast timeline before diving into `app-insights-kql`
(traces/exceptions), `log-analytics-workspace` (KQL over logs),
`storage-app-service-logs` (raw Serilog files), or `azure-sql-database`
(query plans/blocking).

## Hard rule: read-only, no exceptions

Only ever use: `list`, `show`, `get`, `list-metrics`, `metrics list`,
`activity-log list`, `alert list`, `diagnostic-settings list/show`,
`autoscale show/list-history`, `resource-health` reads.

**Never** run: `set`, `create`, `update`, `delete`, `restart`, `stop`,
`start`, `deploy`, `az webapp restart`, `az sql db update`,
`az monitor alert create`, `az monitor diagnostic-settings create`, or
anything mutating. If the user asks for a fix/change, propose the command
but do not execute it — say so explicitly and wait for confirmation outside
this skill.

## Config resolution

This skill needs to know which Azure resources to look at, and — critically
— which **environment** (`qa` or `production`) to point at. Getting the
environment wrong can produce a misleading timeline, so:

1. **Determine the environment first.** If the user or the calling
   instruction hasn't specified `qa` or `production` (or it's ambiguous which
   they mean), **ask before proceeding.** Do not default to production or
   guess.

2. **Resolve config for that environment:**

   ```bash
   scripts/resolve_config.sh --env qa         # or: --env production
   ```

   This checks, in order:
   - `<repo-root>/.claude/azure-monitor.json` — project-specific override,
     found by walking up from the current directory to the git root.
   - `~/.claude/azure-monitor.json` — personal/global default, if the
     project file doesn't exist or doesn't define that environment.

   On success it prints the resolved JSON object (fields:
   `subscriptionId`, `resourceGroup`, and whichever of
   `appServiceBackendName`, `appServiceFrontendName`, `sqlServerName`,
   `sqlDatabaseName`, `storageAccountName` are needed) and exits 0.
   `subscriptionId` and `resourceGroup` are required — the script itself
   validates this. The others are optional and only matter if you're
   investigating that particular resource type.

3. **On failure (non-zero exit), do not guess values.** Follow the discovery
   flow in `references/discovery.md`: list candidate resources with
   read-only commands, confirm with the user, and offer (never assume) to
   save the result to the project config for next time.

See `assets/config.example.json` for the expected shape of both environment
blocks.

## Investigation areas

Once config is resolved and resource IDs are looked up, full command
examples for each area live in `references/commands.md`:

1. **Activity Log** — what changed, and who/what triggered it (always check first).
2. **Metrics** — CPU/memory/HTTP errors, DTU/DB metrics, storage throttling.
3. **Alerts** — configured rules, action groups, firing history.
4. **Diagnostic Settings** — where telemetry is actually routed.
5. **Autoscale** — did scaling cause or fail to prevent the issue.
6. **Resource Health** — is this an Azure-side outage.

`references/commands.md` also has the suggested triage workflow (anchor the
time window → Activity Log → Metrics → Alerts → hand off if needed) and
output-hygiene notes (prefer `-o table`, always state the UTC window used,
lead with Activity Log findings over raw metrics when summarizing).
