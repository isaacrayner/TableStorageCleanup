# Table Storage Cleanup - Azure Function

An Azure Function that automatically cleans up old Windows Azure Diagnostics (WAD) logs from Azure Table Storage across multiple storage accounts.

## Overview

This timer-triggered Azure Function deletes diagnostic log entries older than a configurable retention period from WAD tables (such as `WADWindowsEventLogsTable`, `WADPerformanceCountersTable`, etc.) across multiple storage accounts. It runs on a schedule, processes tables efficiently using batch operations, and provides detailed logging of cleanup activities.

## Features

- 🕒 **Scheduled execution** via CRON timer trigger
- 🗄️ **Multi-account support** - dynamically processes any number of storage accounts
- 🎯 **Smart table discovery** - automatically finds all WAD* tables
- ⚡ **Efficient batch deletion** - deletes up to 100 rows per transaction
- 📊 **Comprehensive logging** - tracks rows deleted per account and table
- 🛡️ **Error resilience** - continues processing even if one account fails
- ⚙️ **Configurable retention** - set custom retention period via environment variables

## Requirements

- .NET 8.0 SDK
- Azure Functions Core Tools v4
- Azure subscription with storage accounts containing WAD tables

## Configuration

### Application Settings

The function requires the following configuration values (set in `local.settings.json` for local development or as Application Settings in Azure):

```json
{
  "IsEncrypted": false,
  "Values": {
    "AzureWebJobsStorage": "UseDevelopmentStorage=true",
    "FUNCTIONS_WORKER_RUNTIME": "dotnet-isolated",
    "STORAGE_ACCOUNT_1": "<connection-string-1>",
    "STORAGE_ACCOUNT_2": "<connection-string-2>",
    "STORAGE_ACCOUNT_3": "<connection-string-3>",
    "RETENTION_DAYS": "90",
    "TIMER_SCHEDULE": "0 0 3 * * *"
  }
}
```

**Note:** You can add as many storage accounts as needed using the naming pattern `STORAGE_ACCOUNT_1`, `STORAGE_ACCOUNT_2`, `STORAGE_ACCOUNT_3`, etc. The function automatically discovers all settings that start with `STORAGE_ACCOUNT_` and processes them in order.

### Configuration Parameters

| Setting | Description | Default |
|---------|-------------|---------|
| `STORAGE_ACCOUNT_1`, `STORAGE_ACCOUNT_2`, etc. | Connection strings for storage accounts to process. Add as many as needed using sequential numbering. Empty values are skipped. | *(at least one required)* |
| `RETENTION_DAYS` | Number of days to retain logs. Rows older than this will be deleted. | `30` |
| `TIMER_SCHEDULE` | CRON expression for execution schedule | `0 0 3 * * *` (daily at 3 AM UTC) |

### CRON Schedule Examples

- `0 0 3 * * *` - Daily at 3:00 AM UTC
- `0 0 */6 * * *` - Every 6 hours
- `0 0 * * * 0` - Weekly on Sunday at midnight
- `0 30 2 * * 1-5` - Weekdays at 2:30 AM

## Local Development

### 1. Clone and Build

```pwsh
git clone <repository-url>
cd TableStorageCleanup
dotnet build
```

### 2. Configure Local Settings

Create or edit `local.settings.json`:

```json
{
  "IsEncrypted": false,
  "Values": {
    "AzureWebJobsStorage": "UseDevelopmentStorage=true",
    "FUNCTIONS_WORKER_RUNTIME": "dotnet-isolated",
    "STORAGE_ACCOUNT_1": "DefaultEndpointsProtocol=https;AccountName=account1;AccountKey=...;EndpointSuffix=core.windows.net",
    "RETENTION_DAYS": "30",
    "TIMER_SCHEDULE": "0 */5 * * * *"
  }
}
```

### 3. Run Locally

```pwsh
func start
```

The function will run according to the schedule specified in `TIMER_SCHEDULE`.

### 4. Trigger Manually (for testing)

To test immediately without waiting for the schedule:

```pwsh
# The function runs automatically on the schedule
# For manual testing, modify RunOnStartup in CleanupTimer.cs temporarily
```

## Deployment to Azure

See [README-deploy.md](README-deploy.md) for comprehensive deployment instructions including:
- Quick deploy with Azure Functions Core Tools
- Full infrastructure deployment with Azure CLI
- Production best practices (Managed Identity, Key Vault, monitoring)
- Troubleshooting guide

Quick deploy to existing Function App:

```pwsh
func azure functionapp publish <your-function-app-name>
```

## How It Works

### Architecture

```
┌─────────────────┐
│  Timer Trigger  │ (CRON schedule)
└────────┬────────┘
         │
         ▼
┌─────────────────────────────────────┐
│  CleanupTimer.cs                    │
│  - Reads configuration              │
│  - Loops through storage accounts   │
│  - Calls TableCleaner for each      │
└────────┬────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────┐
│  TableCleaner.cs                    │
│  - Connects to storage account      │
│  - Discovers WAD* tables            │
│  - Queries old rows (Timestamp)     │
│  - Batch deletes (100 per batch)    │
└─────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────┐
│  Azure Table Storage                │
│  - WADWindowsEventLogsTable         │
│  - WADPerformanceCountersTable      │
│  - WADDiagnosticInfrastructureTable │
│  - ...other WAD* tables             │
└─────────────────────────────────────┘
```

### Execution Flow

1. **Timer trigger fires** based on CRON schedule
2. **Read configuration** - loads retention days and storage account connection strings
3. **For each storage account**:
   - Connect using connection string
   - Query all tables starting with "WAD"
   - For each WAD table:
     - Query rows where `Timestamp < (Now - RetentionDays)`
     - Group rows by `PartitionKey` (batch requirement)
     - Delete in batches of 100 rows
     - Log rows deleted
