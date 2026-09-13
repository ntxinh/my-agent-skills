# Discovery flow (config not found for the requested environment)

If `scripts/resolve_config.sh --env <qa|production>` exits non-zero, do not
guess resource names or invent an ID. Instead:

1. **Discover candidates with read-only commands.** Use the resource group
   (if known) or ask the user for it, then list what's actually there:

   ```bash
   az group list --query "[].name" -o tsv
   az monitor log-analytics workspace list -g "$RESOURCE_GROUP" --query "[].name" -o tsv
   az webapp list -g "$RESOURCE_GROUP" --query "[].name" -o tsv
   az account list --query "[].{name:name, id:id}" -o table
   ```

2. **Confirm with the user.** Present the short list of candidates (or the
   single match, if there's only one) and have them confirm which workspace
   (and App Service names, if relevant) correspond to the environment they
   meant. Never assume the first result is correct.

3. **Offer to persist it.** Once confirmed, ask whether to save the
   resolved values to the project config file:

   ```
   <repo-root>/.claude/log-analytics-workspace.json
   ```

   under the relevant environment key (`qa` or `production`), merging with
   whatever's already in that file (don't clobber the other environment's
   block, or fields for other skills if the file is shared). **Never write
   this file without explicit user confirmation.** If they decline, proceed
   with the values for this session only.

4. **Field names to use when writing the file** — match
   `assets/config.example.json`: `subscriptionId`, `resourceGroup`,
   `logAnalyticsWorkspaceName`, `appServiceBackendName`,
   `appServiceFrontendName`. The first three are required; the App Service
   names are optional and only needed for the backend/frontend filtering
   examples in `references/commands.md`.
