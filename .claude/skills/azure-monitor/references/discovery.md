# Discovery flow (config not found for the requested environment)

If `scripts/resolve_config.sh --env <qa|production>` exits non-zero, do not
guess resource names or invent an ID. Instead:

1. **Discover candidates with read-only commands.** Use the resource group (if
   known) or ask the user for it, then list what's actually there:

   ```bash
   az group list --query "[].name" -o tsv
   az webapp list -g "$RESOURCE_GROUP" --query "[].{name:name, id:id}" -o table
   az sql server list -g "$RESOURCE_GROUP" --query "[].name" -o tsv
   az sql db list -g "$RESOURCE_GROUP" -s "$SQL_SERVER_NAME" --query "[].name" -o tsv
   az storage account list -g "$RESOURCE_GROUP" --query "[].name" -o tsv
   az account list --query "[].{name:name, id:id}" -o table
   ```

2. **Confirm with the user.** Present the short list of candidates (or the
   single match, if there's only one) and have them confirm which resource(s)
   correspond to the environment they meant. Never assume the first result is
   correct.

3. **Offer to persist it.** Once confirmed, ask whether to save the resolved
   values to the project config file:

   ```
   <repo-root>/.claude/azure-monitor.json
   ```

   under the relevant environment key (`qa` or `production`), merging with
   whatever's already in that file (don't clobber the other environment's
   block, or fields for other skills if the file is shared). **Never write
   this file without explicit user confirmation.** If they decline, proceed
   with the values for this session only.

4. **Field names to use when writing the file** — match `assets/config.example.json`:
   `subscriptionId`, `resourceGroup`, `appServiceBackendName`,
   `appServiceFrontendName`, `sqlServerName`, `sqlDatabaseName`,
   `storageAccountName`. Only `subscriptionId` and `resourceGroup` are
   required; omit any optional field you didn't resolve.
