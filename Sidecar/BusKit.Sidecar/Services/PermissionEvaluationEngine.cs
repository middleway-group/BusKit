using System.Net.Http.Headers;
using System.Text.Json;
using BusKit.Sidecar.Models;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Logging;

namespace BusKit.Sidecar.Services;

/// <summary>
/// Evaluates a user's effective Azure RBAC permissions on a Service Bus namespace
/// using the ARM Permissions API and classifies them into an <see cref="AccessTier"/>.
/// </summary>
/// <remarks>
/// Uses GET .../providers/Microsoft.Authorization/permissions?api-version=2022-04-01
/// which returns effective permissions (wildcards expanded, deny assignments respected)
/// for the bearer token holder at the requested scope.
/// </remarks>
public sealed class PermissionEvaluationEngine
{
    // ── Required control-plane READ permissions ──────────────────────────────
    private static readonly string[] ControlPlaneRead =
    [
        "Microsoft.ServiceBus/namespaces/queues/read",
        "Microsoft.ServiceBus/namespaces/topics/read",
        "Microsoft.ServiceBus/namespaces/topics/subscriptions/read",
    ];

    // ── Required control-plane WRITE permissions ─────────────────────────────
    private static readonly string[] ControlPlaneWrite =
    [
        "Microsoft.ServiceBus/namespaces/queues/write",
        "Microsoft.ServiceBus/namespaces/topics/write",
        "Microsoft.ServiceBus/namespaces/topics/subscriptions/write",
        "Microsoft.ServiceBus/namespaces/topics/subscriptions/rules/write",
    ];

    private const string DataReceive = "Microsoft.ServiceBus/namespaces/messages/receive/action";
    private const string DataSend    = "Microsoft.ServiceBus/namespaces/messages/send/action";

    // ── ARM management endpoints per cloud ───────────────────────────────────
    private static readonly Dictionary<string, string> ManagementEndpoints =
        new(StringComparer.OrdinalIgnoreCase)
        {
            ["AzurePublicCloud"]  = "https://management.azure.com",
            ["AzureUSGovernment"] = "https://management.usgovcloudapi.net",
            ["AzureChinaCloud"]   = "https://management.chinacloudapi.cn",
        };

    // ── Role recommendation table ─────────────────────────────────────────────
    // Never recommends Owner — always the most-scoped built-in role.
    private static readonly Dictionary<AccessTier, RoleUpgradeRecommendation> UpgradeMap =
        new()
        {
            [AccessTier.NoAccess] = new()
            {
                RoleName         = "Reader",
                RoleDefinitionId = "acdd72a7-3385-48ef-bd42-f606fba81ae7",
                TargetTier       = AccessTier.ReadOnly,
                Description      = "Grants read access to Azure resource metadata, including Service Bus entity properties.",
            },
            [AccessTier.ReadOnly] = new()
            {
                RoleName         = "Azure Service Bus Data Receiver",
                RoleDefinitionId = "4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0",
                TargetTier       = AccessTier.MessageReader,
                Description      = "Allows peeking and fetching messages from queues and subscriptions.",
            },
            [AccessTier.MessageReader] = new()
            {
                RoleName         = "Azure Service Bus Data Sender",
                RoleDefinitionId = "69a216fc-b8fb-44d8-bc22-1f3c2cd27a39",
                TargetTier       = AccessTier.MessageOperator,
                Description      = "Adds send permission, enabling purge and dead-letter resubmit operations.",
            },
            [AccessTier.MessageOperator] = new()
            {
                RoleName         = "Azure Service Bus Data Owner",
                RoleDefinitionId = "090c5cfd-751d-490a-894a-3ce6f1109419",
                TargetTier       = AccessTier.FullAccess,
                Description      = "Full data plane access. Combine with Contributor for complete management and data plane access.",
            },
        };

    private readonly IMemoryCache                            _cache;
    private readonly HttpClient                              _httpClient;
    private readonly ILogger<PermissionEvaluationEngine>    _logger;
    private readonly TimeSpan                                _cacheTtl;
    private readonly string                                  _managementEndpoint;

