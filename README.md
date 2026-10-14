# Table Storage Cleanup - Azure Function & Web UI

A production-ready Azure Function (.NET 8 isolated worker) that cleans up aged diagnostic logs (such as `WADWindowsEventLogsTable`, `WADPerformanceCountersTable`, etc.) across multiple Azure Storage accounts. It includes an embedded, secure web management dashboard, queue-backed manual runs with dry-run verification, and scheduled execution.

---

## Features

- 🕒 **Scheduled Automation**: Runs on a configurable CRON schedule (via Azure Functions Timer Trigger).
- 💻 **Built-in Web Management UI**: Hosted directly by the Azure Function app at the root URL (`/`) with zero external front-end build dependencies.
- 🧪 **Safe Dry Runs**: Count matching records and preview deletions without modifying data. Manual deletion requires explicit `DELETE` confirmation.
- 🗄️ **Multi-Account Discovery**: Dynamically scans any number of storage accounts via `STORAGE_ACCOUNT_*` settings.
- 🔐 **Modern Authentication**: Supports connection strings, Key Vault references, or Azure Managed Identity (`DefaultAzureCredential`).
- 🛡️ **Enterprise Security**: Built-in App Service Authentication (Easy Auth) integration; UI can be secured to specific user principal names (UPNs).
- ⚡ **Asynchronous Worker**: Manual runs from the UI are queued to Azure Storage Queues to avoid HTTP execution timeouts.
- 📊 **Run History & Metrics**: Stores run statistics and per-table execution history in table storage.

---

## Architecture Overview

```
                      ┌───────────────────────────────────────────────┐
                      │             Azure Function App                │
                      │                                               │
  [ User Browser ] ───┼─► GET / (Static Web UI in wwwroot)            │
                      │   GET /api/overview                           │
                      │   GET /api/accounts/{key}/tables              │
                      │   POST /api/runs (Dry run / Delete)           │
                      │            │                                  │
                      │            ▼ (Enqueue run request)            │
                      │   [ Azure Storage Queue: cleanup-requests ]   │
                      │            │                                  │
                      │            ▼                                  │
                      │   [ CleanupQueueWorker Function ]             │
                      │                    │                          │
  [ Timer Trigger ] ──┼────────────────────┼─► [ CleanupService ]     │
  (CRON schedule)     │                    │          │               │
                      └────────────────────┼──────────┼───────────────┘
                                           │          │
                                           ▼          ▼
                             ┌─────────────────────────────────┐
                             │    Target Azure Storage Accounts │
                             │    - WADWindowsEventLogsTable   │
                             │    - WADPerformanceCounters...  │
                             │    - Custom table prefixes      │
                             └─────────────────────────────────┘
```

---

## Configuration Settings

Set these values in `local.settings.json` for local development or as **Application Settings** (Environment Variables) in Azure:

| Setting | Description | Default |
|---|---|---|
| `AzureWebJobsStorage` | Connection string or table service URI for Function runtime, history, and queues. | `UseDevelopmentStorage=true` |
| `STORAGE_ACCOUNT_<NAME>` | Connection string, storage account name, or table endpoint URL. Add one setting per target storage account. | *(at least one required)* |
| `RETENTION_DAYS` | Number of days of logs to retain. Entities older than this cutoff will be cleaned. | `30` |
| `MIN_RETENTION_DAYS` | Safety floor for retention; prevents accidental aggressive deletion. | `7` |
| `TABLE_PREFIX` | Prefix for diagnostic tables to target. | `WAD` |
| `TIMER_SCHEDULE` | CRON expression for scheduled cleanup. | `0 0 3 * * *` (3 AM UTC) |
| `TIMER_DRY_RUN` | If `true`, scheduled runs will only count matching records without deleting. | `false` |
| `UI_ENABLED` | Set to `false` to disable the web UI and management endpoints. | `true` |
| `UI_ALLOW_ANONYMOUS` | Allows access to UI without authentication. Recommended **only** for local development. | `false` |
| `UI_ALLOWED_USERS` | Comma-separated list of allowed user principal names / emails when using Easy Auth. | *(all authenticated users)* |

---

## Local Development

### Prerequisites

