---
name: azure-cosmos-db
description: Read-only Azure Cosmos DB investigation via Azure CLI (and read-only SQL/NoSQL queries) — RU consumption and throttling (429s), hot partitions, slow queries, indexing policy, consistency level, diagnostic logs, and account-level health. Use whenever the user reports "Cosmos throttling", "429 errors", "RU exhausted", "slow document query", "partition is hot", or wants to check container/database config, throughput provisioning, or diagnostic logs for a Cosmos-backed service. Complements azure-sql-database (same role, different data store) and azure-monitor (platform metrics/activity log also cover Cosmos accounts). NEVER creates, updates, deletes, or upserts documents, containers, databases, or throughput settings — reads and diagnostic queries only.
---

# Azure Cosmos DB (read-only)

Investigates Cosmos DB–backed issues: throttling, slow queries, hot partitions, and configuration drift. Same role as `azure-sql-database` but for the NoSQL side of the stack, if/when the product uses Cosmos DB alongside (or instead of) Azure SQL for a given service.

## Hard rule: read-only, no exceptions

Only ever use: `list`, `show`, `list-metrics`, `az cosmosdb sql container show/list`, `az cosmosdb sql database show/list`, read-only `SELECT`-style Cosmos SQL queries (`SELECT * FROM c WHERE ...`), and metrics/log reads.

**Never** run: `create`, `update`, `delete`, `az cosmosdb sql container throughput update`, `az cosmosdb sql container merge`, `az cosmosdb create/restore`, any document `upsert`/`replace`/`delete`/`patch`, or migrate/failover operations. If a fix requires changing RU/s, partition key, or indexing policy, propose it — don't execute it.

## Setup

Add these to `~/.agents/.env` if not already present (ask the user to fill in real values — don't guess):

```ini
AZURE_COSMOS_ACCOUNT=
AZURE_COSMOS_DATABASE=
AZURE_COSMOS_CONTAINER=
```

```bash
set -a; source ~/.agents/.env; set +a
az account set --subscription "$SUBSCRIPTION"

COSMOS_ID=$(az cosmosdb show -g "$RESOURCE_GROUP" -n "$AZURE_COSMOS_ACCOUNT" --query id -o tsv)
```

## 1. Account & container config — "what are we actually provisioned for"

```bash
# Account-level: consistency level, regions, capabilities (e.g. serverless vs provisioned)
az cosmosdb show -g "$RESOURCE_GROUP" -n "$AZURE_COSMOS_ACCOUNT" \
  --query "{consistency:consistencyPolicy.defaultConsistencyLevel, locations:locations[].locationName, capabilities:capabilities}" -o json

# Database + container list
az cosmosdb sql database list -g "$RESOURCE_GROUP" -a "$AZURE_COSMOS_ACCOUNT" -o table
az cosmosdb sql container list -g "$RESOURCE_GROUP" -a "$AZURE_COSMOS_ACCOUNT" -d "$AZURE_COSMOS_DATABASE" -o table

# Container detail: partition key path, indexing policy, unique keys, TTL
az cosmosdb sql container show -g "$RESOURCE_GROUP" -a "$AZURE_COSMOS_ACCOUNT" \
  -d "$AZURE_COSMOS_DATABASE" -n "$AZURE_COSMOS_CONTAINER" \
  --query "{partitionKey:resource.partitionKey, indexing:resource.indexingPolicy, ttl:resource.defaultTtl}" -o json

# Provisioned throughput (RU/s) at database or container level — check whichever is set
az cosmosdb sql database throughput show -g "$RESOURCE_GROUP" -a "$AZURE_COSMOS_ACCOUNT" -n "$AZURE_COSMOS_DATABASE" -o json
az cosmosdb sql container throughput show -g "$RESOURCE_GROUP" -a "$AZURE_COSMOS_ACCOUNT" \
  -d "$AZURE_COSMOS_DATABASE" -n "$AZURE_COSMOS_CONTAINER" -o json
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

## Output hygiene

- Always state whether the container uses **provisioned** or **autoscale** throughput, and at **database** or **container** granularity — this changes what "check the RU/s" even means.
- RU numbers are meaningless without the traffic volume alongside them — always pair `TotalRequests`/`NormalizedRUConsumption` with request count, not just the percentage.
- Note partition key path explicitly in any hot-partition finding — the fix (if any) is a data-modeling change, flag it as a proposed solution, not something to apply here.
