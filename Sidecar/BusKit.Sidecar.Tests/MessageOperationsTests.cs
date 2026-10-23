using Azure.Messaging.ServiceBus;
using BusKit.Sidecar.Grpc;
using BusKit.Sidecar.Services;

namespace BusKit.Sidecar.Tests;

public class MessageOperationsTests
{
    // ── Peek ─────────────────────────────────────────────────────────────────

    [Fact]
    public async Task Peek_PaginatesInPagesOf250_AndMapsFields()
    {
        var receiver = new FakeReceiver { Stored = Enumerable.Range(1, 600).Select(i => Msg(i)).ToList() };
        var ops = Ops(receiver);

        var reply = await ops.PeekMessagesAsync(new PeekMessagesRequest { QueueName = "q", MaxMessages = 600 });

        Assert.Equal(600, reply.Messages.Count);
        Assert.Equal(new[] { 250, 250, 100 }, receiver.PeekBatchSizes);
        Assert.Equal(new long[] { 0, 251, 501 }, receiver.PeekFromSequence);
        Assert.Equal("m1", reply.Messages[0].MessageId);
        Assert.Equal("v1", reply.Messages[0].Properties["k"]);
    }

    [Fact]
    public async Task Peek_DefaultsTo20Messages_AndStopsWhenEmpty()
    {
        var receiver = new FakeReceiver { Stored = Enumerable.Range(1, 5).Select(i => Msg(i)).ToList() };

        var reply = await Ops(receiver).PeekMessagesAsync(new PeekMessagesRequest { QueueName = "q" });

        Assert.Equal(5, reply.Messages.Count);
        Assert.Equal(new[] { 20, 15 }, receiver.PeekBatchSizes);
    }

    [Fact]
    public async Task Peek_Subscription_UsesDeadLetterSubQueue()
    {
        var receiver = new FakeReceiver();
        var client = new FakeClient(receiver);

        await new MessageOperations(client, null).PeekMessagesAsync(
            new PeekMessagesRequest { TopicName = "t", SubscriptionName = "s", DeadLetter = true });

        Assert.Equal(("t", "s"), (client.Topic, client.Subscription));
        Assert.Equal(SubQueue.DeadLetter, client.Options?.SubQueue);
    }

    // ── Purge ────────────────────────────────────────────────────────────────

    [Fact]
    public async Task Purge_CountsAllMessages_AndStopsAfterFiveEmptyBatches()
    {
        var receiver = new FakeReceiver
        {
            Batches = new Queue<List<ServiceBusReceivedMessage>>(
            [
                [Msg(1), Msg(2), Msg(3)],
                [],
                [Msg(4)],
                [], [], [], [], [],
            ]),
        };
        var client = new FakeClient(receiver);

        var reply = await new MessageOperations(client, null)
            .PurgeMessagesAsync(new PurgeMessagesRequest { QueueName = "q" });

        Assert.Equal(4, reply.PurgedCount);
        Assert.Equal(ServiceBusReceiveMode.ReceiveAndDelete, client.Options?.ReceiveMode);
        Assert.Equal(SubQueue.None, client.Options?.SubQueue);
    }

    [Fact]
    public async Task Purge_DeadLetter_UsesDeadLetterSubQueue()
    {
        var client = new FakeClient(new FakeReceiver());

        await new MessageOperations(client, null)
            .PurgeMessagesAsync(new PurgeMessagesRequest { QueueName = "q", DeadLetter = true });

        Assert.Equal(SubQueue.DeadLetter, client.Options?.SubQueue);
    }

    // ── Delete single message ────────────────────────────────────────────────

    [Fact]
    public async Task DeleteMessage_CompletesTarget_AndAbandonsOthers()
    {
        var receiver = new FakeReceiver
        {
            Batches = new Queue<List<ServiceBusReceivedMessage>>([[Msg(1), Msg(2), Msg(3)]]),
        };

        var reply = await Ops(receiver).DeleteMessageAsync(
            new DeleteMessageRequest { QueueName = "q", SequenceNumber = 2 });

        Assert.True(reply.Success);
        Assert.Equal(new long[] { 2 }, receiver.Completed);
        Assert.Equal(new long[] { 1, 3 }, receiver.Abandoned.OrderBy(x => x));
    }

    [Fact]
    public async Task DeleteMessage_NotFound_AbandonsEverything()
    {
        var receiver = new FakeReceiver
        {
            Batches = new Queue<List<ServiceBusReceivedMessage>>([[Msg(1)], []]),
        };

        var reply = await Ops(receiver).DeleteMessageAsync(
            new DeleteMessageRequest { QueueName = "q", SequenceNumber = 99 });

        Assert.False(reply.Success);
        Assert.Equal("Message not found", reply.Error);
        Assert.Empty(receiver.Completed);
        Assert.Equal(new long[] { 1 }, receiver.Abandoned);
    }

    // ── Delete many ──────────────────────────────────────────────────────────

    [Fact]
    public async Task DeleteMessages_CompletesRequested_ReportsMissing_AndReleasesSkipped()
    {
        var receiver = new FakeReceiver
        {
            Batches = new Queue<List<ServiceBusReceivedMessage>>([[Msg(1), Msg(2), Msg(3)], []]),
        };
        var request = new DeleteMessagesRequest { QueueName = "q" };
        request.SequenceNumbers.AddRange([1L, 3L, 42L]);

        var reply = await Ops(receiver).DeleteMessagesAsync(request);

        Assert.Equal(2, reply.DeletedCount);
        Assert.Equal(new long[] { 42 }, reply.NotFoundSequenceNumbers);
        Assert.Equal(new long[] { 2 }, receiver.Abandoned);
        Assert.Equal(string.Empty, reply.Error);
    }

