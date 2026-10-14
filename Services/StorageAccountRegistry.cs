using Azure.Data.Tables;
using Azure.Identity;
using Microsoft.Extensions.Configuration;

namespace TableStorageCleanup.Services;

/// <summary>
/// A storage account the function is configured to clean. Secrets never leave this type -
/// only <see cref="Key"/>, <see cref="AccountName"/> and <see cref="AuthMode"/> are exposed to the UI.
/// </summary>
public sealed record StorageAccountTarget(string Key, string AccountName, string AuthMode, TableServiceClient Client);

/// <summary>
/// Discovers <c>STORAGE_ACCOUNT_*</c> app settings and builds a <see cref="TableServiceClient"/> for each.
/// Each setting value may be one of:
/// <list type="bullet">
///   <item>a full connection string (or Key Vault reference resolving to one)</item>
///   <item>a table endpoint URL, e.g. <c>https://myaccount.table.core.windows.net</c> (uses Managed Identity)</item>
///   <item>a bare storage account name, e.g. <c>myaccount</c> (uses Managed Identity)</item>
/// </list>
/// </summary>
public sealed class StorageAccountRegistry
{
    public const string SettingPrefix = "STORAGE_ACCOUNT_";

    private readonly IConfiguration _config;
    private readonly Lazy<DefaultAzureCredential> _credential;

    public StorageAccountRegistry(IConfiguration config)
    {
        _config = config;
        _credential = new Lazy<DefaultAzureCredential>(() => new DefaultAzureCredential(new DefaultAzureCredentialOptions
        {
            ManagedIdentityClientId = config["AZURE_CLIENT_ID"]
        }));
    }

    /// <summary>Returns every configured target, ordered by setting name. Empty settings are skipped.</summary>
    public IReadOnlyList<StorageAccountTarget> GetAll()
    {
        return _config.AsEnumerable()
            .Where(kvp => kvp.Key.StartsWith(SettingPrefix, StringComparison.OrdinalIgnoreCase)
                          && !string.IsNullOrWhiteSpace(kvp.Value))
            .OrderBy(kvp => kvp.Key, StringComparer.OrdinalIgnoreCase)
            .Select(kvp => Create(kvp.Key, kvp.Value!.Trim()))
            .ToList();
    }

    public StorageAccountTarget? Find(string key) =>
        GetAll().FirstOrDefault(t => string.Equals(t.Key, key, StringComparison.OrdinalIgnoreCase));

    private StorageAccountTarget Create(string key, string value)
    {
        if (LooksLikeConnectionString(value))
        {
            return new StorageAccountTarget(key, ExtractAccountName(value), "ConnectionString", new TableServiceClient(value));
        }

        Uri endpoint = value.StartsWith("https://", StringComparison.OrdinalIgnoreCase)
            ? new Uri(value)
            : new Uri($"https://{value}.table.core.windows.net");

        string accountName = endpoint.Host.Split('.')[0];
        return new StorageAccountTarget(key, accountName, "ManagedIdentity", new TableServiceClient(endpoint, _credential.Value));
    }

    private static bool LooksLikeConnectionString(string value) =>
        value.Contains("AccountName=", StringComparison.OrdinalIgnoreCase)
        || value.Contains("UseDevelopmentStorage=true", StringComparison.OrdinalIgnoreCase)
        || value.Contains("SharedAccessSignature=", StringComparison.OrdinalIgnoreCase);

    private static string ExtractAccountName(string connectionString)
    {
        foreach (var part in connectionString.Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            if (part.StartsWith("AccountName=", StringComparison.OrdinalIgnoreCase))
                return part["AccountName=".Length..];
            if (part.StartsWith("TableEndpoint=", StringComparison.OrdinalIgnoreCase)
                && Uri.TryCreate(part["TableEndpoint=".Length..], UriKind.Absolute, out var uri))
                return uri.Host.Split('.')[0];
        }
        return connectionString.Contains("UseDevelopmentStorage=true", StringComparison.OrdinalIgnoreCase)
            ? "devstoreaccount1"
            : "<unknown>";
    }
}
