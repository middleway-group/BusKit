using System.Net;
using System.Text;
using System.Text.Json;
using BusKit.Sidecar.Models;
using BusKit.Sidecar.Services;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Logging.Abstractions;

namespace BusKit.Sidecar.Tests;

public class PermissionEvaluationEngineTests
{
    private const string Sb = "Microsoft.ServiceBus/namespaces";

    private static readonly string[] Read =
    [
        $"{Sb}/queues/read", $"{Sb}/topics/read", $"{Sb}/topics/subscriptions/read",
    ];

    private static readonly string[] Write =
    [
        $"{Sb}/queues/write", $"{Sb}/topics/write",
        $"{Sb}/topics/subscriptions/write", $"{Sb}/topics/subscriptions/rules/write",
    ];

    private const string Receive = $"{Sb}/messages/receive/action";
    private const string Send = $"{Sb}/messages/send/action";

    [Fact]
    public async Task NoPermissions_IsNoAccess_WithReaderRecommendation()
    {
        var r = await Evaluate(Entry());

        Assert.Equal(AccessTier.NoAccess, r.Tier);
        Assert.False(r.IsPartialAccess);
        Assert.False(r.EvaluationFailed);
        Assert.Equal(CapabilityMap.None, r.Capabilities);
        Assert.Equal("Reader", r.UpgradeRecommendation?.RoleName);
        Assert.Equal(AccessTier.ReadOnly, r.UpgradeRecommendation?.TargetTier);
    }

    [Fact]
    public async Task ReadOnly_Tier()
    {
        var r = await Evaluate(Entry(actions: Read));

        Assert.Equal(AccessTier.ReadOnly, r.Tier);
        Assert.Equal("Read-Only Observer", r.TierLabel);
        Assert.True(r.Capabilities.BrowseEntities);
        Assert.False(r.Capabilities.PeekFetch);
    }

    [Fact]
    public async Task MessageReader_Tier()
    {
        var r = await Evaluate(Entry(actions: Read, data: [Receive]));

        Assert.Equal(AccessTier.MessageReader, r.Tier);
        Assert.True(r.Capabilities.PeekFetch);
        Assert.False(r.Capabilities.Purge);
        Assert.Equal("Azure Service Bus Data Sender", r.UpgradeRecommendation?.RoleName);
    }

    [Fact]
    public async Task MessageOperator_Tier_CanPurgeAndResubmit()
    {
        var r = await Evaluate(Entry(actions: Read, data: [Receive, Send]));

        Assert.Equal(AccessTier.MessageOperator, r.Tier);
        Assert.True(r.Capabilities.Purge);
        Assert.True(r.Capabilities.ResubmitDlq);
        Assert.False(r.Capabilities.CreateResources);
    }

    [Fact]
    public async Task FullAccess_Tier_ViaWildcards()
    {
        var r = await Evaluate(Entry(actions: ["*"], data: ["*"]));

        Assert.Equal(AccessTier.FullAccess, r.Tier);
        Assert.False(r.IsPartialAccess);
        Assert.Equal(CapabilityMap.All, r.Capabilities);
        Assert.Null(r.UpgradeRecommendation);
    }

    [Fact]
    public async Task PrefixWildcard_GrantsMatchingPermissions()
    {
        var r = await Evaluate(Entry(actions: [$"{Sb}/*"], data: [$"{Sb}/messages/*"]));

        Assert.Equal(AccessTier.FullAccess, r.Tier);
    }

    [Fact]
    public async Task Matching_IsCaseInsensitive()
    {
        var r = await Evaluate(Entry(actions: Read.Select(a => a.ToUpperInvariant()).ToArray()));

        Assert.Equal(AccessTier.ReadOnly, r.Tier);
    }

    [Fact]
    public async Task NotActions_RemoveGrant()
    {
        var r = await Evaluate(Entry(
            actions: ["*"],
            notActions: [$"{Sb}/queues/read"],
            data: [Receive, Send]));

        Assert.True(r.IsPartialAccess);
        Assert.False(r.Capabilities.BrowseEntities);
    }

    [Fact]
    public async Task NotDataActions_RemoveSend()
    {
        var r = await Evaluate(Entry(actions: Read, data: ["*"], notData: [Send]));

        Assert.Equal(AccessTier.MessageReader, r.Tier);
        Assert.False(r.IsPartialAccess);
    }

    [Fact]
    public async Task PermissionsAreUnionedAcrossEntries()
    {
        var r = await Evaluate(Entry(actions: Read), Entry(data: [Receive]));

        Assert.Equal(AccessTier.MessageReader, r.Tier);
    }

    [Fact]
    public async Task DataPermissionsWithoutRead_IsPartialNoAccess()
    {
        var r = await Evaluate(Entry(data: [Receive, Send]));

        Assert.Equal(AccessTier.NoAccess, r.Tier);
        Assert.True(r.IsPartialAccess);
        Assert.Equal("No Access (Partial)", r.TierLabel);
    }

    [Fact]
    public async Task PartialRead_WithReceive_IsPartialMessageReader()
    {
        var r = await Evaluate(Entry(actions: [Read[0]], data: [Receive]));

        Assert.Equal(AccessTier.MessageReader, r.Tier);
        Assert.True(r.IsPartialAccess);
        Assert.Equal("Message Reader (Partial)", r.TierLabel);
    }

