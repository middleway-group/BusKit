using Azure;
using Azure.Core;
using Azure.Messaging.ServiceBus;
using Azure.Messaging.ServiceBus.Administration;
using BusKit.Sidecar.Grpc;
using BusKit.Sidecar.Services;
using Grpc.Core;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Logging.Abstractions;

namespace BusKit.Sidecar.Tests;

public class BusKitGrpcServiceTests
{
    [Fact]
    public async Task WhenNotConnected_MessageCallsReturnNotConnectedReplies()
    {
        var (svc, _) = Create();
        var ctx = new FakeCallContext();

        Assert.Empty((await svc.PeekMessages(new PeekMessagesRequest(), ctx)).Messages);
        Assert.False((await svc.SendMessage(new SendMessageRequest { QueueName = "q" }, ctx)).Success);
        Assert.False((await svc.SendMessageExtended(new SendMessageExtendedRequest(), ctx)).Success);
        Assert.Equal("Not connected", (await svc.DeleteMessage(new DeleteMessageRequest(), ctx)).Error);
        Assert.Equal("Not connected", (await svc.DeleteMessages(new DeleteMessagesRequest(), ctx)).Error);
        Assert.NotNull(await svc.PurgeMessages(new PurgeMessagesRequest(), ctx));
    }

    [Fact]
    public async Task WhenNotConnected_EntityAndPropertyCallsAreRoutedToOperations()
    {
        var (svc, _) = Create();
        var ctx = new FakeCallContext();

        Assert.Empty((await svc.ListQueues(new ListQueuesRequest(), ctx)).Queues);
        Assert.Empty((await svc.ListTopics(new ListTopicsRequest(), ctx)).Topics);
        Assert.NotEmpty((await svc.CreateQueue(new CreateQueueRequest { QueueName = "q" }, ctx)).Error);
        Assert.NotEmpty((await svc.DeleteTopic(new DeleteTopicRequest { TopicName = "t" }, ctx)).Error);
        Assert.NotEmpty((await svc.CreateSubscription(new CreateSubscriptionRequest(), ctx)).Error);
        Assert.NotEmpty((await svc.AddRule(new AddRuleRequest(), ctx)).Error);
        Assert.Null((await svc.GetTopicProperties(new GetTopicPropertiesRequest { Name = "t" }, ctx)).Properties);
        Assert.Null((await svc.GetSubscriptionProperties(new GetSubscriptionPropertiesRequest(), ctx)).Properties);
        Assert.NotEmpty((await svc.UpdateSubscriptionTtl(new UpdateSubscriptionTtlRequest(), ctx)).Error);
    }

    [Fact]
    public async Task Metrics_WithoutAzureAdConnection_ReturnError()
    {
        var (svc, _) = Create();
        var ctx = new FakeCallContext();

        Assert.NotEmpty((await svc.GetTopicMetrics(new GetTopicMetricsRequest { TopicName = "t", Hours = 1 }, ctx)).Error);
        Assert.NotEmpty((await svc.GetQueueMetrics(new GetQueueMetricsRequest { QueueName = "q", Hours = 1 }, ctx)).Error);
    }

    [Fact]
    public async Task ConnectionCalls_DelegateToConnectionService()
    {
        var (svc, _) = Create(connectionString: _ => (new FakeClient(), new FakeAdmin()));
        var ctx = new FakeCallContext();

        Assert.Contains("Not signed in", (await svc.SelectAzureTenant(new SelectAzureTenantRequest { TenantId = "t" }, ctx)).Error);
        Assert.Contains("Not signed in",
            (await svc.ListServiceBusNamespaces(new ListServiceBusNamespacesRequest { SubscriptionId = "s" }, ctx)).Error);
        Assert.True((await svc.CheckRbacPermissions(new CheckRbacPermissionsRequest(), ctx)).CheckFailed);
        Assert.Contains("Not signed in",
            (await svc.ConnectWithAzureAD(new ConnectWithAzureADRequest { FullyQualifiedNamespace = "ns" }, ctx)).Error);

        Assert.True((await svc.Connect(new ConnectRequest { ConnectionString = "x" }, ctx)).Success);
        Assert.True((await svc.Disconnect(new DisconnectRequest(), ctx)).Success);
    }

