---
name: azure-sql-database
description: Investigate Azure SQL Database issues — connection errors, blocking/deadlocks, slow queries, timeouts, resource throttling (DTU/vCore limits), recent errors — using Azure CLI (az sql) for resource-level info and sqlcmd for read-only T-SQL (DMV) queries against the database itself. Use this skill whenever the user suspects the database is the cause of an API error/timeout, asks about slow queries, blocking, deadlocks, connection pool exhaustion, SQL errors, or wants to inspect table/schema/data as part of debugging (SELECT only). Strictly read-only — never runs INSERT/UPDATE/DELETE/DDL/ALTER or any az sql command that creates, updates, scales, or deletes a resource.
---

# Azure SQL Database Debugging (Read-Only)

Two layers of investigation:
1. **Resource/control-plane** via `az sql` — server/database config, firewall,
   resource limits, recent resource-level metrics.
2. **Query/data-plane** via `sqlcmd` — DMVs for blocking, slow queries, wait
   stats, and ad-hoc `SELECT` queries against application data for debugging.

## Read-only rule — this is critical for this skill in particular

**az cli**: only use `show`/`list`/`get-*` style commands, e.g.
`az sql db show`, `az sql server show`, `az sql db list-usages`,
`az sql db op list`, `az monitor metrics list` (for DB resource metrics).
Never use `az sql db create/update/delete`, `az sql server create/update/delete`,
`az sql db update --service-objective` (scaling), firewall-rule create/delete,
etc.

**sqlcmd / T-SQL**: only ever run `SELECT` statements (including against
DMVs/system views) or read-only metadata commands. Never run `INSERT`,
`UPDATE`, `DELETE`, `MERGE`, `TRUNCATE`, `CREATE`, `ALTER`, `DROP`, `EXEC` of
unknown/write procedures, or anything that changes data or schema — even if
asked "just to test something". If the user asks for a write/fix, stop and
clearly say this skill is read-only for the database and the change should
be made through the normal application/migration path.

Before running any query you're unsure about, mentally check: does this
only read data? If there's any doubt, don't run it — ask the user instead.

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
   - `<repo-root>/.claude/azure-sql-database.json` — project-specific
     override, found by walking up from the current directory to the git
     root.
   - `~/.claude/azure-sql-database.json` — personal/global default, if the
     project file doesn't exist or doesn't define that environment.

   On success it prints the resolved JSON object with fields
   `subscriptionId`, `resourceGroup`, `sqlServerName` (all required — the
   script validates this), and optionally `sqlDatabaseName` and
   `sqlUsername` (needed only for the sqlcmd/DMV workflows in
   `references/commands.md`, not for `az sql` control-plane-only reads).

3. **The password is never in this file.** Ask the user to export
   `SQLCMDPASSWORD` as an environment variable for the session before
   running any `sqlcmd` command — `sqlcmd` reads this natively, so no
   custom plumbing is needed. The resolver script actively rejects a config
   file that contains a password field, since these files are meant to be
   safe to commit at the project level.

4. **On failure (non-zero exit), do not guess values.** Follow the
   discovery flow in `references/discovery.md`: list candidate resources
   with read-only commands, confirm with the user, and offer (never
   assume) to save the non-secret parts to the project config for next
   time.

See `assets/config.example.json` for the expected shape of both environment
blocks.

## Investigation playbooks

Once config is resolved and the connection is established, the full
playbooks live in `references/commands.md`:

- **Connecting with sqlcmd** — encrypted connection, `.sql`-file pattern for
  longer queries, fallback if `sqlcmd` isn't installed.
- **Data-plane playbook (A–G)**: current blocking/long-running requests,
  recent slow queries via Query Store, recent errors via Azure Monitor
  metrics, deadlock ring-buffer fallback, resource pressure (DTU/vCore,
  connections), wait stats, ad-hoc data inspection.
- **Control-plane playbook**: `az sql` commands for server/db config,
  firewall rules, recent operations.
- **Connectivity troubleshooting checklist** for "cannot connect to SQL" /
  timeout reports.
- **Hand-off guidance** to `app-insights-kql`, `log-analytics-workspace`,
  and `azure-monitor` for what this skill can't see directly.
- **Output format** — state exactly which queries/commands were run, report
  findings, and never propose or run a fix query; only report findings and
  point to the appropriate remediation path.
