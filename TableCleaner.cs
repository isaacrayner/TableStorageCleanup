using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Azure;
using Azure.Data.Tables;
using Microsoft.Extensions.Logging;

public class TableCleaner
{
    private readonly TableServiceClient _serviceClient;
    private readonly ILogger _logger;
    private readonly string _accountName;

    public TableCleaner(string connectionString, ILogger logger)
    {
        _serviceClient = new TableServiceClient(connectionString);
        _logger = logger;
        _accountName = TryExtractAccountName(connectionString);
    }

    public async Task<(string accountName, int totalDeleted)> CleanWadTablesAsync(TimeSpan retention)
    {
        int totalDeleted = 0;
        _logger.LogInformation("Processing storage account: {Account}", _accountName);
        await foreach (var table in _serviceClient.QueryAsync(filter: $"TableName ge 'WAD' and TableName lt 'WAE'"))
        {
            string tableName = table.Name;
            int deleted = await CleanTableAsync(tableName, retention);
            _logger.LogInformation("Table: {TableName} – {RowsDeleted} rows deleted", tableName, deleted);
            totalDeleted += deleted;
        }
        return (_accountName, totalDeleted);
    }

    private async Task<int> CleanTableAsync(string tableName, TimeSpan retention)
    {
        var tableClient = _serviceClient.GetTableClient(tableName);
        DateTimeOffset cutoff = DateTimeOffset.UtcNow - retention;
        int deleted = 0;
        string filter = $"Timestamp lt datetime'{cutoff:yyyy-MM-ddTHH:mm:ss.fffZ}'";
        
        await foreach (var page in tableClient.QueryAsync<TableEntity>(filter: filter, maxPerPage: 1000).AsPages())
        {
            // Group entities by PartitionKey since batch operations require same PartitionKey
            var partitionGroups = page.Values.GroupBy(e => e.PartitionKey);
            
            foreach (var partitionGroup in partitionGroups)
            {
                var batch = new List<TableTransactionAction>(100);
                foreach (var entity in partitionGroup)
                {
                    batch.Add(new TableTransactionAction(TableTransactionActionType.Delete, entity));
                    if (batch.Count == 100)
                    {
                        try
                        {
                            await tableClient.SubmitTransactionAsync(batch);
                            deleted += batch.Count;
                        }
                        catch (Exception ex)
                        {
                            _logger.LogError(ex, "Batch delete failed for table {TableName}, partition {PartitionKey}", 
                                tableName, partitionGroup.Key);
                        }
                        batch.Clear();
                    }
                }
                if (batch.Count > 0)
                {
                    try
                    {
                        await tableClient.SubmitTransactionAsync(batch);
                        deleted += batch.Count;
                    }
                    catch (Exception ex)
                    {
                        _logger.LogError(ex, "Batch delete failed for table {TableName}, partition {PartitionKey}", 
                            tableName, partitionGroup.Key);
                    }
                }
            }
        }
        return deleted;
    }

    private static string TryExtractAccountName(string connectionString)
    {
        // Try to extract account name from connection string
        var parts = connectionString.Split(';');
        foreach (var part in parts)
        {
            if (part.StartsWith("AccountName=", StringComparison.OrdinalIgnoreCase))
                return part.Substring("AccountName=".Length);
        }
        return "<unknown>";
    }
}