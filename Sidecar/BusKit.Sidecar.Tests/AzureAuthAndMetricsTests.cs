using Azure.Core;
using BusKit.Sidecar.Grpc;
using BusKit.Sidecar.Services;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Identity.Client;

namespace BusKit.Sidecar.Tests;

public class AzureAuthAndMetricsTests
{
    private static readonly string[] Scopes = ["https://management.azure.com/.default"];

    // ── MsalTokenCredential ──────────────────────────────────────────────────

    [Fact]
    public async Task Credential_UsesSilentToken_AndRemembersRefreshedAccount()
    {
        var first = new FakeAccount("first");
        var second = new FakeAccount("second");
        var msal = new FakeMsal { SilentResult = new MsalToken("tok", DateTimeOffset.UtcNow.AddHours(1), second) };
        var cred = new MsalTokenCredential(msal, first, "tenant");

        var token = await cred.GetTokenAsync(new TokenRequestContext(Scopes), CancellationToken.None);
        await cred.GetTokenAsync(new TokenRequestContext(Scopes), CancellationToken.None);

        Assert.Equal("tok", token.Token);
        Assert.Equal(0, msal.InteractiveCalls);
        Assert.Equal([first, second], msal.SilentAccounts);
        Assert.All(msal.SilentTenants, t => Assert.Equal("tenant", t));
    }

    [Fact]
    public async Task Credential_FallsBackToInteractive_WhenSilentNeedsUi_WithoutAccountPrompt()
    {
        var msal = new FakeMsal
        {
            SilentThrows = true,
            InteractiveResult = new MsalToken("ui", DateTimeOffset.UtcNow.AddHours(1), new FakeAccount("a")),
        };

        var token = await new MsalTokenCredential(msal, new FakeAccount("a"))
            .GetTokenAsync(new TokenRequestContext(Scopes), CancellationToken.None);

        Assert.Equal("ui", token.Token);
        Assert.Equal(1, msal.InteractiveCalls);
        Assert.False(msal.LastSelectAccount);
    }

    [Fact]
    public void Credential_SyncGetToken_Works()
    {
        var msal = new FakeMsal { SilentResult = new MsalToken("sync", DateTimeOffset.UtcNow, new FakeAccount("a")) };

        var token = new MsalTokenCredential(msal, new FakeAccount("a"))
            .GetToken(new TokenRequestContext(Scopes), CancellationToken.None);

        Assert.Equal("sync", token.Token);
    }

    [Fact]
    public async Task SelectTenant_FallsBackToInteractive_AndBuildsTenantCredential()
    {
        var account = new FakeAccount("a");
        var msal = new FakeMsal
        {
            SilentThrows = true,
            InteractiveResult = new MsalToken("ui", DateTimeOffset.UtcNow.AddHours(1), account),
        };
        var session = new AzureSession(msal, account, new FakeCredential(), "oid");

        var result = await new MsalAzureAuthenticator().SelectTenantAsync(session, "tenant-2", CancellationToken.None);
        await result.Credential.GetTokenAsync(new TokenRequestContext(Scopes), CancellationToken.None);

        Assert.Equal("oid", result.UserObjectId);
        Assert.Equal("tenant-2", msal.LastInteractiveTenant);
        Assert.Contains("tenant-2", msal.SilentTenants);
    }

    // ── ConnectionService sign-in flows ──────────────────────────────────────

    [Fact]
    public async Task ListAzureSubscriptions_PopulatesSubscriptionsAndTenants_AndStoresCredential()
    {
        var cred = new FakeCredential();
        var service = Create(
            new FakeAuthenticator { Session = Session(cred, "oid") },
            new FakeCatalog
            {
                Subscriptions = [new("sub1", "Prod"), new("sub2", "Dev")],
                Tenants = [new("t1", "Contoso"), new("t2", null), new("", "skipped")],
            });

        var reply = await service.ListAzureSubscriptionsAsync();

        Assert.Equal(string.Empty, reply.Error);
        Assert.Equal(["sub1", "sub2"], reply.Subscriptions.Select(s => s.SubscriptionId));
        Assert.Equal(["Contoso", "t2"], reply.Tenants.Select(t => t.DisplayName));
        Assert.Same(cred, service.AzureCredential);
    }

    [Fact]
    public async Task ListAzureSubscriptions_SignInFailure_ReturnsErrorAndClearsCredential()
    {
        var service = Create(new FakeAuthenticator { SignInError = "cancelled" }, new FakeCatalog());
        service.SetSignedIn(new FakeCredential(), "old");

        var reply = await service.ListAzureSubscriptionsAsync();

        Assert.Equal("cancelled", reply.Error);
        Assert.Null(service.AzureCredential);
    }

