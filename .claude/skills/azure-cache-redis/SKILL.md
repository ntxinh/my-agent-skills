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

## Setup

Add these to `~/.agents/.env` if not already present (ask the user for real values):

```ini
AZURE_REDIS_CACHE=
AZURE_REDIS_HOSTNAME=
AZURE_REDIS_PORT=6380
```

```bash
set -a; source ~/.agents/.env; set +a
az account set --subscription "$SUBSCRIPTION"

REDIS_ID=$(az redis show -g "$RESOURCE_GROUP" -n "$AZURE_REDIS_CACHE" --query id -o tsv)

# Read-only key for connecting via redis-cli (this lists/reads the key, does not rotate it)
REDIS_KEY=$(az redis list-keys -g "$RESOURCE_GROUP" -n "$AZURE_REDIS_CACHE" --query primaryKey -o tsv)
```

## 1. Config & tier — "what are we actually running"

```bash
az redis show -g "$RESOURCE_GROUP" -n "$AZURE_REDIS_CACHE" \
  --query "{sku:sku, shardCount:shardCount, redisVersion:redisVersion, tls:minimumTlsVersion, nonSslEnabled:enableNonSslPort}" -o json

# Redis-specific settings: maxmemory-policy is the single most important one for eviction behavior
az redis show -g "$RESOURCE_GROUP" -n "$AZURE_REDIS_CACHE" --query redisConfiguration -o json
```

Check `maxmemory-policy` first — if it's `noeviction`, the cache will start rejecting writes (not silently evicting) once full, which looks like a very different failure mode than `allkeys-lru`/`volatile-lru` quietly evicting.

## 2. Memory pressure & evictions — via Metrics

```bash
az monitor metrics list --resource "$REDIS_ID" \
  --metric "usedmemorypercentage" "usedmemory" "evictedkeys" "expiredkeys" \
  --interval PT5M --start-time "$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%MZ)" \
  -o table
```

`evictedkeys` climbing = cache is full and actively dropping data under memory pressure (not just TTL expiry, which is `expiredkeys` — a normal/expected number). Sustained high `usedmemorypercentage` (>90%) is the leading indicator before evictions start.

## 3. Cache effectiveness — hit/miss ratio

```bash
az monitor metrics list --resource "$REDIS_ID" \
  --metric "cachehits" "cachemisses" "cachewrites" "cachereads" \
  --interval PT5M --start-time "$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%MZ)" \
  -o table
```

Compute the ratio (`cachehits / (cachehits + cachemisses)`) over the window. A sudden drop usually means either a deploy changed cache-key generation (keys no longer match), a mass expiry/eviction event just happened (see step 2), or a new code path is bypassing the cache.

## 4. Server load, connections, latency

```bash
az monitor metrics list --resource "$REDIS_ID" \
  --metric "percentprocessortime" "connectedclients" "totalcommandsprocessed" "operationsPerSecond" "serverLoad" \
  --interval PT5M --start-time "$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%MZ)" \
  -o table

# For Premium tier with clustering, also check per-shard if relevant
az monitor metrics list --resource "$REDIS_ID" --metric "connectedclients" --dimension "ShardId" \
  --interval PT5M --start-time "$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%MZ)" -o table
```

`serverLoad` near 100% explains latency spikes even when memory looks fine — Redis is single-threaded per shard, so CPU-bound command load (e.g. large `SORT`/`SMEMBERS` on huge collections, or too many clients) saturates it independent of memory headroom.

## 5. Slow commands — SLOWLOG (live, read-only)

Connect read-only via `redis-cli` (TLS, port from env):

```bash
redis-cli -h "$AZURE_REDIS_HOSTNAME" -p "$AZURE_REDIS_PORT" -a "$REDIS_KEY" --tls \
  SLOWLOG GET 25

redis-cli -h "$AZURE_REDIS_HOSTNAME" -p "$AZURE_REDIS_PORT" -a "$REDIS_KEY" --tls \
  SLOWLOG LEN
```

Each entry gives the command, arguments, and microsecond execution time. Look for expensive full-collection scans (`SMEMBERS` on a huge set, `HGETALL` on a huge hash, `KEYS` used by application code instead of `SCAN`, or large `MGET`/pipeline batches) — these are almost always an application-side data-modeling issue, not a Redis config issue.

## 6. Client connections

```bash
redis-cli -h "$AZURE_REDIS_HOSTNAME" -p "$AZURE_REDIS_PORT" -a "$REDIS_KEY" --tls CLIENT LIST
```

Look at `age`, `idle`, and `cmd` per connection. A large number of long-idle connections from the backend App Service usually means the ASP.NET Core `IConnectionMultiplexer` isn't being reused as a singleton (a common StackExchange.Redis misconfiguration — creating a new multiplexer per request exhausts connections and causes `ConnectionTimeoutException` under load).

## 7. Key inspection (targeted, never bulk-scan blindly)

```bash
# TTL and type for a specific key the user is asking about
redis-cli -h "$AZURE_REDIS_HOSTNAME" -p "$AZURE_REDIS_PORT" -a "$REDIS_KEY" --tls TTL "session:abc123"
redis-cli -h "$AZURE_REDIS_HOSTNAME" -p "$AZURE_REDIS_PORT" -a "$REDIS_KEY" --tls TYPE "session:abc123"
redis-cli -h "$AZURE_REDIS_HOSTNAME" -p "$AZURE_REDIS_PORT" -a "$REDIS_KEY" --tls MEMORY USAGE "session:abc123"

# Pattern browsing — SCAN with COUNT, never KEYS * (blocks the server)
redis-cli -h "$AZURE_REDIS_HOSTNAME" -p "$AZURE_REDIS_PORT" -a "$REDIS_KEY" --tls \
  --scan --pattern "session:*" --count 100
```

`TTL` returning `-1` means the key has no expiry set (potential source of unbounded memory growth if the app assumes everything expires). `TTL` returning `-2` means the key doesn't exist (already expired/evicted — explains a cache-miss report directly).

## 8. Diagnostic logs & activity

```bash
az monitor diagnostic-settings list --resource "$REDIS_ID" -o table

az monitor activity-log list -g "$RESOURCE_GROUP" --resource-id "$REDIS_ID" \
  --start-time "$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%MZ)" -o table
```

Activity log catches scaling operations, patch/maintenance events, and failovers — a "Redis suddenly reset all connections" symptom is very often an Azure-managed patching event, visible here, not an application bug.

## Suggested triage workflow

1. **"Cache misses spiking" / "stale data"** → step 3 (hit/miss ratio) → step 2 (was there an eviction event) → step 7 (spot-check a specific expected key's TTL).
2. **"Redis timeouts / connection errors from the app"** → step 6 (CLIENT LIST — is the connection count abnormal) → step 4 (serverLoad/CPU) → step 8 (was there a failover/patch event).
3. **"High memory / OOM-ish behavior"** → step 2 (usedmemorypercentage, evictedkeys) → step 1 (confirm maxmemory-policy isn't `noeviction`) → step 7 (find the biggest keys via `MEMORY USAGE` on suspects).
4. **"Everything feels slow"** → step 5 (SLOWLOG) first — this usually points straight at the offending command/key pattern.

## Output hygiene

- Report hit ratio as a percentage over the stated window, not raw hit/miss counts alone.
- Distinguish `evictedkeys` (memory pressure, bad) from `expiredkeys` (normal TTL behavior) explicitly — conflating them is a common misdiagnosis.
- When flagging a StackExchange.Redis connection-multiplexer misconfiguration, note it as a proposed code-level fix, not something this skill can change.
