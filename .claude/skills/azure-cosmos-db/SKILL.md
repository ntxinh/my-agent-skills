---
name: azure-cosmos-db
description: Read-only Azure Cosmos DB investigation via Azure CLI (and read-only SQL/NoSQL queries) — RU consumption and throttling (429s), hot partitions, slow queries, indexing policy, consistency level, diagnostic logs, and account-level health. Use whenever the user reports "Cosmos throttling", "429 errors", "RU exhausted", "slow document query", "partition is hot", or wants to check container/database config, throughput provisioning, or diagnostic logs for a Cosmos-backed service. Complements azure-sql-database (same role, different data store) and azure-monitor (platform metrics/activity log also cover Cosmos accounts). NEVER creates, updates, deletes, or upserts documents, containers, databases, or throughput settings — reads and diagnostic queries only.
---

# Azure Cosmos DB (read-only)

Investigates Cosmos DB–backed issues: throttling, slow queries, hot partitions, and configuration drift. Same role as `azure-sql-database` but for the NoSQL side of the stack, if/when the product uses Cosmos DB alongside (or instead of) Azure SQL for a given service.

## Hard rule: read-only, no exceptions

Only ever use: `list`, `show`, `list-metrics`, `az cosmosdb sql container show/list`, `az cosmosdb sql database show/list`, read-only `SELECT`-style Cosmos SQL queries (`SELECT * FROM c WHERE ...`), and metrics/log reads.

**Never** run: `create`, `update`, `delete`, `az cosmosdb sql container throughput update`, `az cosmosdb sql container merge`, `az cosmosdb create/restore`, any document `upsert`/`replace`/`delete`/`patch`, or migrate/failover operations. If a fix requires changing RU/s, partition key, or indexing policy, propose it — don't execute it.

## Configuration

Connection settings live in a small JSON config, resolved per environment — not in a `.env` file.

### Step 1 — determine the environment

Exactly two environments are supported: `qa` and `production`. Querying the wrong one can produce misleading results, so:

- If the user's instruction names the environment (`qa`, `production`, or an obvious equivalent like "prod"), use that.
- If it's unspecified or ambiguous, **ask the user which environment before running anything.** Do not guess.

### Step 2 — resolve config for that environment

```bash
scripts/resolve_config.sh --env qa        # or: --env production
```

The script checks, in order:
1. **Project override** — walks up from the current directory to the nearest git root, then reads `<repo-root>/.claude/azure-cosmos-db.json`.
2. **Personal/global default** — `~/.claude/azure-cosmos-db.json`.
3. If neither file defines the requested environment, it exits non-zero (exit code `1`). **Fall through to the discovery flow below — never fabricate values.**

On success, it prints one JSON object with the resolved fields on stdout (exit `0`), after validating that all required fields are present.

### Step 3 — discovery flow (only if resolution fails)

1. Run `az cosmosdb list` (and `az group list` if the resource group is also unknown) to find likely candidate Cosmos accounts for the requested environment. If a database/container also needs to be discovered, use `az cosmosdb sql database list` / `az cosmosdb sql container list` (see step 1 of `references/investigation-playbook.md`) once the account is known.
2. Confirm the match with the user, or let them pick from a short list if there's more than one candidate.
3. Ask whether to save the resolved values to the **project-level** config (`<repo-root>/.claude/azure-cosmos-db.json`) for next time.
4. **Never write the config file without the user's explicit confirmation.**

### Config fields

| Field | Required | Description |
|---|---|---|
| `subscriptionId` | Yes | Azure subscription ID or name containing the account, used for `az account set --subscription` |
| `resourceGroup` | Yes | Resource group containing the Cosmos DB account |
| `accountName` | Yes | The Cosmos DB account name, used with `az cosmosdb show -n` and as the `-a` value for `az cosmosdb sql ...` commands |
| `databaseName` | No | The SQL API database name. Only needed for database/container-scoped steps (config, throughput, queries) — account-level checks (RU metrics, hot partitions, diagnostics, activity log) don't need it |
| `containerName` | No | The container within `databaseName`. Same scope note as above |

`databaseName`/`containerName` are optional because a lot of Cosmos triage (throttling metrics, activity log, diagnostic settings, account health) is account-level. When a specific step needs one and it isn't in the resolved config, ask the user or discover it via `az cosmosdb sql database/container list` rather than guessing.

See `assets/config.example.json` for a filled-in example covering both environments.

### Using the resolved config

```bash
CONFIG=$(scripts/resolve_config.sh --env qa) || {
  # resolution failed — run the discovery flow instead of guessing
  exit 1
}

SUBSCRIPTION_ID=$(jq -r '.subscriptionId' <<<"$CONFIG")
RESOURCE_GROUP=$(jq -r '.resourceGroup'   <<<"$CONFIG")
ACCOUNT_NAME=$(jq -r '.accountName'       <<<"$CONFIG")
DATABASE_NAME=$(jq -r '.databaseName // empty' <<<"$CONFIG")
CONTAINER_NAME=$(jq -r '.containerName // empty' <<<"$CONFIG")

az account set --subscription "$SUBSCRIPTION_ID"
COSMOS_ID=$(az cosmosdb show -g "$RESOURCE_GROUP" -n "$ACCOUNT_NAME" --query id -o tsv)
```

With `$COSMOS_ID`, `$RESOURCE_GROUP`, `$ACCOUNT_NAME`, and (if present) `$DATABASE_NAME`/`$CONTAINER_NAME` set, proceed to the investigation commands.

## Investigation playbook

The full command set — account/container config, RU consumption & throttling metrics, hot-partition checks, slow-query inspection, diagnostic logs, and account health — plus the suggested triage workflow (which step to start with for a given symptom) live in `references/investigation-playbook.md`. Load that file once the environment and config are resolved.

## Output hygiene

- Always state whether the container uses **provisioned** or **autoscale** throughput, and at **database** or **container** granularity — this changes what "check the RU/s" even means.
- RU numbers are meaningless without the traffic volume alongside them — always pair `TotalRequests`/`NormalizedRUConsumption` with request count, not just the percentage.
- Note partition key path explicitly in any hot-partition finding — the fix (if any) is a data-modeling change, flag it as a proposed solution, not something to apply here.
