using Azure;
using Azure.Data.Tables;
using Microsoft.Extensions.Logging;

namespace TableStorageCleanup.Services;

/// <summary>Result of cleaning (or dry-run counting) a single table.</summary>
public sealed record TableResult(string TableName, long RowsMatched, long RowsDeleted, int FailedBatches, string? Error = null);

/// <summary>
/// Handles table discovery and batched deletion of old rows for a single storage account.
/// </summary>
public sealed class TableCleaner
{
    private const int BatchSize = 100;   // Azure Table Storage transaction limit
    private const int PageSize = 1000;   // Max rows per query page

    private readonly TableServiceClient _serviceClient;
    private readonly ILogger _logger;

    public TableCleaner(TableServiceClient serviceClient, ILogger logger)
    {
        _serviceClient = serviceClient;
        _logger = logger;
    }

    /// <summary>Lists all tables whose name starts with <paramref name="prefix"/> (case-sensitive, as per Table Storage).</summary>
    public async Task<List<string>> ListTablesAsync(string prefix, CancellationToken ct = default)
    {
        var names = new List<string>();
        await foreach (var table in _serviceClient.QueryAsync(filter: BuildPrefixFilter(prefix), cancellationToken: ct))
        {
            names.Add(table.Name);
        }
        return names;
    }

    /// <summary>
    /// Counts rows older than <paramref name="cutoff"/>, stopping after <paramref name="maxRows"/>.
    /// Returns the count and whether the limit was hit.
    /// </summary>
    public async Task<(long Count, bool Capped)> CountOldRowsAsync(string tableName, DateTimeOffset cutoff, long maxRows, CancellationToken ct = default)
    {
        var tableClient = _serviceClient.GetTableClient(tableName);
        long count = 0;
        await foreach (var page in QueryOldRows(tableClient, cutoff, ct).AsPages())
        {
            count += page.Values.Count;
            if (count >= maxRows) return (maxRows, true);
        }
        return (count, false);
    }

    /// <summary>
    /// Deletes (or, when <paramref name="dryRun"/> is true, only counts) rows older than <paramref name="cutoff"/>.
    /// </summary>
    public async Task<TableResult> CleanTableAsync(string tableName, DateTimeOffset cutoff, bool dryRun, CancellationToken ct = default)
    {
        var tableClient = _serviceClient.GetTableClient(tableName);
        long matched = 0, deleted = 0;
        int failedBatches = 0;

        await foreach (var page in QueryOldRows(tableClient, cutoff, ct).AsPages())
        {
            matched += page.Values.Count;
            if (dryRun) continue;

            // Transactions must target a single PartitionKey and contain at most 100 operations.
            foreach (var partition in page.Values.GroupBy(e => e.PartitionKey))
            {
                foreach (var chunk in partition.Chunk(BatchSize))
                {
                    ct.ThrowIfCancellationRequested();
                    var batch = chunk
                        .Select(e => new TableTransactionAction(TableTransactionActionType.Delete, e, ETag.All))
                        .ToList();
                    try
                    {
                        await tableClient.SubmitTransactionAsync(batch, ct);
                        deleted += batch.Count;
                    }
                    catch (RequestFailedException ex)
                    {
                        failedBatches++;
                        _logger.LogWarning(ex, "Batch delete failed for table {TableName}, partition {PartitionKey} ({Status})",
                            tableName, partition.Key, ex.Status);
                    }
                }
            }
        }

        return new TableResult(tableName, matched, deleted, failedBatches);
    }

    /// <summary>Only PartitionKey/RowKey are projected - deletion doesn't need the payload, which cuts bandwidth substantially.</summary>
    private static AsyncPageable<TableEntity> QueryOldRows(TableClient tableClient, DateTimeOffset cutoff, CancellationToken ct) =>
        tableClient.QueryAsync<TableEntity>(
            filter: TableClient.CreateQueryFilter($"Timestamp lt {cutoff}"),
            maxPerPage: PageSize,
            select: new[] { "PartitionKey", "RowKey" },
            cancellationToken: ct);

    /// <summary>
    /// Builds a range filter equivalent to "TableName startswith prefix", e.g. WAD -> TableName ge 'WAD' and TableName lt 'WAE'.
    /// </summary>
    public static string BuildPrefixFilter(string prefix)
    {
        if (string.IsNullOrEmpty(prefix)) return string.Empty;
        char last = prefix[^1];
        string upper = prefix[..^1] + (char)(last + 1);
        return $"TableName ge '{Escape(prefix)}' and TableName lt '{Escape(upper)}'";
    }

    private static string Escape(string value) => value.Replace("'", "''");
}