    [Fact]
    public async Task SelectAzureTenant_AfterSignIn_SwitchesCredentialAndListsSubscriptions()
    {
        var tenantCred = new FakeCredential();
        var auth = new FakeAuthenticator
        {
            Session = Session(new FakeCredential(), "oid"),
            TenantSession = Session(tenantCred, "oid2"),
        };
        var service = Create(auth, new FakeCatalog { Subscriptions = [new("s", "S")] });
        await service.ListAzureSubscriptionsAsync();

        var reply = await service.SelectAzureTenantAsync(new SelectAzureTenantRequest { TenantId = "t9" });

        Assert.Equal(string.Empty, reply.Error);
        Assert.Equal("t9", auth.SelectedTenant);
        Assert.Same(tenantCred, service.AzureCredential);
        Assert.Single(reply.Subscriptions);
    }

    [Fact]
    public async Task ListServiceBusNamespaces_MapsNamesAndResourceGroups()
    {
        var service = Create(
            new FakeAuthenticator(),
            new FakeCatalog { Namespaces = [new("bus-a", "rg1"), new("bus-b", "rg2")] });
        service.SetSignedIn(new FakeCredential(), "oid");

        var reply = await service.ListServiceBusNamespacesAsync(
            new ListServiceBusNamespacesRequest { SubscriptionId = "sub1" });

        Assert.Equal(string.Empty, reply.Error);
        Assert.Equal(["bus-a.servicebus.windows.net", "bus-b.servicebus.windows.net"],
            reply.Namespaces.Select(n => n.FullyQualifiedNamespace));
        Assert.Equal(["rg1", "rg2"], reply.Namespaces.Select(n => n.ResourceGroup));
    }

    // ── MetricsOperations ────────────────────────────────────────────────────

    [Fact]
    public async Task Metrics_QueriesNamespaceResource_WithEntityFilter_AndMapsSamples()
    {
        var when = DateTimeOffset.FromUnixTimeSeconds(1_700_000_000);
        var query = new FakeMetricsQuery
        {
            Results =
            [
                new MetricResult("IncomingMessages",
                [
                    new MetricSample(when, 10, 1, 1),
                    new MetricSample(when, null, 2.5, 1),
                    new MetricSample(when, null, null, 7),
                    new MetricSample(default, 99, null, null),
                ]),
            ],
        };
        var ops = new MetricsOperations(new FakeCredential(), "sub", "rg", "ns", query);

        var reply = await ops.GetTopicMetricsAsync(new GetTopicMetricsRequest { TopicName = "orders", Hours = 24 });

        Assert.Equal(string.Empty, reply.Error);
        Assert.Equal("/subscriptions/sub/resourceGroups/rg/providers/Microsoft.ServiceBus/namespaces/ns", query.ResourceId);
        Assert.Equal("EntityName eq 'orders'", query.Filter);
        Assert.Equal(TimeSpan.FromMinutes(15), query.Granularity);
        Assert.InRange((query.End - query.Start).TotalHours, 23.99, 24.01);
        var series = Assert.Single(reply.Series);
        Assert.Equal([10d, 2.5, 7], series.Points.Select(p => p.Value));
        Assert.All(series.Points, p => Assert.Equal(1_700_000_000, p.TimestampUnix));
    }

    [Fact]
    public async Task QueueMetrics_ClampsHoursToOne_AndReportsQueryFailure()
    {
        var query = new FakeMetricsQuery();
        var ops = new MetricsOperations(new FakeCredential(), "sub", "rg", "ns", query);

        await ops.GetQueueMetricsAsync(new GetQueueMetricsRequest { QueueName = "q", Hours = 0 });
        Assert.Equal(TimeSpan.FromMinutes(1), query.Granularity);
        Assert.InRange((query.End - query.Start).TotalHours, 0.99, 1.01);

        query.Fail = true;
        var reply = await ops.GetQueueMetricsAsync(new GetQueueMetricsRequest { QueueName = "q", Hours = 1 });
        Assert.Equal("monitor down", reply.Error);
        Assert.Empty(reply.Series);
    }

    // ── helpers & fakes ──────────────────────────────────────────────────────

    private static AzureSession Session(TokenCredential cred, string oid)
        => new(new FakeMsal(), new FakeAccount("acc"), cred, oid);