    [Fact]
    public async Task ReadWithSomeWrites_IsPartial()
    {
        var r = await Evaluate(Entry(actions: [.. Read, Write[0]]));

        Assert.Equal(AccessTier.ReadOnly, r.Tier);
        Assert.True(r.IsPartialAccess);
    }

    [Fact]
    public async Task ManageFilters_RequiresRulesWrite()
    {
        var r = await Evaluate(Entry(actions: [.. Read, Write[3]]));

        Assert.True(r.Capabilities.ManageFilters);
        Assert.False(r.Capabilities.CreateResources);
    }

    [Fact]
    public async Task MissingValueProperty_IsNoAccess()
    {
        var r = await Evaluate("{}");

        Assert.Equal(AccessTier.NoAccess, r.Tier);
        Assert.False(r.EvaluationFailed);
    }

    [Fact]
    public async Task HttpError_ReturnsFailedResult()
    {
        var handler = new StubHandler(HttpStatusCode.Forbidden, "{}");
        var r = await CreateEngine(handler).EvaluateAsync("sub", "rg", "ns", "user", "token");

        Assert.True(r.EvaluationFailed);
        Assert.Equal(AccessTier.NoAccess, r.Tier);
        Assert.False(string.IsNullOrEmpty(r.ErrorMessage));
        Assert.True(r.ExpiresAt - r.EvaluatedAt <= TimeSpan.FromMinutes(1));
    }

    [Fact]
    public async Task Request_UsesBearerTokenAndExpectedUrl()
    {
        var handler = new StubHandler(HttpStatusCode.OK, Body(Entry(actions: Read)));
        await CreateEngine(handler).EvaluateAsync("sub1", "rg1", "ns1", "user", "tok");

        var req = Assert.Single(handler.Requests);
        Assert.Equal("Bearer", req.Headers.Authorization?.Scheme);
        Assert.Equal("tok", req.Headers.Authorization?.Parameter);
        Assert.Equal(
            "https://management.azure.com/subscriptions/sub1/resourceGroups/rg1/providers/" +
            "Microsoft.ServiceBus/namespaces/ns1/providers/Microsoft.Authorization/permissions?api-version=2022-04-01",
            req.RequestUri!.ToString());
    }

    [Fact]
    public async Task UsGovernmentCloud_UsesGovEndpoint()
    {
        var handler = new StubHandler(HttpStatusCode.OK, Body(Entry()));
        await CreateEngine(handler, cloud: "AzureUSGovernment").EvaluateAsync("s", "r", "n", "u", "t");

        Assert.Equal("management.usgovcloudapi.net", handler.Requests[0].RequestUri!.Host);
    }

    [Fact]
    public async Task UnknownCloud_FallsBackToPublic()
    {
        var handler = new StubHandler(HttpStatusCode.OK, Body(Entry()));
        await CreateEngine(handler, cloud: "Nope").EvaluateAsync("s", "r", "n", "u", "t");

        Assert.Equal("management.azure.com", handler.Requests[0].RequestUri!.Host);
    }

    [Fact]
    public async Task Result_IsCached_UntilInvalidated()
    {
        var handler = new StubHandler(HttpStatusCode.OK, Body(Entry(actions: Read)));
        var engine = CreateEngine(handler);

        await engine.EvaluateAsync("s", "r", "n", "u", "t");
        await engine.EvaluateAsync("s", "r", "n", "u", "t");
        Assert.Single(handler.Requests);

        await engine.EvaluateAsync("s", "r", "n", "other-user", "t");
        Assert.Equal(2, handler.Requests.Count);

        engine.InvalidateCache("u", "s", "r", "n");
        await engine.EvaluateAsync("s", "r", "n", "u", "t");
        Assert.Equal(3, handler.Requests.Count);
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    private static Dictionary<string, string[]> Entry(
        string[]? actions = null, string[]? notActions = null,
        string[]? data = null, string[]? notData = null) => new()
    {
        ["actions"] = actions ?? [],
        ["notActions"] = notActions ?? [],
        ["dataActions"] = data ?? [],
        ["notDataActions"] = notData ?? [],
    };

    private static string Body(params Dictionary<string, string[]>[] entries)
        => JsonSerializer.Serialize(new { value = entries });

    private static Task<PermissionEvaluationResult> Evaluate(params Dictionary<string, string[]>[] entries)
        => Evaluate(Body(entries));

    private static Task<PermissionEvaluationResult> Evaluate(string json)
        => CreateEngine(new StubHandler(HttpStatusCode.OK, json))
            .EvaluateAsync("sub", "rg", "ns", "user", "token");

    private static PermissionEvaluationEngine CreateEngine(StubHandler handler, string cloud = "AzurePublicCloud")
        => new(new MemoryCache(new MemoryCacheOptions()),
               new StubFactory(handler),
               NullLogger<PermissionEvaluationEngine>.Instance,
               cloudEnvironment: cloud);

    private sealed class StubFactory(HttpMessageHandler handler) : IHttpClientFactory
    {
        public HttpClient CreateClient(string name) => new(handler, disposeHandler: false);
    }

    private sealed class StubHandler(HttpStatusCode status, string body) : HttpMessageHandler
    {
        public List<HttpRequestMessage> Requests { get; } = [];

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            Requests.Add(request);
            return Task.FromResult(new HttpResponseMessage(status)
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json"),
            });
        }
    }
}
