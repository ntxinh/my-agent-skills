# Discovery flow (config not found for the requested environment)

If `scripts/resolve_config.sh --env <qa|production>` exits non-zero, do not
guess resource names or invent an ID — and never invent or ask for the
password to be written anywhere but the `SQLCMDPASSWORD` environment
variable. Instead:

1. **Discover candidates with read-only commands.** Use the resource group
   (if known) or ask the user for it, then list what's actually there:

   ```bash
   az group list --query "[].name" -o tsv
   az sql server list -g "$RESOURCE_GROUP" --query "[].{name:name, id:id}" -o table
   az sql db list -g "$RESOURCE_GROUP" -s "$SQL_SERVER_NAME" --query "[].name" -o tsv
   az account list --query "[].{name:name, id:id}" -o table
   ```

2. **Confirm with the user.** Present the short list of candidates (or the
   single match, if there's only one) and have them confirm which server
   and database correspond to the environment they meant. Never assume the
   first result is correct.

3. **Offer to persist the non-secret parts.** Once confirmed, ask whether to
   save the resolved values to the project config file:

   ```
   <repo-root>/.claude/azure-sql-database.json
   ```

   under the relevant environment key (`qa` or `production`), merging with
   whatever's already in that file. **Never write this file without
   explicit user confirmation, and never write a password field into it** —
   the resolver script will reject the file if it finds one anyway.

4. **Field names to use when writing the file** — match
   `assets/config.example.json`: `subscriptionId`, `resourceGroup`,
   `sqlServerName`, `sqlDatabaseName`, `sqlUsername`. The first three are
   required; the last two are optional but needed for the sqlcmd/DMV
   workflows in `references/commands.md`.

5. **The password is out of scope for this flow entirely.** Ask the user to
   `export SQLCMDPASSWORD=...` in their own shell before running any
   `sqlcmd` command. Do not suggest storing it in a file, an env var baked
   into a script, or anywhere that would persist it to disk.