4. **Log summary** - total rows deleted across all accounts

### Sample Output

```
[2025-11-02 03:00:01] Cleaning WAD tables older than 90 days...
[2025-11-02 03:00:01] Found 3 storage account(s) to process
[2025-11-02 03:00:02] Processing storage account: diagstorage01
[2025-11-02 03:00:15] Table: WADWindowsEventLogsTable – 12340 rows deleted
[2025-11-02 03:00:28] Table: WADPerformanceCountersTable – 6812 rows deleted
[2025-11-02 03:00:35] Table: WADDiagnosticInfrastructureLogsTable – 453 rows deleted
[2025-11-02 03:00:35] Completed account diagstorage01. Rows deleted: 19605
[2025-11-02 03:00:36] Processing storage account: diagstorage02
[2025-11-02 03:00:48] Table: WADWindowsEventLogsTable – 8234 rows deleted
[2025-11-02 03:00:55] Completed account diagstorage02. Rows deleted: 8234
[2025-11-02 03:00:55] Cleanup complete. Total rows deleted: 27839
```

## Code Structure

### Files

- **`CleanupTimer.cs`** - Main Azure Function with timer trigger
- **`TableCleaner.cs`** - Helper class that handles table enumeration and deletion logic
- **`Program.cs`** - Function host startup configuration
- **`host.json`** - Function host settings
- **`TableStorageCleanup.csproj`** - Project file with NuGet dependencies

### Key Dependencies

```xml
<PackageReference Include="Microsoft.Azure.Functions.Worker" Version="1.21.0" />
<PackageReference Include="Microsoft.Azure.Functions.Worker.Extensions.Timer" Version="4.2.0" />
<PackageReference Include="Azure.Data.Tables" Version="12.11.0" />
```

## Performance Considerations

### Efficiency

- **Batch operations**: Deletes up to 100 rows per transaction (Azure Table Storage limit)
- **Pagination**: Processes large tables using continuation tokens (1000 rows per page)
- **Partition grouping**: Groups rows by `PartitionKey` to meet batch transaction requirements

### Cost Optimization

- Runs during off-peak hours (configurable)
- Processes only tables with the "WAD" prefix
- Uses efficient queries with timestamp filters
- Minimal storage transaction costs

### Throttling

Azure Table Storage has rate limits. If you encounter throttling:
- Increase the timer interval (run less frequently)
- Add delays between batch operations
- Process fewer storage accounts per execution

## Monitoring

### Application Insights

If Application Insights is configured, you can:
- View execution history and invocation counts
- Track rows deleted over time
- Set alerts for failures or anomalies
- Monitor execution duration and performance

### View Logs

**In Azure Portal:**
1. Navigate to your Function App
2. Go to **Functions** > **CleanupTimer** > **Monitor**
3. Check **Invocations** and **Logs**

**Stream logs in real-time:**
```pwsh
func azure functionapp logstream <your-function-app-name>
```

**Query Application Insights:**
```kusto
traces
| where operation_Name == "CleanupTimer"
| where timestamp > ago(7d)
| project timestamp, message, severityLevel
| order by timestamp desc
```

## Security Best Practices

### For Production

1. **Use Azure Key Vault** for connection strings:
   ```
   STORAGE_ACCOUNT_1=@Microsoft.KeyVault(SecretUri=https://your-vault.vault.azure.net/secrets/StorageAccount1/)
   ```

2. **Use Managed Identity** instead of connection strings:
   - Enable managed identity on the Function App
   - Grant "Storage Table Data Contributor" role to the identity on each storage account
   - Update code to use `DefaultAzureCredential`

3. **Network Security**:
   - Enable VNET integration for the Function App
   - Configure private endpoints for storage accounts
   - Disable public network access where possible

4. **Least Privilege**:
   - Use role-based access control (RBAC)
   - Grant only necessary permissions (table read/delete)

## Troubleshooting

### Common Issues

**Function not triggering on schedule**
- Verify `AzureWebJobsStorage` is configured correctly
- Check `TIMER_SCHEDULE` is a valid CRON expression
- Review function logs for errors

**No rows deleted despite old data**
- Verify `RETENTION_DAYS` is set correctly
- Check row timestamps are actually older than retention period
- Ensure connection strings are valid

**Batch delete failures**
- Check partition key grouping (batch requires same partition)
- Verify table has rows matching the filter
- Review error logs for specific exceptions

**Timeout errors**
- Increase function timeout in `host.json`
- Process fewer storage accounts per execution
- Add pagination/continuation logic for very large tables

### Enable Detailed Logging

In `host.json`, set log level to `Debug`:

```json
{
  "version": "2.0",
  "logging": {
    "logLevel": {
      "default": "Debug"
    }
  }
}
```

## Contributing

Suggestions and improvements welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Submit a pull request with a clear description

## License

[Specify your license here]

## Support

For issues or questions:
- Check the [Troubleshooting](#troubleshooting) section
- Review [Azure Functions documentation](https://learn.microsoft.com/azure/azure-functions/)
- Open an issue in the repository

## References

- [Azure Functions Timer Trigger](https://learn.microsoft.com/azure/azure-functions/functions-bindings-timer)
- [Azure Table Storage SDK](https://learn.microsoft.com/azure/storage/tables/table-storage-overview)
- [CRON Expression Reference](https://learn.microsoft.com/azure/azure-functions/functions-bindings-timer#ncrontab-expressions)
- [Azure Functions Best Practices](https://learn.microsoft.com/azure/azure-functions/functions-best-practices)
