using System.Net;
using System.Text;
using System.Text.Json;
using Azure;
using Azure.Core;
using Azure.Messaging.ServiceBus;
using Azure.Messaging.ServiceBus.Administration;
using BusKit.Sidecar.Grpc;
using BusKit.Sidecar.Services;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Logging.Abstractions;

namespace BusKit.Sidecar.Tests;

public class ConnectionServiceRbacAndWarmupTests
{
    private const string Ns = "Microsoft.ServiceBus/namespaces";

    // ── CheckRbacPermissions ─────────────────────────────────────────────────

    [Fact]
    public async Task CheckRbac_FullAccess_MapsTierCapabilitiesAndStoresNamespace()
    {
        var service = CreateSignedIn(Permissions(actions: ["*"], data: ["*"]));

        var reply = await service.CheckRbacPermissionsAsync(Request(), CancellationToken.None);

        Assert.False(reply.CheckFailed);
        Assert.Equal(string.Empty, reply.Error);
        Assert.Equal(BusKit.Sidecar.Grpc.AccessTier.FullAccess, reply.AccessTier);
        Assert.True(reply.CanBrowseEntities);
        Assert.True(reply.CanPeekFetch);
        Assert.True(reply.CanPurge);
        Assert.True(reply.CanCreateResources);
        Assert.True(reply.CanManageFilters);
        Assert.True(reply.HasDataOwnerRole);
        Assert.True(reply.HasContributorRole);
        Assert.True(reply.ExpiresAtUnixMs > reply.EvaluatedAtUnixMs);
        Assert.Equal(("sub", "rg", "ns"), (service.SubscriptionId, service.ResourceGroup, service.NamespaceName));
    }

    [Fact]
    public async Task CheckRbac_ReadOnly_ReturnsUpgradeRecommendation()
    {
        var service = CreateSignedIn(Permissions(actions:
            [$"{Ns}/queues/read", $"{Ns}/topics/read", $"{Ns}/topics/subscriptions/read"]));

        var reply = await service.CheckRbacPermissionsAsync(Request(), CancellationToken.None);

        Assert.Equal(BusKit.Sidecar.Grpc.AccessTier.ReadOnly, reply.AccessTier);
        Assert.True(reply.CanBrowseEntities);
        Assert.False(reply.CanPeekFetch);
        Assert.False(reply.HasDataOwnerRole);
        Assert.NotEmpty(reply.RecommendedRoleName);
        Assert.NotEmpty(reply.RecommendedRoleId);
        Assert.NotEqual(BusKit.Sidecar.Grpc.AccessTier.ReadOnly, reply.RecommendedTargetTier);
    }

    [Fact]
    public async Task CheckRbac_EvaluationFailure_ReportsCheckFailed()
    {
        var service = CreateSignedIn(new StubHandler(HttpStatusCode.Forbidden, "{}"));

        var reply = await service.CheckRbacPermissionsAsync(Request(), CancellationToken.None);

        Assert.True(reply.CheckFailed);
        Assert.NotEmpty(reply.Error);
        Assert.Equal(BusKit.Sidecar.Grpc.AccessTier.NoAccess, reply.AccessTier);
    }

    // ── ConnectWithAzureAD warm-up ───────────────────────────────────────────

    [Fact]
    public async Task ConnectWithAzureAD_WarmsUpAmqpWithFirstQueue()
    {
        var receiver = new FakeReceiver();
        var client = new FakeClient(receiver);
        var service = CreateAadService(client, new FakeAdmin { Queues = ["orders", "other"] });

        var reply = await service.ConnectWithAzureADAsync(Request("ns.servicebus.windows.net"));

        Assert.True(reply.Success);
        Assert.Equal("orders", client.QueueReceiver);
        Assert.Equal(1, receiver.Peeks);
        Assert.True(receiver.Disposed);
    }

    [Fact]
    public async Task ConnectWithAzureAD_WithoutQueues_WarmsUpFirstTopicSubscription()
    {
        var receiver = new FakeReceiver();
        var client = new FakeClient(receiver);
        var admin = new FakeAdmin { Topics = ["events"], Subscriptions = ["audit"] };
        var service = CreateAadService(client, admin);

        var reply = await service.ConnectWithAzureADAsync(Request("ns.servicebus.windows.net"));

        Assert.True(reply.Success);
        Assert.Equal(("events", "audit"), client.SubscriptionReceiver);
        Assert.Equal(1, receiver.Peeks);
    }

    [Fact]
    public async Task ConnectWithAzureAD_EmptyNamespace_SkipsWarmUp()
    {
        var client = new FakeClient(new FakeReceiver());

        var reply = await CreateAadService(client, new FakeAdmin()).ConnectWithAzureADAsync(Request("ns"));

        Assert.True(reply.Success);
        Assert.Null(client.QueueReceiver);
        Assert.Null(client.SubscriptionReceiver);
    }

    [Fact]
    public async Task ConnectWithAzureAD_WarmUpFailure_IsNonFatal()
    {
        var client = new FakeClient(new FakeReceiver { Fail = true });

        var reply = await CreateAadService(client, new FakeAdmin { Queues = ["q"] }).ConnectWithAzureADAsync(Request("ns"));

        Assert.True(reply.Success);
    }