    [Fact]
    public async Task WhenConnected_ListQueuesUsesAdminClient()
    {
        var (svc, _) = Create(connectionString: _ => (new FakeClient(), new FakeAdmin()));
        var ctx = new FakeCallContext();
        await svc.Connect(new ConnectRequest { ConnectionString = "x" }, ctx);

        var before = FakeAdmin.QueueListCalls;

        var reply = await svc.ListQueues(new ListQueuesRequest(), ctx);

        Assert.Empty(reply.Queues);
        Assert.Equal(before + 1, FakeAdmin.QueueListCalls);
    }

    [Fact]
    public async Task SendMessage_SendsBodyContentTypeAndProperties()
    {
        var sender = new FakeSender();
        var (svc, _) = Create(connectionString: _ => (new FakeClient { Sender = sender }, new FakeAdmin()));
        var ctx = new FakeCallContext();
        await svc.Connect(new ConnectRequest { ConnectionString = "x" }, ctx);
        var request = new SendMessageRequest { QueueName = "q", Body = "hello", ContentType = "text/plain" };
        request.Properties["k"] = "v";

        var reply = await svc.SendMessage(request, ctx);

        Assert.True(reply.Success);
        var sent = Assert.Single(sender.Sent);
        Assert.Equal("hello", sent.Body.ToString());
        Assert.Equal("text/plain", sent.ContentType);
        Assert.Equal("v", sent.ApplicationProperties["k"]);
    }

    [Fact]
    public async Task SendMessage_ReturnsError_WhenSenderFails()
    {
        var sender = new FakeSender { Fail = true };
        var (svc, _) = Create(connectionString: _ => (new FakeClient { Sender = sender }, new FakeAdmin()));
        var ctx = new FakeCallContext();
        await svc.Connect(new ConnectRequest { ConnectionString = "x" }, ctx);

        var reply = await svc.SendMessage(new SendMessageRequest { QueueName = "q", Body = "b" }, ctx);

        Assert.False(reply.Success);
        Assert.Equal("boom", reply.Error);
    }

    [Fact]
    public async Task SubscribeMessages_WhenNotConnected_ReturnsImmediately()
    {
        var (svc, _) = Create();

        await svc.SubscribeMessages(new SubscribeRequest { QueueName = "q" }, new FakeStream(), new FakeCallContext());
    }

    [Fact]
    public async Task SubscribeMessages_StreamsReceivedMessages_UntilCancelled_ThenStopsProcessor()
    {
        var processor = new FakeProcessor();
        var (svc, _) = Create(connectionString: _ => (new FakeClient(), new FakeAdmin()), processor: processor);
        await svc.Connect(new ConnectRequest { ConnectionString = "x" }, new FakeCallContext());
        var stream = new FakeStream();
        using var cts = new CancellationTokenSource();

        var call = svc.SubscribeMessages(new SubscribeRequest { QueueName = "q" }, stream, new FakeCallContext(cts.Token));
        await processor.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await processor.RaiseMessage(new ProcessedMessage("id1", "body", "text/plain", 42));
        await processor.RaiseError(new InvalidOperationException("ignored"));
        cts.Cancel();
        await call.WaitAsync(TimeSpan.FromSeconds(5));

        var written = Assert.Single(stream.Written);
        Assert.Equal("id1", written.MessageId);
        Assert.Equal("body", written.Body);
        Assert.Equal("text/plain", written.ContentType);
        Assert.Equal(42, written.EnqueuedTimeUnix);
        Assert.Equal("q", processor.QueueName);
        Assert.True(processor.Stopped);
        Assert.True(processor.Disposed);
    }

    private static (BusKitGrpcService, ConnectionService) Create(
        Func<string, (ServiceBusClient, ServiceBusAdministrationClient)>? connectionString = null,
        FakeProcessor? processor = null)
    {
        var engine = new PermissionEvaluationEngine(
            new MemoryCache(new MemoryCacheOptions()),
            new NoHttpFactory(),
            NullLogger<PermissionEvaluationEngine>.Instance);
        var connection = new ConnectionService(
            engine,
            connectionString ?? (_ => throw new InvalidOperationException("unexpected")),
            (_, _) => throw new InvalidOperationException("unexpected"));
        var service = processor == null
            ? new BusKitGrpcService(connection)
            : new BusKitGrpcService(connection, (_, queue) => { processor.QueueName = queue; return processor; });
        return (service, connection);
    }

