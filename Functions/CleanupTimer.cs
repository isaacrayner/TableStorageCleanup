using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using TableStorageCleanup.Services;

namespace TableStorageCleanup.Functions;

/// <summary>Scheduled cleanup across every configured storage account.</summary>
public sealed class CleanupTimer
{
    private readonly IConfiguration _config;
    private readonly CleanupService _cleanup;
    private readonly ILogger<CleanupTimer> _logger;

    public CleanupTimer(IConfiguration config, CleanupService cleanup, ILogger<CleanupTimer> logger)
    {
        _config = config;
        _cleanup = cleanup;
        _logger = logger;
    }

    // RunOnStartup is intentionally false: with it enabled, every cold start / scale-out / redeploy would trigger a destructive run.
    // Use the web UI (or POST /api/runs) to run on demand.
    [Function(nameof(CleanupTimer))]
    public async Task Run([TimerTrigger("%TIMER_SCHEDULE%", RunOnStartup = false)] TimerInfo timer, CancellationToken ct)
    {
        var options = CleanupOptions.From(_config);
        var run = new RunRecord
        {
            RunId = RunStore.NewRunId(),
            Trigger = "Timer",
            RequestedBy = "schedule",
            DryRun = options.TimerDryRun,
            RetentionDays = options.RetentionDays,
            TablePrefix = options.TablePrefix,
            CreatedUtc = DateTimeOffset.UtcNow
        };

        if (timer.IsPastDue)
            _logger.LogWarning("Timer is running late (past due).");

        await _cleanup.ExecuteAsync(run, ct);
    }
}
