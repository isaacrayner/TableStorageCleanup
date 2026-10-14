using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace TableStorageCleanup.Services;

/// <summary>Strongly-typed view of the app settings that control cleanup behaviour.</summary>
public sealed class CleanupOptions
{
    public int RetentionDays { get; init; }
    public int MinRetentionDays { get; init; }
    public string TablePrefix { get; init; } = "WAD";
    public string TimerSchedule { get; init; } = "";
    public bool TimerDryRun { get; init; }

    public static CleanupOptions From(IConfiguration config)
    {
        int minRetention = ParseInt(config["MIN_RETENTION_DAYS"], 7);
        return new CleanupOptions
        {
            RetentionDays = Math.Max(ParseInt(config["RETENTION_DAYS"], 30), minRetention),
            MinRetentionDays = minRetention,
            TablePrefix = config["TABLE_PREFIX"] is { Length: > 0 } p ? p : "WAD",
            TimerSchedule = config["TIMER_SCHEDULE"] ?? "",
            TimerDryRun = bool.TryParse(config["TIMER_DRY_RUN"], out var dry) && dry
        };
    }

    private static int ParseInt(string? value, int fallback) => int.TryParse(value, out var v) ? v : fallback;
}

/// <summary>Message placed on the queue when a run is requested from the UI.</summary>
public sealed record CleanupRequest(string RunId);

/// <summary>
/// Executes a cleanup run across one or more storage accounts and records progress in <see cref="RunStore"/>.
/// </summary>
public sealed class CleanupService
{
    private readonly StorageAccountRegistry _registry;
    private readonly RunStore _store;
    private readonly ILogger<CleanupService> _logger;

    public CleanupService(StorageAccountRegistry registry, RunStore store, ILogger<CleanupService> logger)
    {
        _registry = registry;
        _store = store;
        _logger = logger;
    }

    public async Task<RunRecord> ExecuteAsync(RunRecord run, CancellationToken ct)
    {
        var targets = _registry.GetAll();
        if (run.RequestedAccounts.Count > 0)
        {
            var requested = new HashSet<string>(run.RequestedAccounts, StringComparer.OrdinalIgnoreCase);
            targets = targets.Where(t => requested.Contains(t.Key)).ToList();
        }

        var cutoff = DateTimeOffset.UtcNow.AddDays(-run.RetentionDays);
        run.Status = RunStatus.Running;
        run.StartedUtc = DateTimeOffset.UtcNow;
        run.Accounts = targets.Select(t => new AccountResult { Key = t.Key, AccountName = t.AccountName }).ToList();
        await _store.SaveAsync(run, ct);

        _logger.LogInformation("Run {RunId}: {Mode} rows older than {Cutoff:u} ({RetentionDays} days) in '{Prefix}*' tables across {Count} account(s)",
            run.RunId, run.DryRun ? "counting" : "deleting", cutoff, run.RetentionDays, run.TablePrefix, targets.Count);

        bool anyErrors = false;
        try
        {
            for (int i = 0; i < targets.Count; i++)
            {
                var target = targets[i];
                var result = run.Accounts[i];
                result.Status = RunStatus.Running;
                await _store.SaveAsync(run, ct);

                try
                {
                    var cleaner = new TableCleaner(target.Client, _logger);
                    foreach (var tableName in await cleaner.ListTablesAsync(run.TablePrefix, ct))
                    {
                        TableResult tableResult;
                        try
                        {
                            tableResult = await cleaner.CleanTableAsync(tableName, cutoff, run.DryRun, ct);
                        }
                        catch (Exception ex) when (ex is not OperationCanceledException)
                        {
                            _logger.LogError(ex, "Run {RunId}: failed processing table {Table} in {Account}", run.RunId, tableName, target.AccountName);
                            tableResult = new TableResult(tableName, 0, 0, 0, ex.Message);
                        }

                        if (tableResult.Error is not null || tableResult.FailedBatches > 0) anyErrors = true;
                        result.Tables.Add(tableResult);
                        run.TotalMatched += tableResult.RowsMatched;
                        run.TotalDeleted += tableResult.RowsDeleted;

                        _logger.LogInformation("Run {RunId}: {Account}/{Table} - matched {Matched}, deleted {Deleted}, failed batches {Failed}",
                            run.RunId, target.AccountName, tableName, tableResult.RowsMatched, tableResult.RowsDeleted, tableResult.FailedBatches);
                        await _store.SaveAsync(run, ct);
                    }

                    result.Status = result.Tables.Any(t => t.Error is not null || t.FailedBatches > 0)
                        ? RunStatus.CompletedWithErrors
                        : RunStatus.Succeeded;
                }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    anyErrors = true;
                    result.Status = RunStatus.Failed;
                    result.Error = ex.Message;
                    _logger.LogError(ex, "Run {RunId}: failed processing account {Account} ({Key})", run.RunId, target.AccountName, target.Key);
                }
                await _store.SaveAsync(run, ct);
            }

            run.Status = anyErrors ? RunStatus.CompletedWithErrors : RunStatus.Succeeded;
        }
        catch (OperationCanceledException)
        {
            run.Status = RunStatus.Failed;
            run.Error = "Run was cancelled (function timeout or host shutdown). Re-run to continue - cleanup is idempotent.";
            throw;
        }
        catch (Exception ex)
        {
            run.Status = RunStatus.Failed;
            run.Error = ex.Message;
            throw;
        }
        finally
        {
            run.CompletedUtc = DateTimeOffset.UtcNow;
            await _store.SaveAsync(run, CancellationToken.None);
            _logger.LogInformation("Run {RunId} finished with status {Status}. Matched {Matched}, deleted {Deleted}",
                run.RunId, run.Status, run.TotalMatched, run.TotalDeleted);
        }

        return run;
    }
}