- [.NET 8.0 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)
- [Azure Functions Core Tools v4](https://learn.microsoft.com/azure/azure-functions/functions-run-local)
- [Azurite emulator](https://learn.microsoft.com/azure/storage/common/storage-use-azurite) or an active Azure Storage account for local testing

### 1. Clone & Build

```bash
git clone https://github.com/your-org/TableStorageCleanup.git
cd TableStorageCleanup
dotnet build
```

### 2. Configure `local.settings.json`

Copy `local.settings.json.template` to `local.settings.json`:

```json
{
  "IsEncrypted": false,
  "Values": {
    "AzureWebJobsStorage": "UseDevelopmentStorage=true",
    "FUNCTIONS_WORKER_RUNTIME": "dotnet-isolated",
    "STORAGE_ACCOUNT_1": "DefaultEndpointsProtocol=https;AccountName=myteststorage;AccountKey=...;EndpointSuffix=core.windows.net",
    "RETENTION_DAYS": "90",
    "TIMER_SCHEDULE": "0 0 3 * * *",
    "UI_ALLOW_ANONYMOUS": "true",
    "UI_ENABLED": "true"
  }
}
```

### 3. Run Locally

Start Azurite (if using local storage emulation):
```bash
azurite --silent --location c:\azurite --debug c:\azurite\debug.log
```

Start the function host:
```bash
func start
```

Open `http://localhost:7071` in your browser to view the interactive management UI.

---

## Deployment to Azure

### Option 1: Quick Deployment via Core Tools

1. Sign in to your Azure CLI:
   ```bash
   az login
   ```
2. Publish to your existing Azure Function App:
   ```bash
   func azure functionapp publish <your-function-app-name>
   ```

### Option 2: Infrastructure Setup using Azure CLI

```bash
# Variables
RESOURCE_GROUP="rg-tablecleanup-prod"
LOCATION="westeurope"
STORAGE_ACCOUNT="sttablecleanupprod"
FUNCTION_APP="func-tablecleanup-prod"
APP_INSIGHTS="appi-tablecleanup-prod"

# 1. Create Resource Group
az group create --name $RESOURCE_GROUP --location $LOCATION

# 2. Create Storage Account for the Function host
az storage account create \
  --name $STORAGE_ACCOUNT \
  --location $LOCATION \
  --resource-group $RESOURCE_GROUP \
  --sku Standard_LRS \
  --kind StorageV2

# 3. Create Application Insights
az monitor app-insights component create \
  --app $APP_INSIGHTS \
  --location $LOCATION \
  --resource-group $RESOURCE_GROUP \
  --application-type web

# 4. Create the Function App (.NET 8 Isolated on Linux)
az functionapp create \
  --name $FUNCTION_APP \
  --storage-account $STORAGE_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --consumption-plan-location $LOCATION \
  --runtime dotnet-isolated \
  --runtime-version 8 \
  --functions-version 4 \
  --os-type Linux

# 5. Configure App Settings
az functionapp config appsettings set \
  --name $FUNCTION_APP \
  --resource-group $RESOURCE_GROUP \
  --settings \
    "RETENTION_DAYS=90" \
    "TIMER_SCHEDULE=0 0 3 * * *" \
    "STORAGE_ACCOUNT_1=@Microsoft.KeyVault(SecretUri=https://<your-vault>.vault.azure.net/secrets/StorageAccount1/)"

# 6. Publish the code
dotnet publish -c Release
func azure functionapp publish $FUNCTION_APP
```

---

## Security & Best Practices

1. **Authentication (Easy Auth)**:
   - In Azure Portal, navigate to your Function App > **Authentication** > **Add identity provider** (Microsoft Entra ID).
   - Once configured, all requests to the Web UI and API are authenticated automatically.
   - Restrict access to authorized operators using `UI_ALLOWED_USERS`.

2. **Managed Identity / Key Vault**:
   - Instead of storing raw connection strings, use Azure Key Vault references or Managed Identities.
   - For Managed Identity, provide the storage account name or endpoint as the setting value (e.g. `STORAGE_ACCOUNT_PROD=https://mystorage.table.core.windows.net`), enable a System-Assigned Managed Identity on the Function App, and grant `Storage Table Data Contributor` on the target storage account.

3. **Protection Against Accidental Deletion**:
   - `MIN_RETENTION_DAYS` enforces a minimum retention period server-side.
   - Deletion requests from the UI require explicit confirmation by typing `DELETE`.
   - The scheduled timer trigger can be run in `TIMER_DRY_RUN=true` mode if automated deletion is not desired.

---

## Supporting Modernization Scripts

The [`scripts/`](scripts/) directory contains PowerShell utilities to assist during migrations from legacy diagnostics:
- [`Remove-WadExtension.ps1`](scripts/Remove-WadExtension.ps1): Audits and uninstalls legacy Windows Azure Diagnostics (WAD) and OMS agents from Azure VMs.
- [`Deploy-AMAInfrastructure.ps1`](scripts/Deploy-AMAInfrastructure.ps1): Deploys modern Azure Monitor Agent (AMA) infrastructure with Data Collection Rules (DCR).
- [`Delete-WadTables.ps1`](scripts/Delete-WadTables.ps1): Utility to delete entire legacy tables in bulk once migration and validation are complete.
- [`Update-AmaExtensions.ps1`](scripts/Update-AmaExtensions.ps1): Configures automatic minor version upgrades for Azure Monitor Agent extensions.

Refer to [`scripts/README.md`](scripts/README.md) for script usage details.

---

## License

This project is licensed under the [MIT License](LICENSE).
