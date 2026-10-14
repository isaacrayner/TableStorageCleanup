using System.Text.Json;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using TableStorageCleanup.Services;

namespace TableStorageCleanup.Functions;

/// <summary>
/// Processes runs requested from the UI. Runs are queued rather than executed inside the HTTP request
/// because large cleanups can take far longer than the ~230s HTTP timeout.
/// </summary>
public sealed class CleanupQueueWorker
{
    public const string QueueName = "cleanup-requests";

    private readonly RunStore _store;
    private readonly CleanupService _cleanup;
    private readonly ILogger<CleanupQueueWorker> _logger;

    public CleanupQueueWorker(RunStore store, CleanupService cleanup, ILogger<CleanupQueueWorker> logger)
    {
        _store = store;
        _cleanup = cleanup;
        _logger = logger;
    }

    [Function(nameof(CleanupQueueWorker))]
    public async Task Run([QueueTrigger(QueueName, Connection = "AzureWebJobsStorage")] string message, CancellationToken ct)
    {
        var request = JsonSerializer.Deserialize<CleanupRequest>(message, new JsonSerializerOptions(JsonSerializerDefaults.Web));
        if (request is null || string.IsNullOrWhiteSpace(request.RunId))
        {
            _logger.LogError("Ignoring malformed queue message: {Message}", message);
            return;
        }

        var run = await _store.GetAsync(request.RunId, ct);
        if (run is null)
        {
            _logger.LogError("Run {RunId} not found - ignoring.", request.RunId);
            return;
        }
        if (run.Status != RunStatus.Queued)
        {
            _logger.LogWarning("Run {RunId} is already {Status} - not re-running.", run.RunId, run.Status);
            return;
        }

        await _cleanup.ExecuteAsync(run, ct);
    }
}