    [Fact]
    public async Task DeleteMessages_EmptyRequest_DoesNothing()
    {
        var client = new FakeClient(new FakeReceiver());

        var reply = await new MessageOperations(client, null).DeleteMessagesAsync(new DeleteMessagesRequest { QueueName = "q" });

        Assert.Equal(0, reply.DeletedCount);
        Assert.Null(client.Options);
    }

    // ── Send ─────────────────────────────────────────────────────────────────

    [Fact]
    public async Task SendExtended_MapsFields_AndReservedBusKitProperties()
    {
        var sender = new FakeSender();
        var client = new FakeClient(new FakeReceiver()) { Sender = sender };
        var request = new SendMessageExtendedRequest
        {
            QueueOrTopic = "q", Body = "hi", Subject = "subj", MessageId = "id-1", SessionId = "sess",
        };
        request.Properties["x-buskit-ttl-seconds"] = "60";
        request.Properties["x-buskit-scheduled-enqueue-time-unix"] = "1700000000";
        request.Properties["custom"] = "v";

        var reply = await new MessageOperations(client, null).SendMessageExtendedAsync(request);

        Assert.True(reply.Success);
        Assert.Equal("id-1", reply.MessageId);
        var sent = Assert.Single(sender.Sent);
        Assert.Equal("subj", sent.Subject);
        Assert.Equal("sess", sent.SessionId);
        Assert.Null(sent.ContentType);
        Assert.Equal(TimeSpan.FromSeconds(60), sent.TimeToLive);
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1700000000), sent.ScheduledEnqueueTime);
        Assert.Equal("v", sent.ApplicationProperties["custom"]);
        Assert.DoesNotContain("x-buskit-ttl-seconds", sent.ApplicationProperties.Keys);
    }

    [Fact]
    public async Task SendExtended_ReturnsFailure_WhenSendThrows()
    {
        var client = new FakeClient(new FakeReceiver()) { Sender = new FakeSender { Fail = true } };

        var reply = await new MessageOperations(client, null)
            .SendMessageExtendedAsync(new SendMessageExtendedRequest { QueueOrTopic = "q", Body = "x" });

        Assert.False(reply.Success);
        Assert.Equal("boom", reply.Error);
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    private static MessageOperations Ops(FakeReceiver receiver) => new(new FakeClient(receiver), null);

    private static ServiceBusReceivedMessage Msg(long seq) => ServiceBusModelFactory.ServiceBusReceivedMessage(
        body: BinaryData.FromString("{}"),
        messageId: $"m{seq}",
        sequenceNumber: seq,
        enqueuedTime: DateTimeOffset.UtcNow,
        properties: new Dictionary<string, object> { ["k"] = $"v{seq}" });

    private sealed class FakeClient(ServiceBusReceiver receiver) : ServiceBusClient
    {
        public ServiceBusReceiverOptions? Options { get; private set; }
        public string? Topic { get; private set; }
        public string? Subscription { get; private set; }
        public ServiceBusSender? Sender { get; init; }

        public override ServiceBusReceiver CreateReceiver(string queueName, ServiceBusReceiverOptions options)
        {
            Options = options;
            return receiver;
        }

        public override ServiceBusReceiver CreateReceiver(
            string topicName, string subscriptionName, ServiceBusReceiverOptions options)
        {
            (Topic, Subscription, Options) = (topicName, subscriptionName, options);
            return receiver;
        }

        public override ServiceBusSender CreateSender(string queueOrTopicName) => Sender!;
    }

    private sealed class FakeReceiver : ServiceBusReceiver
    {
        public List<ServiceBusReceivedMessage> Stored { get; init; } = [];
        public Queue<List<ServiceBusReceivedMessage>> Batches { get; init; } = new();
        public List<int> PeekBatchSizes { get; } = [];
        public List<long> PeekFromSequence { get; } = [];
        public List<long> Completed { get; } = [];
        public List<long> Abandoned { get; } = [];

        public override Task<IReadOnlyList<ServiceBusReceivedMessage>> PeekMessagesAsync(
            int maxMessages, long? fromSequenceNumber = null, CancellationToken cancellationToken = default)
        {
            PeekBatchSizes.Add(maxMessages);
            PeekFromSequence.Add(fromSequenceNumber ?? 0);
            IReadOnlyList<ServiceBusReceivedMessage> page = Stored
                .Where(m => m.SequenceNumber >= (fromSequenceNumber ?? 0))
                .Take(maxMessages).ToList();
            return Task.FromResult(page);
        }

        public override Task<IReadOnlyList<ServiceBusReceivedMessage>> ReceiveMessagesAsync(
            int maxMessages, TimeSpan? maxWaitTime = null, CancellationToken cancellationToken = default)
        {
            IReadOnlyList<ServiceBusReceivedMessage> batch = Batches.Count > 0 ? Batches.Dequeue() : [];
            return Task.FromResult(batch);
        }

        public override Task CompleteMessageAsync(ServiceBusReceivedMessage message, CancellationToken cancellationToken = default)
        {
            Completed.Add(message.SequenceNumber);
            return Task.CompletedTask;
        }

        public override Task AbandonMessageAsync(
            ServiceBusReceivedMessage message, IDictionary<string, object>? propertiesToModify = null,
            CancellationToken cancellationToken = default)
        {
            Abandoned.Add(message.SequenceNumber);
            return Task.CompletedTask;
        }

        public override Task CloseAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
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
}
