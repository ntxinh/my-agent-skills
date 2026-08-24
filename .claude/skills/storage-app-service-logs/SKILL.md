---
name: storage-app-service-logs
description: Read the ASP.NET Core backend's daily log files (Serilog file sink output, e.g. api-log.txt) stored in an Azure Storage Account container, organized by date folders, using Azure CLI/az storage. Use this skill whenever the user wants to look at raw application log text for a specific day or time, tail recent log lines, grep for an error/exception/correlation ID in the daily log file, or mentions "daily log", "log file", "blob storage logs", api-log.txt, or a specific date's logs. Strictly read-only — never uploads, modifies, or deletes any blob or container.
---

# Azure Storage Account — App Service Daily Log Files

Read-only access to the raw daily log file(s) the ASP.NET Core backend writes via its
Serilog file sink, which get shipped/synced into an Azure Storage Account blob
container (common pattern for App Service apps that also log to a file for durability
beyond App Insights sampling/retention).

## 0. Load config

```bash
set -a; source ~/.agents/.env; set +a
echo "Storage account: $AZURE_STORAGE_ACCOUNT | Container: $AZURE_STORAGE_ACCOUNT_CONTAINER"
echo "Path pattern: $AZURE_STORAGE_ACCOUNT_CONTAINER_DIRECTORY_STRUCTURE"
az account set --subscription "$SUBSCRIPTION"
```

`AZURE_STORAGE_ACCOUNT_CONTAINER_DIRECTORY_STRUCTURE` (e.g. `YYYY/MM/DD/api-log.txt`)
tells you how to build the blob path for a given date. For 2026-08-21 that resolves to
`2026/08/21/api-log.txt`. Always compute this from the actual date the user cares
about (incident date), not today's date, unless they want "today's" log.

## 1. Auth

Prefer Azure AD auth (no keys needed) if the caller's identity has a data-plane role
(Storage Blob Data Reader) on the account:

```bash
az storage blob list --auth-mode login \
  --account-name "$AZURE_STORAGE_ACCOUNT" \
  --container-name "$AZURE_STORAGE_ACCOUNT_CONTAINER" \
  --prefix "2026/08/21/" \
  -o table
```

If that fails with an auth error and a connection string / key isn't provided in the
env file, tell the user you need either:
- their AAD identity granted `Storage Blob Data Reader` on `$AZURE_STORAGE_ACCOUNT`, or
- a read-only SAS token / connection string added to `~/.agents/.env`.

Do not attempt to generate or regenerate storage account keys (that's a write/rotate
operation, and it's also a secret-handling risk) — ask the user to provide one instead
if `--auth-mode login` doesn't work.

## 2. Read-only rule

Only ever use:
- `az storage blob list`
- `az storage blob show`
- `az storage blob download` (downloads a local read-only copy to inspect; does not
  mutate the source)
- `az storage container list` / `az storage container show`

Never use `az storage blob upload/delete/copy start`, `set-tier`, `lease`,
`az storage container create/delete`, `az storage account keys renew`, or any other
mutating command. If the user asks to "clean up" or "archive" logs, explain this skill
is read-only and won't perform that action.

## 3. Finding and reading a specific day's log

List what's available for a date (folder listing):
```bash
az storage blob list --auth-mode login \
  --account-name "$AZURE_STORAGE_ACCOUNT" \
  --container-name "$AZURE_STORAGE_ACCOUNT_CONTAINER" \
  --prefix "2026/08/21/" \
  --query "[].{name:name, size:properties.contentLength, lastModified:properties.lastModified}" \
  -o table
```

Download the specific file to a local scratch path to grep/inspect (never write it
anywhere under the read-only mounts):
```bash
mkdir -p /home/claude/logs
az storage blob download --auth-mode login \
  --account-name "$AZURE_STORAGE_ACCOUNT" \
  --container-name "$AZURE_STORAGE_ACCOUNT_CONTAINER" \
  --name "2026/08/21/api-log.txt" \
  --file /home/claude/logs/api-log-2026-08-21.txt \
  --no-progress
```

Then inspect locally rather than re-downloading repeatedly:
```bash
wc -l /home/claude/logs/api-log-2026-08-21.txt
tail -n 200 /home/claude/logs/api-log-2026-08-21.txt
grep -i "exception\|error\|fatal" /home/claude/logs/api-log-2026-08-21.txt | tail -n 100
```

## 4. Multi-day range (incident spanning midnight, or "last N days")

Loop over dates and download/prefix-list each day; the date folder structure means you
can't glob across days in a single blob list call, so iterate:

```bash
for d in 2026-08-20 2026-08-21; do
  y=${d:0:4}; m=${d:5:2}; day=${d:8:2}
  az storage blob download --auth-mode login \
    --account-name "$AZURE_STORAGE_ACCOUNT" \
    --container-name "$AZURE_STORAGE_ACCOUNT_CONTAINER" \
    --name "$y/$m/$day/api-log.txt" \
    --file "/home/claude/logs/api-log-$d.txt" \
    --no-progress 2>/dev/null || echo "no log for $d"
done
cat /home/claude/logs/api-log-2026-08-2*.txt | sort > /home/claude/logs/combined.txt
```

## 5. Interpreting Serilog file-sink output

Typical Serilog file output (default text formatter) looks like:
```
2026-08-21 02:14:33.512 +00:00 [ERR] Failed to process order 12345
System.Exception: ...
   at MyApp.Services.OrderService.Process(...) ...
```
- Level tokens: `[VRB]/[DBG]/[INF]/[WRN]/[ERR]/[FTL]`.
- If structured/JSON formatter is used instead, each line is a JSON object — pipe
  through `jq` for filtering:
```bash
grep '^{' /home/claude/logs/api-log-2026-08-21.txt | jq -c 'select(.Level=="Error")'
```
- Correlate with App Insights by looking for a `TraceId`/`SpanId`/`CorrelationId`
  property in the line (Serilog enrichers commonly add these when integrated with
  OpenTelemetry) — use that value as `operation_Id`/`trace_Id` when switching to the
  app-insights-kql skill for the richer distributed trace.

## 6. Common workflows

**"Show me errors around 02:14 UTC on Aug 21"**
```bash
grep -n "^2026-08-21 02:1[0-9]" /home/claude/logs/api-log-2026-08-21.txt | grep -i err
```

**"Get the full stack trace for that exception"** — Serilog exceptions print
multi-line; grab context after the match:
```bash
grep -n -A 15 "Failed to process order 12345" /home/claude/logs/api-log-2026-08-21.txt
```

**"Did this error happen before?"** — check prior days:
```bash
for f in /home/claude/logs/*.txt; do echo "== $f =="; grep -c "OrderService" "$f"; done
```

## 7. When to hand off to other skills/tools

- Need distributed trace correlation, request/dependency timing, or exception
  aggregation across many requests → **app-insights-kql** skill (use any
  TraceId/CorrelationId found in the file as the join key).
- Need platform-level App Service logs (HTTP access log, container restarts) →
  **log-analytics-workspace** skill.
- Suspect the DB is the root cause → **Azure SQL Database** skill.
- Need alerting/metrics context (CPU, memory, restarts) → **Azure Monitor** skill.

## 8. Output format for the user

State which blob path(s) were read, the time range inspected, key findings (error
counts, representative stack trace, correlation IDs found), and suggest the next step
(often: take a found `TraceId` into app-insights-kql for the full distributed trace).
Clean up downloaded scratch files from `/home/claude/logs` are fine to leave for the
session but never present them as deliverables — they're just working copies of
read-only source data.
