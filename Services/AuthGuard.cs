using System.Net;
using System.Text;
using System.Text.Json;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Configuration;

namespace TableStorageCleanup.Services;

/// <summary>
/// Protects the management API. Because the UI can delete data, access is denied unless either:
/// <list type="bullet">
///   <item>App Service Authentication ("Easy Auth") is enabled on the Function App and the caller is signed in, or</item>
///   <item><c>UI_ALLOW_ANONYMOUS=true</c> is set (intended for local development only).</item>
/// </list>
/// Optionally restrict to specific users with <c>UI_ALLOWED_USERS</c> (comma-separated UPNs/emails).
/// </summary>
public sealed class AuthGuard
{
    private readonly bool _uiEnabled;
    private readonly bool _allowAnonymous;
    private readonly bool _easyAuthEnabled;
    private readonly HashSet<string> _allowedUsers;

    public AuthGuard(IConfiguration config)
    {
        _uiEnabled = !bool.TryParse(config["UI_ENABLED"], out var enabled) || enabled;
        _allowAnonymous = bool.TryParse(config["UI_ALLOW_ANONYMOUS"], out var anon) && anon;
        // Set by the platform when Easy Auth is on. The platform also strips any spoofed X-MS-CLIENT-PRINCIPAL headers.
        _easyAuthEnabled = string.Equals(config["WEBSITE_AUTH_ENABLED"], "true", StringComparison.OrdinalIgnoreCase);
        _allowedUsers = new HashSet<string>(
            (config["UI_ALLOWED_USERS"] ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries),
            StringComparer.OrdinalIgnoreCase);
    }

    public bool UiEnabled => _uiEnabled;

    /// <summary>Returns <c>null</c> if the request is authorised (and the user name via <paramref name="user"/>), otherwise an error response.</summary>
    public async Task<HttpResponseData?> AuthoriseAsync(HttpRequestData req, Action<string> user)
    {
        if (!_uiEnabled)
            return await Error(req, HttpStatusCode.NotFound, "The management UI is disabled (UI_ENABLED=false).");

        if (_easyAuthEnabled && TryGetPrincipalName(req, out var name))
        {
            if (_allowedUsers.Count > 0 && !_allowedUsers.Contains(name))
                return await Error(req, HttpStatusCode.Forbidden, $"User '{name}' is not listed in UI_ALLOWED_USERS.");
            user(name);
            return null;
        }

        if (_allowAnonymous)
        {
            user("anonymous");
            return null;
        }

        return await Error(req, HttpStatusCode.Unauthorized,
            "Authentication required. Enable App Service Authentication (Easy Auth) on the Function App, " +
            "or set UI_ALLOW_ANONYMOUS=true for local development.");
    }

    private static bool TryGetPrincipalName(HttpRequestData req, out string name)
    {
        name = "";
        if (req.Headers.TryGetValues("X-MS-CLIENT-PRINCIPAL-NAME", out var names) && names.FirstOrDefault() is { Length: > 0 } n)
        {
            name = n;
            return true;
        }

        if (req.Headers.TryGetValues("X-MS-CLIENT-PRINCIPAL", out var encoded) && encoded.FirstOrDefault() is { Length: > 0 } b64)
        {
            try
            {
                using var doc = JsonDocument.Parse(Encoding.UTF8.GetString(Convert.FromBase64String(b64)));
                foreach (var claim in doc.RootElement.GetProperty("claims").EnumerateArray())
                {
                    string type = claim.GetProperty("typ").GetString() ?? "";
                    if (type is "preferred_username" or "name" or "email"
                        || type.EndsWith("/upn") || type.EndsWith("/emailaddress"))
                    {
                        name = claim.GetProperty("val").GetString() ?? "";
                        if (name.Length > 0) return true;
                    }
                }
            }
            catch (Exception ex) when (ex is FormatException or JsonException or KeyNotFoundException or InvalidOperationException)
            {
                // Malformed header - treat as unauthenticated.
            }
        }
        return false;
    }

    private static async Task<HttpResponseData> Error(HttpRequestData req, HttpStatusCode status, string message)
    {
        var res = req.CreateResponse(status);
        await res.WriteAsJsonAsync(new { error = message });
        return res;
    }
}
