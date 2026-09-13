---
name: azure-cache-redis
description: Read-only Azure Cache for Redis investigation via Azure CLI and read-only redis-cli commands — memory pressure and evictions, cache hit/miss ratio, connected clients, server load/CPU, slow commands (SLOWLOG), key inspection (TTL, key size, key patterns), and connection errors/timeouts. Use whenever the user reports "cache misses spiking", "Redis timeouts", "high memory usage on cache", "evictions happening", "slow Redis commands", "connection pool exhausted on Redis", or wants to check cache config/metrics for a service using distributed caching or session/output caching. Complements azure-monitor (platform metrics/activity log also cover Redis) and azure-sql-database/azure-cosmos-db as the third data-layer skill. NEVER writes, deletes, expires, or flushes keys, and never changes cache configuration, tier, or scaling — INFO/monitoring commands and read-only key inspection only.
---

# Azure Cache for Redis (read-only)

Investigates Redis-backed issues: memory pressure, evictions, latency spikes, and connection problems. Third data-layer skill alongside `azure-sql-database` and `azure-cosmos-db` — reach for this when the symptom smells like caching (stale data, cache-miss storms, session loss, rate-limiter/lock behaving oddly) rather than the primary datastore.

## Hard rule: read-only, no exceptions

**Azure CLI**: only `list`, `show`, `list-keys` (to *read* the connection key, not rotate it), and metrics/log reads. Never `create`, `update`, `delete`, `az redis force-reboot`, `az redis regenerate-keys`, `az redis patch-schedule`, or scaling operations.

**redis-cli / RESP commands**: only read/introspection commands — `INFO`, `PING`, `CLIENT LIST`, `CLIENT INFO`, `SLOWLOG GET`, `SLOWLOG LEN`, `MEMORY STATS`, `MEMORY USAGE <key>`, `DBSIZE`, `TTL`/`PTTL <key>`, `TYPE <key>`, `SCAN` (never `KEYS *` in production — it blocks the single-threaded server), `GET`/`LRANGE`/`HGETALL`/etc. to inspect a specific key's *value* only when the user explicitly asks and it's safe to view (no PII concerns).

**Never** run: `SET`, `DEL`, `EXPIRE`, `FLUSHALL`, `FLUSHDB`, `CONFIG SET`, `SHUTDOWN`, `CLIENT KILL`, or any write/eviction/config command. If a fix requires flushing a bad key or bumping the tier, propose it — don't execute it.

## Configuration

Connection settings live in a small JSON config, resolved per environment — not in a `.env` file.

### Step 1 — determine the environment

Exactly two environments are supported: `qa` and `production`. Querying the wrong one can produce misleading results (or point someone at a production incident that's actually a QA issue), so:

- If the user's instruction names the environment (`qa`, `production`, or an obvious equivalent like "prod"), use that.
- If it's unspecified or ambiguous, **ask the user which environment before running anything.** Do not guess.

### Step 2 — resolve config for that environment

```bash
scripts/resolve_config.sh --env qa        # or: --env production
```

The script checks, in order:
1. **Project override** — walks up from the current directory to the nearest git root, then reads `<repo-root>/.claude/azure-cache-redis.json`.
2. **Personal/global default** — `~/.claude/azure-cache-redis.json`.
3. If neither file defines the requested environment, it exits non-zero (exit code `1`). **Fall through to the discovery flow below — never fabricate values.**

On success, it prints one JSON object with the resolved fields on stdout (exit `0`). It also validates that all required fields are present, so a successful exit means the config is usable as-is.

### Step 3 — discovery flow (only if resolution fails)

1. Run `az redis list` (and `az group list` if the resource group is also unknown) to find likely candidate caches for the requested environment.
2. Confirm the match with the user, or let them pick from a short list if there's more than one candidate.
3. Ask whether to save the resolved values to the **project-level** config (`<repo-root>/.claude/azure-cache-redis.json`) for next time.
4. **Never write the config file without the user's explicit confirmation.**

### Config fields

| Field | Required | Description |
|---|---|---|
| `subscriptionId` | Yes | Azure subscription ID or name containing the cache, used for `az account set --subscription` |
| `resourceGroup` | Yes | Resource group containing the Redis cache |
| `cacheName` | Yes | The Azure Cache for Redis resource name, used with `az redis show/list-keys -n` |
| `hostName` | Yes | Redis hostname used for `redis-cli` connections |
| `port` | No — defaults to `6380` | Redis TLS port used for `redis-cli` connections |

See `assets/config.example.json` for a filled-in example covering both environments.

### Using the resolved config

```bash
CONFIG=$(scripts/resolve_config.sh --env qa) || {
  # resolution failed — run the discovery flow instead of guessing
  exit 1
}

SUBSCRIPTION_ID=$(jq -r '.subscriptionId' <<<"$CONFIG")
RESOURCE_GROUP=$(jq -r '.resourceGroup'   <<<"$CONFIG")
CACHE_NAME=$(jq -r '.cacheName'           <<<"$CONFIG")
HOST_NAME=$(jq -r '.hostName'             <<<"$CONFIG")
PORT=$(jq -r '.port'                      <<<"$CONFIG")

az account set --subscription "$SUBSCRIPTION_ID"
REDIS_ID=$(az redis show -g "$RESOURCE_GROUP" -n "$CACHE_NAME" --query id -o tsv)

# Read-only key fetch for connecting via redis-cli (this lists/reads the key, does not rotate it)
REDIS_KEY=$(az redis list-keys -g "$RESOURCE_GROUP" -n "$CACHE_NAME" --query primaryKey -o tsv)
```

With `$REDIS_ID`, `$HOST_NAME`, `$PORT`, `$REDIS_KEY`, and `$RESOURCE_GROUP` set, proceed to the investigation commands.

## Investigation playbook

The full command set — config/tier check, memory & eviction metrics, hit/miss ratio, server load, `SLOWLOG`, client connections, key inspection, and diagnostic logs — plus the suggested triage workflow (which step to start with for a given symptom) live in `references/investigation-playbook.md`. Load that file once the environment and config are resolved.

## Output hygiene

- Report hit ratio as a percentage over the stated window, not raw hit/miss counts alone.
- Distinguish `evictedkeys` (memory pressure, bad) from `expiredkeys` (normal TTL behavior) explicitly — conflating them is a common misdiagnosis.
- When flagging a StackExchange.Redis connection-multiplexer misconfiguration, note it as a proposed code-level fix, not something this skill can change.