    private static ConnectionService Create(IAzureAuthenticator auth, IAzureResourceCatalog catalog)
    {
        var engine = new PermissionEvaluationEngine(
            new MemoryCache(new MemoryCacheOptions()),
            new NoHttpFactory(),
            NullLogger<PermissionEvaluationEngine>.Instance);
        return new ConnectionService(
            engine,
            _ => throw new InvalidOperationException("unexpected"),
            (_, _) => throw new InvalidOperationException("unexpected"),
            auth, catalog);
    }

    private sealed class NoHttpFactory : IHttpClientFactory
    {
        public HttpClient CreateClient(string name) => new();
    }

    private sealed class FakeAccount(string username) : IAccount
    {
        public string Username { get; } = username;
        public string Environment => "login.microsoftonline.com";
        public AccountId HomeAccountId { get; } = new("id", "oid", "tid");
    }

    private sealed class FakeCredential : TokenCredential
    {
        public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken)
            => new("t", DateTimeOffset.UtcNow.AddHours(1));

        public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext requestContext, CancellationToken cancellationToken)
            => new(GetToken(requestContext, cancellationToken));
    }

    private sealed class FakeMsal : IMsalClient
    {
        public MsalToken? SilentResult { get; init; }
        public MsalToken? InteractiveResult { get; init; }
        public bool SilentThrows { get; init; }
        public List<IAccount> SilentAccounts { get; } = [];
        public List<string?> SilentTenants { get; } = [];
        public int InteractiveCalls { get; private set; }
        public bool LastSelectAccount { get; private set; }
        public string? LastInteractiveTenant { get; private set; }

        public Task<MsalToken> AcquireSilentAsync(
            IEnumerable<string> scopes, IAccount account, string? tenantId, CancellationToken ct)
        {
            SilentAccounts.Add(account);
            SilentTenants.Add(tenantId);
            if (SilentThrows) throw new MsalUiRequiredException("ui_required", "needs ui");
            return Task.FromResult(SilentResult!);
        }

        public Task<MsalToken> AcquireInteractiveAsync(
            IEnumerable<string> scopes, IAccount? account, string? tenantId, bool selectAccount, CancellationToken ct)
        {
            InteractiveCalls++;
            LastSelectAccount = selectAccount;
            LastInteractiveTenant = tenantId;
            return Task.FromResult(InteractiveResult!);
        }
    }

    private sealed class FakeAuthenticator : IAzureAuthenticator
    {
        public AzureSession? Session { get; init; }
        public AzureSession? TenantSession { get; init; }
        public string? SignInError { get; init; }
        public string? SelectedTenant { get; private set; }

        public Task<AzureSession> SignInAsync(CancellationToken ct)
            => SignInError != null ? throw new InvalidOperationException(SignInError) : Task.FromResult(Session!);

        public Task<AzureSession> SelectTenantAsync(AzureSession session, string tenantId, CancellationToken ct)
        {
            SelectedTenant = tenantId;
            return Task.FromResult(TenantSession!);
        }
    }

    private sealed class FakeCatalog : IAzureResourceCatalog
    {
        public SubscriptionEntry[] Subscriptions { get; init; } = [];
        public TenantEntry[] Tenants { get; init; } = [];
        public NamespaceEntry[] Namespaces { get; init; } = [];

        public IAsyncEnumerable<SubscriptionEntry> ListSubscriptionsAsync(TokenCredential credential)
            => Subscriptions.ToAsyncEnumerable();

        public IAsyncEnumerable<TenantEntry> ListTenantsAsync(TokenCredential credential)
            => Tenants.ToAsyncEnumerable();

        public IAsyncEnumerable<NamespaceEntry> ListNamespacesAsync(TokenCredential credential, string subscriptionId)
            => Namespaces.ToAsyncEnumerable();
    }

    private sealed class FakeMetricsQuery : IMetricsQuery
    {
        public IReadOnlyList<MetricResult> Results { get; init; } = [];
        public bool Fail { get; set; }
        public string? ResourceId { get; private set; }
        public string? Filter { get; private set; }
        public TimeSpan Granularity { get; private set; }
        public DateTimeOffset Start { get; private set; }
        public DateTimeOffset End { get; private set; }

        public Task<IReadOnlyList<MetricResult>> QueryAsync(
            string resourceId, IReadOnlyList<string> metricNames, string filter, TimeSpan granularity,
            DateTimeOffset start, DateTimeOffset end, CancellationToken ct)
        {
            if (Fail) throw new InvalidOperationException("monitor down");
            (ResourceId, Filter, Granularity, Start, End) = (resourceId, filter, granularity, start, end);
            return Task.FromResult(Results);
        }
    }
}
