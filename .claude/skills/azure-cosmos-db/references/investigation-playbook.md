# Azure Cosmos DB — Investigation Playbook

This file contains the full command set for investigating a Cosmos DB–backed issue.
Load it once you know the environment and have resolved config via
`scripts/resolve_config.sh` (see `SKILL.md`).

All commands below assume these shell variables are already set from the resolved
config (see the "Using resolved config in commands" section of `SKILL.md`):

- `$SUBSCRIPTION_ID`
- `$RESOURCE_GROUP`
- `$ACCOUNT_NAME`
- `$DATABASE_NAME` — only needed for database/container-scoped steps; may be unset if
  the investigation is account-level only
- `$CONTAINER_NAME` — only needed for container-scoped steps; may be unset likewise
- `$COSMOS_ID` — the account's Azure resource ID (`az cosmosdb show --query id`)

If `$DATABASE_NAME`/`$CONTAINER_NAME` aren't set and a step below needs them, ask the
user which database/container, or use `az cosmosdb sql database list` /
`az cosmosdb sql container list` (step 1) to discover candidates first.

## 1. Account & container config — "what are we actually provisioned for"

```bash
# Account-level: consistency level, regions, capabilities (e.g. serverless vs provisioned)
az cosmosdb show -g "$RESOURCE_GROUP" -n "$ACCOUNT_NAME" \
  --query "{consistency:consistencyPolicy.defaultConsistencyLevel, locations:locations[].locationName, capabilities:capabilities}" -o json

# Database + container list
az cosmosdb sql database list -g "$RESOURCE_GROUP" -a "$ACCOUNT_NAME" -o table
az cosmosdb sql container list -g "$RESOURCE_GROUP" -a "$ACCOUNT_NAME" -d "$DATABASE_NAME" -o table

# Container detail: partition key path, indexing policy, unique keys, TTL
az cosmosdb sql container show -g "$RESOURCE_GROUP" -a "$ACCOUNT_NAME" \
  -d "$DATABASE_NAME" -n "$CONTAINER_NAME" \
  --query "{partitionKey:resource.partitionKey, indexing:resource.indexingPolicy, ttl:resource.defaultTtl}" -o json

# Provisioned throughput (RU/s) at database or container level — check whichever is set
az cosmosdb sql database throughput show -g "$RESOURCE_GROUP" -a "$ACCOUNT_NAME" -n "$DATABASE_NAME" -o json
az cosmosdb sql container throughput show -g "$RESOURCE_GROUP" -a "$ACCOUNT_NAME" \
  -d "$DATABASE_NAME" -n "$CONTAINER_NAME" -o json
```

A mismatch between actual traffic and provisioned RU/s (fixed, not autoscale, and set too low) is the single most common Cosmos incident — check this before anything fancier.

## 2. Throttling (429s) and RU consumption — via Metrics

```bash
az monitor metrics list --resource "$COSMOS_ID" \
  --metric "TotalRequestUnits" "NormalizedRUConsumption" "TotalRequests" \
  --interval PT5M --start-time "$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%MZ)" \
  -o table

# Break down 429s specifically by status code dimension
az monitor metrics list --resource "$COSMOS_ID" \
  --metric "TotalRequests" --dimension "StatusCode" \
  --interval PT5M --start-time "$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%MZ)" \
  -o table
```

`NormalizedRUConsumption` near/at 100% for a sustained period = the container was throttled; correlate the timestamps with the app-side symptom (slow requests, retried calls in App Insights dependency data — hand off to `app-insights-kql`).

## 3. Hot partitions — "is load skewed to one partition key value"

```bash
# Per-partition-key-range RU consumption (needs PartitionKeyRangeId dimension)
az monitor metrics list --resource "$COSMOS_ID" \
  --metric "NormalizedRUConsumption" --dimension "CollectionName" "PartitionKeyRangeId" \
  --interval PT15M --start-time "$(date -u -d '6 hours ago' +%Y-%m-%dT%H:%MZ)" \
  -o table
```

If one partition key range is consistently maxed while others are idle, the container's partition key choice (or a specific tenant/customer with disproportionate traffic under that key) is the root cause — this is a design issue, not something fixable by raising RU/s alone.

## 4. Slow / expensive queries

Cosmos returns RU cost per query in the response headers (`x-ms-request-charge`). When debugging from application code or via a read-only query tool:

```sql
-- Run directly (read-only) to inspect a suspect query's shape/cost
SELECT * FROM c WHERE c.partitionKeyField = @value AND c.someField = @other
```

- A high RU charge on a query usually means it's a **cross-partition query** (missing or wrong partition key in the filter) or missing an index for the filtered/sorted field.
- Check the container's indexing policy (pulled in step 1) — confirm the field being filtered/sorted on is actually included and not excluded.
- `ORDER BY` on a non-indexed (or composite-index-missing) field forces an expensive in-memory sort — a frequent silent cost driver.

## 5. Diagnostic logs (if routed to Log Analytics)

Cosmos can send `DataPlaneRequests`, `QueryRuntimeStatistics`, `PartitionKeyStatistics`, and `PartitionKeyRUConsumption` logs to the shared Log Analytics workspace — check first whether this is configured:

```bash
az monitor diagnostic-settings list --resource "$COSMOS_ID" -o table
```

If configured, hand off to `log-analytics-workspace` with these starting queries (adjust table names to what's actually enabled):

```kusto
CDBDataPlaneRequests
| where TimeGenerated > ago(1h)
| where StatusCode == 429
| summarize count() by CollectionName, bin(TimeGenerated, 5m)

CDBQueryRuntimeStatistics
| where TimeGenerated > ago(1h)
| where requestCharge > 50
| project TimeGenerated, querytext_s, requestCharge, CollectionName
| order by requestCharge desc
```

If no diagnostic setting exists, say so explicitly — this is often the reason "there's nothing in Log Analytics" isn't a query bug but a missing routing config (a fix to propose, not apply).

## 6. Account health / activity

```bash
# Control-plane changes (throughput changes, failovers, region additions)
az monitor activity-log list -g "$RESOURCE_GROUP" --resource-id "$COSMOS_ID" \
  --start-time "$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%MZ)" -o table

# Availability metric
az monitor metrics list --resource "$COSMOS_ID" --metric "ServiceAvailability" \
  --interval PT1H --start-time "$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%MZ)" -o table
```

## Suggested triage workflow

1. **Symptom is 429s / "throttled" errors** → step 2 (RU metrics) → step 3 (hot partition check) → step 1 (confirm actual provisioned RU/s vs. traffic).
2. **Symptom is a slow specific operation** → get the query from `app-insights-kql`/`chrome-devtools-frontend` first → step 4 (inspect its shape and RU cost) → check indexing policy.
3. **"Nothing shows up in our logs for Cosmos"** → step 5, check diagnostic settings are actually configured before assuming a query problem.
4. **Intermittent regional issue** → step 6, cross-reference with `azure-monitor`'s resource-health check for the account.