    [Fact]
    public async Task ConnectWithAzureAD_AdminFailure_ReturnsError()
    {
        var client = new FakeClient(new FakeReceiver());

        var reply = await CreateAadService(client, new FakeAdmin { Fail = true }).ConnectWithAzureADAsync(Request("ns"));

        Assert.False(reply.Success);
        Assert.Equal("forbidden", reply.Error);
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    private static CheckRbacPermissionsRequest Request()
        => new() { SubscriptionId = "sub", ResourceGroup = "rg", NamespaceName = "ns" };

    private static ConnectWithAzureADRequest Request(string fqns) => new() { FullyQualifiedNamespace = fqns };

    private static StubHandler Permissions(string[]? actions = null, string[]? data = null)
        => new(HttpStatusCode.OK, JsonSerializer.Serialize(new
        {
            value = new[]
            {
                new Dictionary<string, string[]>
                {
                    ["actions"] = actions ?? [],
                    ["notActions"] = [],
                    ["dataActions"] = data ?? [],
                    ["notDataActions"] = [],
                },
            },
        }));

    private static ConnectionService CreateSignedIn(HttpMessageHandler handler)
    {
        var service = Create(handler, (_, _) => throw new InvalidOperationException("unexpected"));
        service.SetSignedIn(new FakeCredential(), "user-oid");
        return service;
    }

    private static ConnectionService CreateAadService(ServiceBusClient client, ServiceBusAdministrationClient admin)
    {
        var service = Create(new StubHandler(HttpStatusCode.OK, "{}"), (_, _) => (client, admin));
        service.SetSignedIn(new FakeCredential(), "user-oid");
        return service;
    }

    private static ConnectionService Create(
        HttpMessageHandler handler,
        Func<string, TokenCredential, (ServiceBusClient, ServiceBusAdministrationClient)> token)
    {
        var engine = new PermissionEvaluationEngine(
            new MemoryCache(new MemoryCacheOptions()),
            new StubFactory(handler),
            NullLogger<PermissionEvaluationEngine>.Instance);
        return new ConnectionService(engine, _ => throw new InvalidOperationException("unexpected"), token);
    }

    private sealed class StubFactory(HttpMessageHandler handler) : IHttpClientFactory
    {
        public HttpClient CreateClient(string name) => new(handler, disposeHandler: false);
    }

    private sealed class StubHandler(HttpStatusCode status, string body) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
            => Task.FromResult(new HttpResponseMessage(status)
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json"),
            });
    }

    private sealed class FakeCredential : TokenCredential
    {
        public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken)
            => new("t", DateTimeOffset.UtcNow.AddHours(1));

        public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext requestContext, CancellationToken cancellationToken)
            => new(GetToken(requestContext, cancellationToken));
    }

    private sealed class FakeClient(ServiceBusReceiver receiver) : ServiceBusClient
    {
        public string? QueueReceiver { get; private set; }
        public (string, string)? SubscriptionReceiver { get; private set; }

        public override ServiceBusReceiver CreateReceiver(string queueName, ServiceBusReceiverOptions options)
        {
            QueueReceiver = queueName;
            return receiver;
        }

        public override ServiceBusReceiver CreateReceiver(
            string topicName, string subscriptionName, ServiceBusReceiverOptions options)
        {
            SubscriptionReceiver = (topicName, subscriptionName);
            return receiver;
        }

        public override ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    private sealed class FakeReceiver : ServiceBusReceiver
    {
        public bool Fail { get; init; }
        public int Peeks { get; private set; }
        public bool Disposed { get; private set; }

        public override Task<IReadOnlyList<ServiceBusReceivedMessage>> PeekMessagesAsync(
            int maxMessages, long? fromSequenceNumber = null, CancellationToken cancellationToken = default)
        {
            Peeks++;
            if (Fail) throw new UnauthorizedAccessException("no peek");
            return Task.FromResult<IReadOnlyList<ServiceBusReceivedMessage>>([]);
        }

        public override ValueTask DisposeAsync()
        {
            Disposed = true;
            return ValueTask.CompletedTask;
        }
    }

    private sealed class FakeAdmin : ServiceBusAdministrationClient
    {
        public bool Fail { get; init; }
        public string[] Queues { get; init; } = [];
        public string[] Topics { get; init; } = [];
        public string[] Subscriptions { get; init; } = [];

        public override AsyncPageable<QueueProperties> GetQueuesAsync(CancellationToken cancellationToken = default)
        {
            if (Fail) throw new UnauthorizedAccessException("forbidden");
            return Pageable(Queues.Select(q => ServiceBusModelFactory.QueueProperties(
                name: q, lockDuration: TimeSpan.FromMinutes(1), maxSizeInMegabytes: 1024,
                defaultMessageTimeToLive: TimeSpan.FromDays(14), autoDeleteOnIdle: TimeSpan.FromDays(14),
                maxDeliveryCount: 10, duplicateDetectionHistoryTimeWindow: TimeSpan.FromMinutes(10), userMetadata: "")));
        }

        public override AsyncPageable<TopicProperties> GetTopicsAsync(CancellationToken cancellationToken = default)
            => Pageable(Topics.Select(t => ServiceBusModelFactory.TopicProperties(
                name: t, maxSizeInMegabytes: 1024, defaultMessageTimeToLive: TimeSpan.FromDays(14),
                autoDeleteOnIdle: TimeSpan.FromDays(14), duplicateDetectionHistoryTimeWindow: TimeSpan.FromMinutes(10))));

        public override AsyncPageable<SubscriptionProperties> GetSubscriptionsAsync(
            string topicName, CancellationToken cancellationToken = default)
            => Pageable(Subscriptions.Select(s => ServiceBusModelFactory.SubscriptionProperties(
                topicName: topicName, subscriptionName: s, lockDuration: TimeSpan.FromMinutes(1),
                defaultMessageTimeToLive: TimeSpan.FromDays(1), maxDeliveryCount: 10,
                autoDeleteOnIdle: TimeSpan.FromDays(1), userMetadata: "")));

        private static AsyncPageable<T> Pageable<T>(IEnumerable<T> items) where T : notnull
            => AsyncPageable<T>.FromPages([Page<T>.FromValues(items.ToList(), null, null!)]);
    }
}
