# Discovery flow (config not found for the requested environment)

If `scripts/resolve_config.sh --env <qa|production>` exits non-zero, do not
guess resource names or invent an ID — and never suggest writing a SAS
token, connection string, or account key anywhere but an ad-hoc,
session-only environment variable. Instead:

1. **Discover candidates with read-only commands.** Ask the user for the
   resource group if you don't already know it, then list what's actually
   there:

   ```bash
   az group list --query "[].name" -o tsv
   az storage account list -g "$RESOURCE_GROUP" --query "[].name" -o tsv
   az storage container list --auth-mode login --account-name "$STORAGE_ACCOUNT_NAME" --query "[].name" -o tsv
   az account list --query "[].{name:name, id:id}" -o table
   ```

2. **Confirm with the user.** Present the short list of candidates (or the
   single match, if there's only one) and have them confirm which storage
   account and container correspond to the environment they meant. Never
   assume the first result is correct.

3. **Infer the directory structure, if unknown.** List the top level of the
   confirmed container to see the folder pattern (e.g. `YYYY/MM/DD/`)
   instead of assuming one:

   ```bash
   az storage blob list --auth-mode login \
     --account-name "$STORAGE_ACCOUNT_NAME" \
     --container-name "$CONTAINER_NAME" \
     --num-results 20 -o table
   ```

4. **Offer to persist the non-secret parts.** Once confirmed, ask whether
   to save the resolved values to the project config file:

   ```
   <repo-root>/.claude/storage-app-service-logs.json
   ```

   under the relevant environment key (`qa` or `production`), merging with
   whatever's already in that file. **Never write this file without
   explicit user confirmation, and never write a `sasToken`,
   `connectionString`, or `accountKey` field into it** — the resolver
   script will reject the file if it finds one anyway.

5. **Field names to use when writing the file** — match
   `assets/config.example.json`: `subscriptionId`, `resourceGroup`,
   `storageAccountName`, `containerName`, `directoryStructurePattern`.
   `subscriptionId`, `storageAccountName`, and `containerName` are required;
   `resourceGroup` and `directoryStructurePattern` are optional.
