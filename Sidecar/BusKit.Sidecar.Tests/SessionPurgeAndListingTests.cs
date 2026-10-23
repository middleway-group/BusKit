using Azure;
using Azure.Messaging.ServiceBus;
using Azure.Messaging.ServiceBus.Administration;
using BusKit.Sidecar.Grpc;
using BusKit.Sidecar.Services;

namespace BusKit.Sidecar.Tests;

public class SessionPurgeAndListingTests
{
    // ── Session-enabled purge ────────────────────────────────────────────────

    [Fact]
    public async Task Purge_SessionEnabledQueue_DrainsAllSessions()
    {
        var client = new SessionClient(
            new SessionReceiver(3, 2),
            new SessionReceiver(4));
        var admin = new FakeAdmin { Queue = Queue(requiresSession: true) };

        var reply = await new MessageOperations(client, admin)
            .PurgeMessagesAsync(new PurgeMessagesRequest { QueueName = "q" });

        Assert.Equal(9, reply.PurgedCount);
        Assert.Equal(3, client.AcceptCalls); // two sessions, then the timeout that ends the loop
    }

    [Fact]
    public async Task Purge_SessionEnabledSubscription_UsesTopicAndSubscription()
    {
        var client = new SessionClient(new SessionReceiver(2));
        var admin = new FakeAdmin { RequiresSessionSubscription = true };

        var reply = await new MessageOperations(client, admin)
            .PurgeMessagesAsync(new PurgeMessagesRequest { TopicName = "t", SubscriptionName = "s" });

        Assert.Equal(2, reply.PurgedCount);
        Assert.Equal("t/s", client.LastEntity);
    }

    [Fact]
    public async Task Purge_DeadLetterOfSessionQueue_DoesNotUseSessions()
    {
        var client = new SessionClient();
        var admin = new FakeAdmin { Queue = Queue(requiresSession: true) };

        var reply = await new MessageOperations(client, admin)
            .PurgeMessagesAsync(new PurgeMessagesRequest { QueueName = "q", DeadLetter = true });

        Assert.Equal(0, client.AcceptCalls);
        Assert.Equal(0, reply.PurgedCount);
        Assert.Equal(SubQueue.DeadLetter, client.PlainOptions?.SubQueue);
    }

    // ── Listings ─────────────────────────────────────────────────────────────

    [Fact]
    public async Task ListQueues_CombinesRuntimeCountsWithStatus()
    {
        var admin = new FakeAdmin
        {
            Queues = [Queue(name: "a", status: EntityStatus.Disabled)],
            QueueRuntimes =
            [
                ServiceBusModelFactory.QueueRuntimeProperties("a", activeMessageCount: 5, deadLetterMessageCount: 1),
                ServiceBusModelFactory.QueueRuntimeProperties("b", activeMessageCount: 2, deadLetterMessageCount: 0),
            ],
        };

        var reply = await new EntityOperations(admin).ListQueuesAsync(new ListQueuesRequest());

        Assert.Equal(2, reply.Queues.Count);
        Assert.Equal(("a", 5, 1, "Disabled"),
            (reply.Queues[0].Name, reply.Queues[0].MessageCount, reply.Queues[0].DeadLetterCount, reply.Queues[0].Status));
        Assert.Equal("Active", reply.Queues[1].Status); // no matching properties entry → default
    }

