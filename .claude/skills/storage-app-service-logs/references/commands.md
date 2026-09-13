# Azure Storage App Service Logs — Command & Workflow Reference

This file holds the full command examples and log-reading workflows.
SKILL.md tells you when to reach for each section; this file has the actual
commands.

All commands below assume you've already resolved config for the target
environment (see SKILL.md "Config resolution") and exported it into shell
variables:

```bash
CONFIG_JSON="$(scripts/resolve_config.sh --env "$ENV_NAME")"

SUBSCRIPTION_ID=$(jq -r '.subscriptionId' <<<"$CONFIG_JSON")
STORAGE_ACCOUNT_NAME=$(jq -r '.storageAccountName' <<<"$CONFIG_JSON")
CONTAINER_NAME=$(jq -r '.containerName' <<<"$CONFIG_JSON")
DIRECTORY_STRUCTURE_PATTERN=$(jq -r '.directoryStructurePattern // empty' <<<"$CONFIG_JSON")

az account set --subscription "$SUBSCRIPTION_ID"
```

`DIRECTORY_STRUCTURE_PATTERN` (e.g. `YYYY/MM/DD/api-log.txt`) tells you how
to build the blob path for a given date. For 2026-08-21 that resolves to
`2026/08/21/api-log.txt`. Always compute this from the actual date the user
cares about (incident date), not today's date, unless they want "today's"
log. If this field wasn't set in the resolved config, list the container's
top-level prefixes first to infer the actual folder structure before
guessing.

## Auth

Prefer Azure AD auth (no keys needed) if the caller's identity has a
data-plane role (Storage Blob Data Reader) on the account:

```bash
az storage blob list --auth-mode login \
  --account-name "$STORAGE_ACCOUNT_NAME" \
  --container-name "$CONTAINER_NAME" \
  --prefix "2026/08/21/" \
  -o table
```

If that fails with an auth error, tell the user you need either:
- their AAD identity granted `Storage Blob Data Reader` on
  `$STORAGE_ACCOUNT_NAME`, or
- a read-only SAS token / connection string, supplied ad hoc for the
  session (e.g. exported as an environment variable right before the
  command that needs it) — **never write it into the config file.** The
  resolver script rejects a config containing one anyway.

Do not attempt to generate or regenerate storage account keys (that's a
write/rotate operation, and it's also a secret-handling risk) — ask the
user to provide one instead if `--auth-mode login` doesn't work.

## Read-only rule

Only ever use:
- `az storage blob list`
- `az storage blob show`
- `az storage blob download` (downloads a local read-only copy to inspect;
  does not mutate the source)
- `az storage container list` / `az storage container show`

Never use `az storage blob upload/delete/copy start`, `set-tier`, `lease`,
`az storage container create/delete`, `az storage account keys renew`, or
any other mutating command. If the user asks to "clean up" or "archive"
logs, explain this skill is read-only and won't perform that action.

## Finding and reading a specific day's log

List what's available for a date (folder listing):
```bash
az storage blob list --auth-mode login \
  --account-name "$STORAGE_ACCOUNT_NAME" \
  --container-name "$CONTAINER_NAME" \
  --prefix "2026/08/21/" \
  --query "[].{name:name, size:properties.contentLength, lastModified:properties.lastModified}" \
  -o table
```

Download the specific file to a local scratch path to grep/inspect (never
write it anywhere under the read-only mounts):
```bash
mkdir -p /home/claude/logs
az storage blob download --auth-mode login \
  --account-name "$STORAGE_ACCOUNT_NAME" \
  --container-name "$CONTAINER_NAME" \
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

## Multi-day range (incident spanning midnight, or "last N days")

Loop over dates and download/prefix-list each day; the date folder
structure means you can't glob across days in a single blob list call, so
iterate:

```bash
for d in 2026-08-20 2026-08-21; do
  y=${d:0:4}; m=${d:5:2}; day=${d:8:2}
  az storage blob download --auth-mode login \
    --account-name "$STORAGE_ACCOUNT_NAME" \
    --container-name "$CONTAINER_NAME" \
    --name "$y/$m/$day/api-log.txt" \
    --file "/home/claude/logs/api-log-$d.txt" \
    --no-progress 2>/dev/null || echo "no log for $d"
done
cat /home/claude/logs/api-log-2026-08-2*.txt | sort > /home/claude/logs/combined.txt
```

## Interpreting Serilog file-sink output

Typical Serilog file output (default text formatter) looks like:
```
2026-08-21 02:14:33.512 +00:00 [ERR] Failed to process order 12345
System.Exception: ...
   at MyApp.Services.OrderService.Process(...) ...
```
- Level tokens: `[VRB]/[DBG]/[INF]/[WRN]/[ERR]/[FTL]`.
- If structured/JSON formatter is used instead, each line is a JSON object —
  pipe through `jq` for filtering:
```bash
grep '^{' /home/claude/logs/api-log-2026-08-21.txt | jq -c 'select(.Level=="Error")'
```
- Correlate with App Insights by looking for a `TraceId`/`SpanId`/`CorrelationId`
  property in the line (Serilog enrichers commonly add these when
  integrated with OpenTelemetry) — use that value as
  `operation_Id`/`trace_Id` when switching to the app-insights-kql skill
  for the richer distributed trace.

## Common workflows

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

## When to hand off to other skills/tools

- Need distributed trace correlation, request/dependency timing, or
  exception aggregation across many requests → **app-insights-kql** skill
  (use any TraceId/CorrelationId found in the file as the join key).
- Need platform-level App Service logs (HTTP access log, container
  restarts) → **log-analytics-workspace** skill.
- Suspect the DB is the root cause → **Azure SQL Database** skill.
- Need alerting/metrics context (CPU, memory, restarts) → **Azure Monitor**
  skill.

## Output format for the user

State which blob path(s) were read, the time range inspected, key findings
(error counts, representative stack trace, correlation IDs found), and
suggest the next step (often: take a found `TraceId` into app-insights-kql
for the full distributed trace). Downloaded scratch files under
`/home/claude/logs` are fine to leave for the session but never present
them as deliverables — they're just working copies of read-only source
data.
