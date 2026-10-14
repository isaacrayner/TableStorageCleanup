using System.Text.Json;
using Azure.Core.Serialization;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using TableStorageCleanup.Services;

var host = new HostBuilder()
    .ConfigureFunctionsWorkerDefaults()
    .ConfigureServices(services =>
    {
        services.AddApplicationInsightsTelemetryWorkerService();
        services.ConfigureFunctionsApplicationInsights();

        // camelCase JSON for the UI.
        services.Configure<WorkerOptions>(o =>
            o.Serializer = new JsonObjectSerializer(new JsonSerializerOptions(JsonSerializerDefaults.Web)));

        services.AddSingleton<StorageAccountRegistry>();
        services.AddSingleton<RunStore>();
        services.AddSingleton<AuthGuard>();
        services.AddSingleton<CleanupService>();
    })
    .Build();

host.Run();