    public PermissionEvaluationEngine(
        IMemoryCache cache,
        IHttpClientFactory httpClientFactory,
        ILogger<PermissionEvaluationEngine> logger,
        TimeSpan? cacheTtl          = null,
        string    cloudEnvironment  = "AzurePublicCloud")
    {
        _cache              = cache;
        _httpClient         = httpClientFactory.CreateClient(nameof(PermissionEvaluationEngine));
        _logger             = logger;
        _cacheTtl           = cacheTtl ?? TimeSpan.FromMinutes(5);
        _managementEndpoint = ManagementEndpoints.GetValueOrDefault(
                                  cloudEnvironment, ManagementEndpoints["AzurePublicCloud"]);
    }

    // ── Public API ────────────────────────────────────────────────────────────

    /// <summary>
    /// Evaluates the calling user's effective permissions for the given Service Bus namespace.
    /// Results are cached by (userId, subscriptionId, resourceGroup, namespaceName).
    /// </summary>
    public async Task<PermissionEvaluationResult> EvaluateAsync(
        string            subscriptionId,
        string            resourceGroupName,
        string            namespaceName,
        string            userId,
        string            bearerToken,
        CancellationToken ct = default)
    {
        var cacheKey = BuildCacheKey(userId, subscriptionId, resourceGroupName, namespaceName);

        if (_cache.TryGetValue(cacheKey, out PermissionEvaluationResult? cached) && cached is not null)
        {
            _logger.LogDebug("RBAC cache hit: user={UserId} ns={Namespace}", userId, namespaceName);
            return cached;
        }

        PermissionEvaluationResult result;
        try
        {
            var entries                         = await FetchPermissionsAsync(subscriptionId, resourceGroupName, namespaceName, bearerToken, ct);
            var (grantedActions, grantedData)   = ComputeEffectivePermissions(entries);
            result                              = ClassifyTier(grantedActions, grantedData);

            _logger.LogInformation(
                "RBAC evaluated: user={UserId} ns={Namespace} tier={Tier} partial={Partial}",
                userId, namespaceName, result.Tier, result.IsPartialAccess);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "RBAC evaluation failed: user={UserId} ns={Namespace}", userId, namespaceName);
            result = FailedResult(ex.Message);
        }