    // ── fakes ────────────────────────────────────────────────────────────────

    private sealed class FakeCallContext(CancellationToken token = default) : ServerCallContext
    {
        protected override string MethodCore => "test";
        protected override string HostCore => "localhost";
        protected override string PeerCore => "peer";
        protected override DateTime DeadlineCore => DateTime.MaxValue;
        protected override Metadata RequestHeadersCore => [];
        protected override CancellationToken CancellationTokenCore => token;
        protected override Metadata ResponseTrailersCore => [];
        protected override Status StatusCore { get; set; }
        protected override WriteOptions? WriteOptionsCore { get; set; }
        protected override AuthContext AuthContextCore => new(null, new Dictionary<string, List<AuthProperty>>());

        protected override ContextPropagationToken CreatePropagationTokenCore(ContextPropagationOptions? options)
            => throw new NotSupportedException();

        protected override Task WriteResponseHeadersAsyncCore(Metadata responseHeaders) => Task.CompletedTask;
    }

    private sealed class FakeStream : IServerStreamWriter<BusMessage>
    {
        public List<BusMessage> Written { get; } = [];
        public WriteOptions? WriteOptions { get; set; }

        public Task WriteAsync(BusMessage message)
        {
            Written.Add(message);
            return Task.CompletedTask;
        }
    }

    private sealed class FakeProcessor : IMessageProcessor
    {
        public TaskCompletionSource Started { get; } = new();
        public string? QueueName { get; set; }
        public bool Stopped { get; private set; }
        public bool Disposed { get; private set; }

        public event Func<ProcessedMessage, Task>? MessageReceived;
        public event Func<Exception, Task>? ErrorOccurred;

        public Task RaiseMessage(ProcessedMessage m) => MessageReceived!(m);
        public Task RaiseError(Exception e) => ErrorOccurred!(e);

        public Task StartAsync()
        {
            Started.SetResult();
            return Task.CompletedTask;
        }

        public Task StopAsync()
        {
            Stopped = true;
            return Task.CompletedTask;
        }

        public ValueTask DisposeAsync()
        {
            Disposed = true;
            return ValueTask.CompletedTask;
        }
    }

    private sealed class NoHttpFactory : IHttpClientFactory
    {
        public HttpClient CreateClient(string name) => new();
    }

    private sealed class FakeClient : ServiceBusClient
    {
        public ServiceBusSender? Sender { get; init; }

        public override ServiceBusSender CreateSender(string queueOrTopicName) => Sender!;
        public override ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    private sealed class FakeSender : ServiceBusSender
    {
        public List<ServiceBusMessage> Sent { get; } = [];
        public bool Fail { get; init; }

        public override Task SendMessageAsync(ServiceBusMessage message, CancellationToken cancellationToken = default)
        {
            if (Fail) throw new InvalidOperationException("boom");
            Sent.Add(message);
            return Task.CompletedTask;
        }

        public override ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    private sealed class FakeAdmin : ServiceBusAdministrationClient
    {
        public static int QueueListCalls;

        public override AsyncPageable<QueueProperties> GetQueuesAsync(CancellationToken cancellationToken = default)
        {
            Interlocked.Increment(ref QueueListCalls);
            return AsyncPageable<QueueProperties>.FromPages([Page<QueueProperties>.FromValues([], null, null!)]);
        }

        public override AsyncPageable<QueueRuntimeProperties> GetQueuesRuntimePropertiesAsync(
            CancellationToken cancellationToken = default)
            => AsyncPageable<QueueRuntimeProperties>.FromPages([Page<QueueRuntimeProperties>.FromValues([], null, null!)]);

        public override AsyncPageable<TopicProperties> GetTopicsAsync(CancellationToken cancellationToken = default)
            => AsyncPageable<TopicProperties>.FromPages([Page<TopicProperties>.FromValues([], null, null!)]);
    }
}
