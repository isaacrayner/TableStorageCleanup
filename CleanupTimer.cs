
using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Configuration;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions;

public class CleanupTimer
{
    private readonly IConfiguration _config;
    private readonly ILogger<CleanupTimer> _logger;

    public CleanupTimer(IConfiguration config, ILogger<CleanupTimer> logger)
    {
        _config = config;
        _logger = logger;
    }

    [Function("CleanupTimer")]
    public async Task Run([TimerTrigger("%TIMER_SCHEDULE%", RunOnStartup = true)] TimerInfo timer)
    {
        int retentionDays = int.TryParse(_config["RETENTION_DAYS"], out var rd) ? rd : 30;
        _logger.LogInformation("Cleaning WAD tables older than {RetentionDays} days...", retentionDays);

        // Discover all STORAGE_ACCOUNT_* settings (no hardcoded limit)
        var connectionKeys = _config.AsEnumerable()
            .Where(kvp => kvp.Key.StartsWith("STORAGE_ACCOUNT_", StringComparison.OrdinalIgnoreCase))
            .Select(kvp => kvp.Key)
            .OrderBy(k => k)
            .ToList();

        _logger.LogInformation("Found {Count} storage account(s) to process", connectionKeys.Count);

        int totalDeleted = 0;

        foreach (var key in connectionKeys)
        {
            var conn = _config[key];
            if (string.IsNullOrWhiteSpace(conn))
            {
                _logger.LogWarning("Application setting {Key} is not set - skipping.", key);
                continue;
            }

            try
            {
                var cleaner = new TableCleaner(conn, _logger);
                var (accountName, deleted) = await cleaner.CleanWadTablesAsync(TimeSpan.FromDays(retentionDays));
                _logger.LogInformation("Completed account {AccountName}. Rows deleted: {Deleted}", accountName, deleted);
                totalDeleted += deleted;
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Failed processing storage account from setting {Key}", key);
            }
        }

        _logger.LogInformation("Cleanup complete. Total rows deleted: {Total}", totalDeleted);
    }
}
