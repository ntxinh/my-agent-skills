---
name: storage-app-service-logs
description: Read the ASP.NET Core backend's daily log files (Serilog file sink output, e.g. api-log.txt) stored in an Azure Storage Account container, organized by date folders, using Azure CLI/az storage. Use this skill whenever the user wants to look at raw application log text for a specific day or time, tail recent log lines, grep for an error/exception/correlation ID in the daily log file, or mentions "daily log", "log file", "blob storage logs", api-log.txt, or a specific date's logs. Strictly read-only — never uploads, modifies, or deletes any blob or container.
---

# Azure Storage Account — App Service Daily Log Files

Read-only access to the raw daily log file(s) the ASP.NET Core backend
writes via its Serilog file sink, which get shipped/synced into an Azure
Storage Account blob container (common pattern for App Service apps that
also log to a file for durability beyond App Insights sampling/retention).

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
   - `<repo-root>/.claude/storage-app-service-logs.json` — project-specific
     override, found by walking up from the current directory to the git
     root.
   - `~/.claude/storage-app-service-logs.json` — personal/global default,
     if the project file doesn't exist or doesn't define that environment.

   On success it prints the resolved JSON object with fields
   `subscriptionId`, `storageAccountName`, `containerName` (all required —
   the script validates this), and optionally `resourceGroup` and
   `directoryStructurePattern` (the date-folder path convention, e.g.
   `YYYY/MM/DD/api-log.txt` — if not set, discover it by listing the
   container's top level rather than guessing).

3. **Secrets are never in this file.** Auth defaults to
   `--auth-mode login` (AAD) — no key needed if the caller's identity has
   `Storage Blob Data Reader` on the account. If that fails, ask the user
   for a SAS token or connection string supplied ad hoc for the session
   only. The resolver script actively rejects a config file that contains
   a `sasToken`, `connectionString`, or `accountKey` field, since these
   files are meant to be safe to commit at the project level.

4. **On failure (non-zero exit), do not guess values.** Follow the
   discovery flow in `references/discovery.md`: list candidate resources
   with read-only commands, confirm with the user, and offer (never
   assume) to save the non-secret parts to the project config for next
   time.

See `assets/config.example.json` for the expected shape of both environment
blocks.

## Read-only rule

Only ever use:
- `az storage blob list`
- `az storage blob show`
- `az storage blob download` (downloads a local read-only copy to inspect;
  does not mutate the source)
- `az storage container list` / `az storage container show`

Never use `az storage blob upload/delete/copy start`, `set-tier`, `lease`,
`az storage container create/delete`, `az storage account keys renew`, or
any other mutating command, and never generate or regenerate storage
account keys. If the user asks to "clean up" or "archive" logs, explain
this skill is read-only and won't perform that action.

## Reading logs

Once config is resolved, the full command examples and workflows live in
`references/commands.md`:

- **Auth** — AAD (`--auth-mode login`) first, SAS/connection-string fallback
  supplied ad hoc, never persisted.
- **Finding and reading a specific day's log** — list, download to a local
  scratch path, then `wc`/`tail`/`grep` it locally rather than
  re-downloading.
- **Multi-day range** handling for incidents spanning midnight or "last N
  days".
- **Interpreting Serilog output** — text vs. JSON formatter, correlating
  `TraceId`/`CorrelationId` with app-insights-kql.
- **Common workflows** — errors around a specific time, full stack traces,
  checking whether an error recurred on prior days.
- **Hand-off guidance** to `app-insights-kql`, `log-analytics-workspace`,
  `azure-sql-database`, and `azure-monitor`.
- **Output format** — state the blob path(s) read, time range, and key
  findings; scratch files are working copies, never deliverables.