        _cache.Set(cacheKey, result, result.ExpiresAt);
        return result;
    }

    /// <summary>Removes the cached result, forcing re-evaluation on the next call.</summary>
    public void InvalidateCache(string userId, string subscriptionId, string resourceGroupName, string namespaceName)
        => _cache.Remove(BuildCacheKey(userId, subscriptionId, resourceGroupName, namespaceName));

    // ── ARM Permissions API ───────────────────────────────────────────────────

    private async Task<List<PermissionEntry>> FetchPermissionsAsync(
        string            subscriptionId,
        string            resourceGroupName,
        string            namespaceName,
        string            bearerToken,
        CancellationToken ct)
    {
        // The Permissions API aggregates all scopes (subscription → RG → namespace),
        // expands wildcards, and applies deny assignments server-side.
        var url = $"{_managementEndpoint}/subscriptions/{subscriptionId}" +
                  $"/resourceGroups/{resourceGroupName}" +
                  $"/providers/Microsoft.ServiceBus/namespaces/{namespaceName}" +
                  $"/providers/Microsoft.Authorization/permissions?api-version=2022-04-01";

        using var req = new HttpRequestMessage(HttpMethod.Get, url);
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", bearerToken);
        req.Headers.Accept.ParseAdd("application/json");

        // Hard timeout — fail closed if ARM is slow.
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(TimeSpan.FromSeconds(10));

        using var resp = await _httpClient.SendAsync(req, cts.Token);
        resp.EnsureSuccessStatusCode();

        var body = await resp.Content.ReadAsStringAsync(ct);
        using var doc = JsonDocument.Parse(body);

        if (!doc.RootElement.TryGetProperty("value", out var values)) return [];

        var entries = new List<PermissionEntry>();
        foreach (var item in values.EnumerateArray())
        {
            entries.Add(new PermissionEntry(
                Actions:        ReadStringList(item, "actions"),
                NotActions:     ReadStringList(item, "notActions"),
                DataActions:    ReadStringList(item, "dataActions"),
                NotDataActions: ReadStringList(item, "notDataActions")));
        }
        return entries;
    }

    // ── Effective permission computation ──────────────────────────────────────

    private static (HashSet<string> Actions, HashSet<string> DataActions)
        ComputeEffectivePermissions(IReadOnlyList<PermissionEntry> entries)
    {
        var allControl = ControlPlaneRead.Concat(ControlPlaneWrite).ToArray();
        var allData    = new[] { DataReceive, DataSend };

        var granted    = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var denied     = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var grantedDa  = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var deniedDa   = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var entry in entries)
        {
            foreach (var p in allControl)
            {
                if (MatchesAny(p, entry.Actions))    granted.Add(p);
                if (MatchesAny(p, entry.NotActions)) denied.Add(p);
            }
            foreach (var p in allData)
            {
                if (MatchesAny(p, entry.DataActions))    grantedDa.Add(p);
                if (MatchesAny(p, entry.NotDataActions)) deniedDa.Add(p);
            }
        }

        // Deny wins: explicit deny removes any grant.
        foreach (var d in denied)  granted.Remove(d);
        foreach (var d in deniedDa) grantedDa.Remove(d);

        return (granted, grantedDa);
    }

    // ── Tier classification ───────────────────────────────────────────────────

    private PermissionEvaluationResult ClassifyTier(HashSet<string> actions, HashSet<string> dataActions)
    {
        bool hasAllRead  = ControlPlaneRead.All(actions.Contains);
        bool hasAllWrite = ControlPlaneWrite.All(actions.Contains);
        bool hasAnyRead  = ControlPlaneRead.Any(actions.Contains);
        bool hasAnyWrite = ControlPlaneWrite.Any(actions.Contains);
        bool hasReceive  = dataActions.Contains(DataReceive);
        bool hasSend     = dataActions.Contains(DataSend);

        bool hasQueueWrite = actions.Contains("Microsoft.ServiceBus/namespaces/queues/write");
        bool hasTopicWrite = actions.Contains("Microsoft.ServiceBus/namespaces/topics/write");
        bool hasSubWrite   = actions.Contains("Microsoft.ServiceBus/namespaces/topics/subscriptions/write");
        bool hasRulesWrite = actions.Contains("Microsoft.ServiceBus/namespaces/topics/subscriptions/rules/write");

        var caps = BuildCapabilityMap(hasAllRead, hasReceive, hasSend,
                                      hasQueueWrite, hasTopicWrite, hasSubWrite, hasRulesWrite);

        // Standard tier paths
        if (hasAllRead && hasAllWrite && hasReceive && hasSend)
            return MakeResult(AccessTier.FullAccess,      isPartial: false, caps);

        if (hasAllRead && hasReceive && hasSend && !hasAnyWrite)
            return MakeResult(AccessTier.MessageOperator, isPartial: false, caps);

        if (hasAllRead && hasReceive && !hasSend && !hasAnyWrite)
            return MakeResult(AccessTier.MessageReader,   isPartial: false, caps);

        if (hasAllRead && !hasReceive && !hasSend && !hasAnyWrite)
            return MakeResult(AccessTier.ReadOnly,        isPartial: false, caps);

        if (!hasAnyRead && !hasReceive && !hasSend && !hasAnyWrite)
            return MakeResult(AccessTier.NoAccess,        isPartial: false, caps);

        // Non-standard combination → nearest lower tier + partial flag
        var partialTier = DeterminePartialTier(hasAllRead, hasAnyRead, hasReceive, hasSend);
        return MakeResult(partialTier, isPartial: true, caps);
    }

    private static AccessTier DeterminePartialTier(bool hasAllRead, bool hasAnyRead, bool hasReceive, bool hasSend)
    {
        if (!hasAnyRead) return AccessTier.NoAccess; // data perms without read are unusable
        if (hasReceive && hasSend) return AccessTier.MessageOperator;
        if (hasReceive)            return AccessTier.MessageReader;
        return AccessTier.ReadOnly;
    }

    // ── Capability map ────────────────────────────────────────────────────────

    private static CapabilityMap BuildCapabilityMap(
        bool hasAllRead, bool hasReceive, bool hasSend,
        bool hasQueueWrite, bool hasTopicWrite, bool hasSubWrite, bool hasRulesWrite) => new()
    {
        BrowseEntities  = hasAllRead,
        ViewProperties  = hasAllRead,
        PeekFetch       = hasAllRead && hasReceive,
        // Purge is gated at Tier 3 (requires both receive AND send) — see plan.md §Purge Decision.
        Purge           = hasAllRead && hasReceive && hasSend,
        ResubmitDlq     = hasAllRead && hasReceive && hasSend,
        CreateResources = hasAllRead && hasQueueWrite && hasTopicWrite && hasSubWrite,
        ManageFilters   = hasAllRead && hasRulesWrite,
    };

    // ── Result factories ──────────────────────────────────────────────────────

    private PermissionEvaluationResult MakeResult(AccessTier tier, bool isPartial, CapabilityMap caps)
    {
        var now = DateTimeOffset.UtcNow;
        return new PermissionEvaluationResult
        {
            Tier                  = tier,
            IsPartialAccess       = isPartial,
            TierLabel             = TierLabel(tier, isPartial),
            Capabilities          = caps,
            UpgradeRecommendation = UpgradeMap.GetValueOrDefault(tier),
            EvaluationFailed      = false,
            EvaluatedAt           = now,
            ExpiresAt             = now.Add(_cacheTtl),
        };
    }

    private static PermissionEvaluationResult FailedResult(string error)
    {
        var now = DateTimeOffset.UtcNow;
        return new PermissionEvaluationResult
        {
            Tier             = AccessTier.NoAccess,
            IsPartialAccess  = false,
            TierLabel        = "No Access (Evaluation Error)",
            Capabilities     = CapabilityMap.None,
            EvaluationFailed = true,
            ErrorMessage     = error,
            EvaluatedAt      = now,
            ExpiresAt        = now.AddMinutes(1), // Short TTL on failure so retries are fast
        };
    }

    private static string TierLabel(AccessTier tier, bool isPartial)
    {
        var label = tier switch
        {
            AccessTier.NoAccess        => "No Access",
            AccessTier.ReadOnly        => "Read-Only Observer",
            AccessTier.MessageReader   => "Message Reader",
            AccessTier.MessageOperator => "Message Operator",
            AccessTier.FullAccess      => "Full Access",
            _                          => "Unknown",
        };
        return isPartial ? $"{label} (Partial)" : label;
    }

    // ── Wildcard matching ─────────────────────────────────────────────────────

    private static bool MatchesAny(string permission, IReadOnlyList<string> patterns)
        => patterns.Any(p => MatchesPattern(permission, p));

    private static bool MatchesPattern(string permission, string pattern)
    {
        if (pattern == "*") return true;
        if (string.Equals(permission, pattern, StringComparison.OrdinalIgnoreCase)) return true;

        // Prefix wildcard: "Microsoft.ServiceBus/*" or "Microsoft.ServiceBus/namespaces/*"
        if (pattern.EndsWith('*'))
        {
            var prefix = pattern[..^1];
            return permission.StartsWith(prefix, StringComparison.OrdinalIgnoreCase);
        }

        return false;
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private static string BuildCacheKey(string userId, string sub, string rg, string ns)
        => $"rbac:{userId}:{sub}:{rg}:{ns}";

    private static IReadOnlyList<string> ReadStringList(JsonElement element, string property)
    {
        if (!element.TryGetProperty(property, out var arr)) return [];
        var list = new List<string>();
        foreach (var item in arr.EnumerateArray())
        {
            var s = item.GetString();
            if (s is not null) list.Add(s);
        }
        return list;
    }

    // ── Internal model ────────────────────────────────────────────────────────

    private sealed record PermissionEntry(
        IReadOnlyList<string> Actions,
        IReadOnlyList<string> NotActions,
        IReadOnlyList<string> DataActions,
        IReadOnlyList<string> NotDataActions);
}