    [Fact]
    public async Task ListSubscriptions_MapsRuntimeCounts()
    {
        var admin = new FakeAdmin
        {
            Subscriptions =
            [
                ServiceBusModelFactory.SubscriptionRuntimeProperties("t", "s1", activeMessageCount: 7, deadLetterMessageCount: 3),
            ],
        };

        var reply = await new EntityOperations(admin)
            .ListSubscriptionsAsync(new ListSubscriptionsRequest { TopicName = "t" });

        var s = Assert.Single(reply.Subscriptions);
        Assert.Equal(("s1", 7, 3), (s.Name, s.ActiveMessageCount, s.DeadLetterCount));
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    private static QueueProperties Queue(string name = "q", bool requiresSession = false, EntityStatus? status = null)
        => ServiceBusModelFactory.QueueProperties(
            name: name, lockDuration: TimeSpan.FromMinutes(1), maxSizeInMegabytes: 1024,
            requiresSession: requiresSession,
            defaultMessageTimeToLive: TimeSpan.FromDays(14), autoDeleteOnIdle: TimeSpan.FromDays(14),
            maxDeliveryCount: 10, duplicateDetectionHistoryTimeWindow: TimeSpan.FromMinutes(10),
            userMetadata: "", status: status ?? EntityStatus.Active);

    private static ServiceBusReceivedMessage Msg(long seq) => ServiceBusModelFactory.ServiceBusReceivedMessage(
        body: BinaryData.FromString("{}"), messageId: $"m{seq}", sequenceNumber: seq);

    private sealed class SessionReceiver(params int[] batchSizes) : ServiceBusSessionReceiver
    {
        private readonly Queue<int> _batches = new(batchSizes);

        public override Task<IReadOnlyList<ServiceBusReceivedMessage>> ReceiveMessagesAsync(
            int maxMessages, TimeSpan? maxWaitTime = null, CancellationToken cancellationToken = default)
        {
            var n = _batches.Count > 0 ? _batches.Dequeue() : 0;
            IReadOnlyList<ServiceBusReceivedMessage> batch = Enumerable.Range(0, n).Select(i => Msg(i)).ToList();
            return Task.FromResult(batch);
        }

        public override ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    private sealed class SessionClient(params ServiceBusSessionReceiver[] sessions) : ServiceBusClient
    {
        private readonly Queue<ServiceBusSessionReceiver> _sessions = new(sessions);
        public int AcceptCalls { get; private set; }
        public string? LastEntity { get; private set; }
        public ServiceBusReceiverOptions? PlainOptions { get; private set; }

        public override Task<ServiceBusSessionReceiver> AcceptNextSessionAsync(
            string queueName, ServiceBusSessionReceiverOptions? options = null, CancellationToken cancellationToken = default)
            => Next(queueName);

        public override Task<ServiceBusSessionReceiver> AcceptNextSessionAsync(
            string topicName, string subscriptionName, ServiceBusSessionReceiverOptions? options = null,
            CancellationToken cancellationToken = default)
            => Next($"{topicName}/{subscriptionName}");

        private Task<ServiceBusSessionReceiver> Next(string entity)
        {
            AcceptCalls++;
            LastEntity = entity;
            if (_sessions.Count == 0)
                throw new ServiceBusException("no sessions", ServiceBusFailureReason.ServiceTimeout);
            return Task.FromResult(_sessions.Dequeue());
        }

        public override ServiceBusReceiver CreateReceiver(string queueName, ServiceBusReceiverOptions options)
        {
            PlainOptions = options;
            return new EmptyReceiver();
        }
    }

    private sealed class EmptyReceiver : ServiceBusReceiver
    {
        public override Task<IReadOnlyList<ServiceBusReceivedMessage>> ReceiveMessagesAsync(
            int maxMessages, TimeSpan? maxWaitTime = null, CancellationToken cancellationToken = default)
            => Task.FromResult<IReadOnlyList<ServiceBusReceivedMessage>>([]);

        public override ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    private sealed class FakeAdmin : ServiceBusAdministrationClient
    {
        public QueueProperties? Queue { get; init; }
        public bool RequiresSessionSubscription { get; init; }
        public List<QueueProperties> Queues { get; init; } = [];
        public List<QueueRuntimeProperties> QueueRuntimes { get; init; } = [];
        public List<SubscriptionRuntimeProperties> Subscriptions { get; init; } = [];

        public override Task<Response<QueueProperties>> GetQueueAsync(
            string name, CancellationToken cancellationToken = default)
            => Task.FromResult(Response.FromValue(Queue!, null!));

        public override Task<Response<SubscriptionProperties>> GetSubscriptionAsync(
            string topicName, string subscriptionName, CancellationToken cancellationToken = default)
            => Task.FromResult(Response.FromValue(
                ServiceBusModelFactory.SubscriptionProperties(
                    topicName, subscriptionName, TimeSpan.FromMinutes(1), RequiresSessionSubscription,
                    TimeSpan.FromDays(1), TimeSpan.FromDays(1), false, 10, true,
                    EntityStatus.Active, null, null, ""), null!));

        public override AsyncPageable<QueueProperties> GetQueuesAsync(CancellationToken cancellationToken = default)
            => AsyncPageable<QueueProperties>.FromPages([Page<QueueProperties>.FromValues(Queues, null, null!)]);

        public override AsyncPageable<QueueRuntimeProperties> GetQueuesRuntimePropertiesAsync(
            CancellationToken cancellationToken = default)
            => AsyncPageable<QueueRuntimeProperties>.FromPages(
                [Page<QueueRuntimeProperties>.FromValues(QueueRuntimes, null, null!)]);

        public override AsyncPageable<SubscriptionRuntimeProperties> GetSubscriptionsRuntimePropertiesAsync(
            string topicName, CancellationToken cancellationToken = default)
            => AsyncPageable<SubscriptionRuntimeProperties>.FromPages(
                [Page<SubscriptionRuntimeProperties>.FromValues(Subscriptions, null, null!)]);
    }
}
