using System.Text.Json;
using Azure;
using Azure.Data.Tables;
using Azure.Identity;
using Microsoft.Extensions.Configuration;

namespace TableStorageCleanup.Services;

public static class RunStatus
{
    public const string Queued = "Queued";
    public const string Running = "Running";
    public const string Succeeded = "Succeeded";
    public const string CompletedWithErrors = "CompletedWithErrors";
    public const string Failed = "Failed";
}

/// <summary>Per-account result stored inside a run record.</summary>
public sealed class AccountResult
{
    public string Key { get; set; } = "";
    public string AccountName { get; set; } = "";
    public string Status { get; set; } = RunStatus.Queued;
    public string? Error { get; set; }
    public List<TableResult> Tables { get; set; } = new();
}

/// <summary>A cleanup run as returned by the API.</summary>
public sealed class RunRecord
{
    public string RunId { get; set; } = "";
    public string Trigger { get; set; } = "";          // Timer | Manual
    public string? RequestedBy { get; set; }
    public bool DryRun { get; set; }
    public int RetentionDays { get; set; }
    public string TablePrefix { get; set; } = "";
    public string Status { get; set; } = RunStatus.Queued;
    public DateTimeOffset CreatedUtc { get; set; }
    public DateTimeOffset? StartedUtc { get; set; }
    public DateTimeOffset? CompletedUtc { get; set; }
    public long TotalMatched { get; set; }
    public long TotalDeleted { get; set; }
    public string? Error { get; set; }
    public List<string> RequestedAccounts { get; set; } = new();
    public List<AccountResult> Accounts { get; set; } = new();
}

/// <summary>
/// Persists run history to a table in the Function App's own storage account (<c>AzureWebJobsStorage</c>).
/// Row keys use inverted ticks so the newest run sorts first.
/// </summary>
public sealed class RunStore
{
    private const string Partition = "run";
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    private readonly TableClient _table;
    private readonly SemaphoreSlim _initLock = new(1, 1);
    private bool _initialised;

    public RunStore(IConfiguration config)
    {
        string tableName = config["RUN_HISTORY_TABLE"] is { Length: > 0 } t ? t : "CleanupRuns";
        _table = CreateServiceClient(config).GetTableClient(tableName);
    }

    public static string NewRunId() =>
        $"{DateTime.MaxValue.Ticks - DateTime.UtcNow.Ticks:D19}-{Guid.NewGuid().ToString("N")[..8]}";

    public async Task SaveAsync(RunRecord run, CancellationToken ct = default)
    {
        await EnsureTableAsync(ct);
        var entity = new TableEntity(Partition, run.RunId)
        {
            ["Status"] = run.Status,
            ["Trigger"] = run.Trigger,
            ["CreatedUtc"] = run.CreatedUtc,
            // Table Storage properties are capped at 64KB; trim table details if a very large run exceeds that.
            ["Payload"] = Serialize(run)
        };
        await _table.UpsertEntityAsync(entity, TableUpdateMode.Replace, ct);
    }

    public async Task<RunRecord?> GetAsync(string runId, CancellationToken ct = default)
    {
        await EnsureTableAsync(ct);
        var response = await _table.GetEntityIfExistsAsync<TableEntity>(Partition, runId, cancellationToken: ct);
        return response.HasValue ? Deserialize(response.Value!) : null;
    }

    public async Task<List<RunRecord>> ListAsync(int top, CancellationToken ct = default)
    {
        await EnsureTableAsync(ct);
        var runs = new List<RunRecord>(top);
        await foreach (var entity in _table.QueryAsync<TableEntity>(e => e.PartitionKey == Partition, maxPerPage: top, cancellationToken: ct))
        {
            if (Deserialize(entity) is { } run) runs.Add(run);
            if (runs.Count >= top) break;
        }
        return runs;
    }

    private static string Serialize(RunRecord run)
    {
        string payload = JsonSerializer.Serialize(run, Json);
        if (payload.Length <= 30_000) return payload; // UTF-16 string property limit is 32K chars

        // Fall back to account-level summaries only.
        var slim = JsonSerializer.Deserialize<RunRecord>(payload, Json)!;
        foreach (var account in slim.Accounts)
        {
            account.Tables = account.Tables
                .GroupBy(_ => "(summary)")
                .Select(g => new TableResult($"{g.Count()} tables (details trimmed)", g.Sum(t => t.RowsMatched), g.Sum(t => t.RowsDeleted), g.Sum(t => t.FailedBatches)))
                .ToList();
        }
        return JsonSerializer.Serialize(slim, Json);
    }

    private static RunRecord? Deserialize(TableEntity entity) =>
        entity.GetString("Payload") is { } payload ? JsonSerializer.Deserialize<RunRecord>(payload, Json) : null;

    private async Task EnsureTableAsync(CancellationToken ct)
    {
        if (_initialised) return;
        await _initLock.WaitAsync(ct);
        try
        {
            if (!_initialised)
            {
                await _table.CreateIfNotExistsAsync(ct);
                _initialised = true;
            }
        }
        finally
        {
            _initLock.Release();
        }
    }

    /// <summary>
    /// Supports both a classic <c>AzureWebJobsStorage</c> connection string and identity-based connections
    /// (<c>AzureWebJobsStorage__accountName</c> / <c>AzureWebJobsStorage__tableServiceUri</c>).
    /// </summary>
    private static TableServiceClient CreateServiceClient(IConfiguration config)
    {
        string? connectionString = config["AzureWebJobsStorage"];
        if (!string.IsNullOrWhiteSpace(connectionString))
            return new TableServiceClient(connectionString);

        string? uri = config["AzureWebJobsStorage:tableServiceUri"];
        string? accountName = config["AzureWebJobsStorage:accountName"];
        Uri endpoint = !string.IsNullOrWhiteSpace(uri)
            ? new Uri(uri)
            : !string.IsNullOrWhiteSpace(accountName)
                ? new Uri($"https://{accountName}.table.core.windows.net")
                : throw new InvalidOperationException(
                    "AzureWebJobsStorage is not configured. Set a connection string or AzureWebJobsStorage__accountName.");

        var credential = new DefaultAzureCredential(new DefaultAzureCredentialOptions
        {
            ManagedIdentityClientId = config["AzureWebJobsStorage:clientId"] ?? config["AZURE_CLIENT_ID"]
        });
        return new TableServiceClient(endpoint, credential);
    }
}
