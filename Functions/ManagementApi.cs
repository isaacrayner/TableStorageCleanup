using System.Net;
using System.Text.Json;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using TableStorageCleanup.Services;

namespace TableStorageCleanup.Functions;

/// <summary>Return type for <see cref="ManagementApi.StartRun"/>: an HTTP response plus an optional queue message.</summary>
public sealed class StartRunOutput
{
    [QueueOutput(CleanupQueueWorker.QueueName, Connection = "AzureWebJobsStorage")]
    public string? QueueMessage { get; set; }

    public HttpResponseData Response { get; set; } = default!;
}

public sealed record StartRunBody(List<string>? Accounts, bool DryRun = true, int? RetentionDays = null);

/// <summary>
/// HTTP endpoints backing the web UI. All endpoints are protected by <see cref="AuthGuard"/>.
/// Secrets (connection strings) are never returned - only setting names and account names.
/// </summary>
public sealed class ManagementApi
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    private readonly IConfiguration _config;
    private readonly StorageAccountRegistry _registry;
    private readonly RunStore _store;
    private readonly AuthGuard _auth;
    private readonly ILogger<ManagementApi> _logger;

    public ManagementApi(IConfiguration config, StorageAccountRegistry registry, RunStore store, AuthGuard auth, ILogger<ManagementApi> logger)
    {
        _config = config;
        _registry = registry;
        _store = store;
        _auth = auth;
        _logger = logger;
    }

    /// <summary>Serves the single-page UI at the site root.</summary>
    [Function("Ui")]
    public async Task<HttpResponseData> Ui(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "{ignored:maxlength(0)?}")] HttpRequestData req)
    {
        if (!_auth.UiEnabled) return req.CreateResponse(HttpStatusCode.NotFound);

        string path = Path.Combine(AppContext.BaseDirectory, "wwwroot", "index.html");
        var res = req.CreateResponse(HttpStatusCode.OK);
        res.Headers.Add("Content-Type", "text/html; charset=utf-8");
        res.Headers.Add("Cache-Control", "no-cache");
        res.Headers.Add("X-Content-Type-Options", "nosniff");
        res.Headers.Add("X-Frame-Options", "DENY");
        res.Headers.Add("Content-Security-Policy",
            "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'");
        await res.WriteStringAsync(await File.ReadAllTextAsync(path));
        return res;
    }

    [Function("GetOverview")]
    public async Task<HttpResponseData> GetOverview(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "api/overview")] HttpRequestData req)
    {
        string user = "";
        if (await _auth.AuthoriseAsync(req, u => user = u) is { } denied) return denied;

        var options = CleanupOptions.From(_config);
        return await Ok(req, new
        {
            user,
            options.RetentionDays,
            options.MinRetentionDays,
            options.TablePrefix,
            options.TimerSchedule,
            options.TimerDryRun,
            accounts = _registry.GetAll().Select(a => new { a.Key, a.AccountName, a.AuthMode })
        });
    }

    [Function("ListTables")]
    public async Task<HttpResponseData> ListTables(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "api/accounts/{key}/tables")] HttpRequestData req,
        string key, CancellationToken ct)
    {
        if (await _auth.AuthoriseAsync(req, _ => { }) is { } denied) return denied;
        if (_registry.Find(key) is not { } target) return await Problem(req, HttpStatusCode.NotFound, $"Unknown account '{key}'.");

        try
        {
            var options = CleanupOptions.From(_config);
            var tables = await new TableCleaner(target.Client, _logger).ListTablesAsync(options.TablePrefix, ct);
            return await Ok(req, new { key = target.Key, target.AccountName, tables });
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _logger.LogWarning(ex, "Failed to list tables for {Key}", key);
            return await Problem(req, HttpStatusCode.BadGateway, $"Could not connect to '{target.AccountName}': {ex.Message}");
        }
    }

    /// <summary>Counts rows older than the retention cutoff, capped at <c>max</c> (default 10,000) to keep the request fast.</summary>
    [Function("EstimateTable")]
    public async Task<HttpResponseData> EstimateTable(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "api/accounts/{key}/tables/{table}/estimate")] HttpRequestData req,
        string key, string table, CancellationToken ct)
    {
        if (await _auth.AuthoriseAsync(req, _ => { }) is { } denied) return denied;
        if (_registry.Find(key) is not { } target) return await Problem(req, HttpStatusCode.NotFound, $"Unknown account '{key}'.");

        var options = CleanupOptions.From(_config);
        if (!table.StartsWith(options.TablePrefix, StringComparison.Ordinal))
            return await Problem(req, HttpStatusCode.BadRequest, $"Table must start with '{options.TablePrefix}'.");

        var query = System.Web.HttpUtility.ParseQueryString(req.Url.Query);
        int days = int.TryParse(query["retentionDays"], out var d) ? Math.Max(d, options.MinRetentionDays) : options.RetentionDays;
        long max = long.TryParse(query["max"], out var m) ? Math.Clamp(m, 1, 100_000) : 10_000;

        try
        {
            var cutoff = DateTimeOffset.UtcNow.AddDays(-days);
            var (count, capped) = await new TableCleaner(target.Client, _logger).CountOldRowsAsync(table, cutoff, max, ct);
            return await Ok(req, new { table, retentionDays = days, cutoff, count, capped });
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _logger.LogWarning(ex, "Estimate failed for {Key}/{Table}", key, table);
            return await Problem(req, HttpStatusCode.BadGateway, ex.Message);
        }
    }

    [Function("ListRuns")]
    public async Task<HttpResponseData> ListRuns(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "api/runs")] HttpRequestData req, CancellationToken ct)
    {
        if (await _auth.AuthoriseAsync(req, _ => { }) is { } denied) return denied;
        var query = System.Web.HttpUtility.ParseQueryString(req.Url.Query);
        int top = int.TryParse(query["top"], out var t) ? Math.Clamp(t, 1, 100) : 20;
        return await Ok(req, await _store.ListAsync(top, ct));
    }

    [Function("GetRun")]
    public async Task<HttpResponseData> GetRun(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "api/runs/{runId}")] HttpRequestData req,
        string runId, CancellationToken ct)
    {
        if (await _auth.AuthoriseAsync(req, _ => { }) is { } denied) return denied;
        return await _store.GetAsync(runId, ct) is { } run
            ? await Ok(req, run)
            : await Problem(req, HttpStatusCode.NotFound, "Run not found.");
    }

    /// <summary>Queues a new run. Defaults to a dry run unless <c>dryRun: false</c> is explicitly sent.</summary>
    [Function("StartRun")]
    public async Task<StartRunOutput> StartRun(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "api/runs")] HttpRequestData req, CancellationToken ct)
    {
        string user = "";
        if (await _auth.AuthoriseAsync(req, u => user = u) is { } denied) return new StartRunOutput { Response = denied };

        // Basic CSRF defence: require a JSON body (cross-site forms can't send application/json without a CORS preflight).
        if (!req.Headers.TryGetValues("Content-Type", out var ctype) || !ctype.Any(v => v.StartsWith("application/json", StringComparison.OrdinalIgnoreCase)))
            return new StartRunOutput { Response = await Problem(req, HttpStatusCode.UnsupportedMediaType, "Content-Type must be application/json.") };

        StartRunBody? body;
        try
        {
            body = await JsonSerializer.DeserializeAsync<StartRunBody>(req.Body, Json, ct);
        }
        catch (JsonException)
        {
            body = null;
        }
        if (body is null)
            return new StartRunOutput { Response = await Problem(req, HttpStatusCode.BadRequest, "Invalid JSON body.") };

        var options = CleanupOptions.From(_config);
        int retention = body.RetentionDays ?? options.RetentionDays;
        if (retention < options.MinRetentionDays)
            return new StartRunOutput { Response = await Problem(req, HttpStatusCode.BadRequest, $"Retention must be at least {options.MinRetentionDays} days (MIN_RETENTION_DAYS).") };

        var known = _registry.GetAll().Select(a => a.Key).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var accounts = body.Accounts?.Where(a => !string.IsNullOrWhiteSpace(a)).Distinct(StringComparer.OrdinalIgnoreCase).ToList() ?? new();
        if (accounts.FirstOrDefault(a => !known.Contains(a)) is { } unknown)
            return new StartRunOutput { Response = await Problem(req, HttpStatusCode.BadRequest, $"Unknown account '{unknown}'.") };
        if (known.Count == 0)
            return new StartRunOutput { Response = await Problem(req, HttpStatusCode.BadRequest, "No STORAGE_ACCOUNT_* settings are configured.") };

        var run = new RunRecord
        {
            RunId = RunStore.NewRunId(),
            Trigger = "Manual",
            RequestedBy = user,
            DryRun = body.DryRun,
            RetentionDays = retention,
            TablePrefix = options.TablePrefix,
            CreatedUtc = DateTimeOffset.UtcNow,
            RequestedAccounts = accounts
        };
        await _store.SaveAsync(run, ct);
        _logger.LogInformation("Run {RunId} queued by {User} (dryRun={DryRun}, retention={Retention}d, accounts={Accounts})",
            run.RunId, user, run.DryRun, retention, accounts.Count == 0 ? "all" : string.Join(",", accounts));

        return new StartRunOutput
        {
            QueueMessage = JsonSerializer.Serialize(new CleanupRequest(run.RunId), Json),
            Response = await Ok(req, run, HttpStatusCode.Accepted)
        };
    }

    private static async Task<HttpResponseData> Ok(HttpRequestData req, object payload, HttpStatusCode status = HttpStatusCode.OK)
    {
        var res = req.CreateResponse(status);
        await res.WriteAsJsonAsync(payload);
        return res;
    }

    private static async Task<HttpResponseData> Problem(HttpRequestData req, HttpStatusCode status, string message)
    {
        var res = req.CreateResponse(status);
        await res.WriteAsJsonAsync(new { error = message });
        return res;
    }
}
