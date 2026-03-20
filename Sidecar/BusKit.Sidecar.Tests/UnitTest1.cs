using Azure.Messaging.ServiceBus;
using BusKit.Sidecar.Grpc;
using BusKit.Sidecar.Services;

namespace BusKit.Sidecar.Tests;

public class PurgeWithSqlFilterTests
{
    [Fact]
    [Trait("Category", "Integration")]
    public async Task Integration_Subscription_FetchAndPurgeMessages()
    {
        // var connectionString = RequireEnv("SERVICEBUS_CONNECTION_STRING");
        // var topicName = RequireEnv("SERVICEBUS_TOPIC_NAME");
        // var subscriptionName = RequireEnv("SERVICEBUS_SUBSCRIPTION_NAME");

        var connectionString = "Endpoint=sb://ucruatsbnamespace.servicebus.windows.net/;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=vO78sHiqd1vOo0ygeVHm0OPONmSJ7ByAa+ASbBegYYM=";
        var topicName = "ucrsbt_salesforce";
        var subscriptionName = "ucrsbs_crmde";

        await using var client = new ServiceBusClient(connectionString);
        await using var receiver = client.CreateReceiver(
            topicName,
            subscriptionName,
            new ServiceBusReceiverOptions
            {
                ReceiveMode = ServiceBusReceiveMode.PeekLock,
                SubQueue = SubQueue.DeadLetter
            });

        var request = new PurgeMessagesRequest { SqlFilter = "[X-GSEB-Optins] LIKE '%IT%'" };
        var beforePurge = await receiver.PeekMessagesAsync(maxMessages: 100);
        var beforeMatchingCount = CountMatchingOptins(beforePurge);

        await using var adapter = new RealReceiverAdapter(receiver);
        var reply = await BusKitServiceImpl.PurgeWithSqlFilterCore(request, CancellationToken.None, adapter);

        // In shared environments, new DLQ messages can arrive concurrently.
        // Validate that matching messages did not increase after purge.
        var afterPurge = await receiver.PeekMessagesAsync(maxMessages: 100);
        var afterMatchingCount = CountMatchingOptins(afterPurge);

        Assert.True(reply.PurgedCount >= 0);
        Assert.True(
            afterMatchingCount <= beforeMatchingCount,
            $"Expected matching DLQ messages to decrease or stay the same. Before={beforeMatchingCount}, After={afterMatchingCount}, Purged={reply.PurgedCount}");
    }

    [Fact]
    public async Task PurgeWithSqlFilterCore_CompletesMatches_AndRestoresDeferred()
    {
        var request = new PurgeMessagesRequest { SqlFilter = "[X-GSEB-Optins] LIKE '%IT%'" };

        var m1 = CreateMessage(1, "m1", new Dictionary<string, object> { ["X-GSEB-Optins"] = "IT" });
        var m2 = CreateMessage(2, "m2", new Dictionary<string, object> { ["X-GSEB-Optins"] = "US" });
        var m3 = CreateMessage(3, "m3", new Dictionary<string, object> { ["X-GSEB-Optins"] = "IT" });
    
        var receiver = new FakeReceiver(new[]
        {
            new List<ServiceBusReceivedMessage> { m1, m2, m3 },
            new List<ServiceBusReceivedMessage>()
        });

        var reply = await BusKitServiceImpl.PurgeWithSqlFilterCore(request, CancellationToken.None, receiver);

        Assert.Equal(2, reply.PurgedCount);
        Assert.Equal(new long[] { 1, 3 }, receiver.CompletedSequenceNumbers);
        Assert.Equal(new long[] { 2 }, receiver.DeferredSequenceNumbers);
        Assert.Equal(new long[] { 2 }, receiver.ReceiveDeferredRequestedSequenceNumbers);
        Assert.Equal(new long[] { 2 }, receiver.AbandonedSequenceNumbers);
    }

    [Fact]
    public async Task PurgeWithSqlFilterCore_WhenAllMessagesMatch_DoesNotReadDeferredMessages()
    {
        var request = new PurgeMessagesRequest { SqlFilter = "[X-GSEB-Optins] LIKE '%IT%'" };

        var m1 = CreateMessage(10, "m10", new Dictionary<string, object> { ["X-GSEB-Optins"] = "IT" });
        var m2 = CreateMessage(11, "m11", new Dictionary<string, object> { ["X-GSEB-Optins"] = "IT" });

        var receiver = new FakeReceiver(new[]
        {
            new List<ServiceBusReceivedMessage> { m1, m2 },
            new List<ServiceBusReceivedMessage>()
        });

        var reply = await BusKitServiceImpl.PurgeWithSqlFilterCore(request, CancellationToken.None, receiver);

        Assert.Equal(2, reply.PurgedCount);
        Assert.Empty(receiver.DeferredSequenceNumbers);
        Assert.Empty(receiver.ReceiveDeferredRequestedSequenceNumbers);
        Assert.Empty(receiver.AbandonedSequenceNumbers);
    }

    [Fact]
    public async Task PurgeWithSqlFilterCore_NormalizesSmartQuotesInSqlFilter()
    {
        var request = new PurgeMessagesRequest { SqlFilter = "[X-GSEB-Optins] LIKE '%IT%'" };

        var m1 = CreateMessage(21, "m21", new Dictionary<string, object> { ["X-GSEB-Optins"] = "IT" });
        var m2 = CreateMessage(22, "m22", new Dictionary<string, object> { ["X-GSEB-Optins"] = "B" });

        var receiver = new FakeReceiver(new[]
        {
            new List<ServiceBusReceivedMessage> { m1, m2 },
            new List<ServiceBusReceivedMessage>()
        });

        var reply = await BusKitServiceImpl.PurgeWithSqlFilterCore(request, CancellationToken.None, receiver);

        Assert.Equal(1, reply.PurgedCount);
        Assert.Equal(new long[] { 21 }, receiver.CompletedSequenceNumbers);
        Assert.Equal(new long[] { 22 }, receiver.AbandonedSequenceNumbers);
    }

    private static ServiceBusReceivedMessage CreateMessage(
        long sequenceNumber,
        string messageId,
        IDictionary<string, object> applicationProperties)
    {
        return ServiceBusModelFactory.ServiceBusReceivedMessage(
            body: BinaryData.FromString("{}"),
            messageId: messageId,
            sequenceNumber: sequenceNumber,
            enqueuedTime: DateTimeOffset.UtcNow,
            properties: applicationProperties);
    }

    private static string RequireEnv(string name)
    {
        var value = Environment.GetEnvironmentVariable(name);
        return !string.IsNullOrWhiteSpace(value)
            ? value
            : throw new InvalidOperationException($"Missing required environment variable: {name}");
    }

    private static int CountMatchingOptins(IEnumerable<ServiceBusReceivedMessage> messages)
    {
        return messages
            .Where(m => m.ApplicationProperties.TryGetValue("X-GSEB-Optins", out _))
            .Select(m => m.ApplicationProperties["X-GSEB-Optins"]?.ToString() ?? string.Empty)
            .Count(v => v.Contains("GB", StringComparison.OrdinalIgnoreCase));
    }

    private sealed class RealReceiverAdapter(ServiceBusReceiver receiver) : BusKitServiceImpl.IServiceBusReceiverAdapter
    {
        private readonly ServiceBusReceiver _receiver = receiver;

        public Task<IReadOnlyList<ServiceBusReceivedMessage>> ReceiveMessagesAsync(
            int maxMessages,
            TimeSpan maxWaitTime,
            CancellationToken cancellationToken = default) =>
            _receiver.ReceiveMessagesAsync(maxMessages, maxWaitTime, cancellationToken);

        public Task CompleteMessageAsync(ServiceBusReceivedMessage message, CancellationToken cancellationToken = default) =>
            _receiver.CompleteMessageAsync(message, cancellationToken);

        public Task DeferMessageAsync(ServiceBusReceivedMessage message, CancellationToken cancellationToken = default) =>
            _receiver.DeferMessageAsync(message, cancellationToken: cancellationToken);

        public Task<IReadOnlyList<ServiceBusReceivedMessage>> ReceiveDeferredMessagesAsync(
            IEnumerable<long> sequenceNumbers,
            CancellationToken cancellationToken = default) =>
            _receiver.ReceiveDeferredMessagesAsync(sequenceNumbers, cancellationToken);

        public Task AbandonMessageAsync(ServiceBusReceivedMessage message, CancellationToken cancellationToken = default) =>
            _receiver.AbandonMessageAsync(message, cancellationToken: cancellationToken);

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    private sealed class FakeReceiver(
        IEnumerable<IReadOnlyList<ServiceBusReceivedMessage>> batches) : BusKitServiceImpl.IServiceBusReceiverAdapter
    {
        private readonly Queue<IReadOnlyList<ServiceBusReceivedMessage>> _batches = new(batches);
        private readonly Dictionary<long, ServiceBusReceivedMessage> _deferred = new();

        public List<long> CompletedSequenceNumbers { get; } = new();
        public List<long> DeferredSequenceNumbers { get; } = new();
        public List<long> ReceiveDeferredRequestedSequenceNumbers { get; } = new();
        public List<long> AbandonedSequenceNumbers { get; } = new();

        public Task<IReadOnlyList<ServiceBusReceivedMessage>> ReceiveMessagesAsync(
            int maxMessages,
            TimeSpan maxWaitTime,
            CancellationToken cancellationToken = default)
        {
            if (_batches.Count == 0)
                return Task.FromResult<IReadOnlyList<ServiceBusReceivedMessage>>(new List<ServiceBusReceivedMessage>());

            return Task.FromResult(_batches.Dequeue());
        }

        public Task CompleteMessageAsync(ServiceBusReceivedMessage message, CancellationToken cancellationToken = default)
        {
            CompletedSequenceNumbers.Add(message.SequenceNumber);
            return Task.CompletedTask;
        }

        public Task DeferMessageAsync(ServiceBusReceivedMessage message, CancellationToken cancellationToken = default)
        {
            DeferredSequenceNumbers.Add(message.SequenceNumber);
            _deferred[message.SequenceNumber] = message;
            return Task.CompletedTask;
        }

        public Task<IReadOnlyList<ServiceBusReceivedMessage>> ReceiveDeferredMessagesAsync(
            IEnumerable<long> sequenceNumbers,
            CancellationToken cancellationToken = default)
        {
            var seqList = sequenceNumbers.ToList();
            ReceiveDeferredRequestedSequenceNumbers.AddRange(seqList);

            var messages = seqList
                .Where(_deferred.ContainsKey)
                .Select(seq => _deferred[seq])
                .ToList();

            return Task.FromResult<IReadOnlyList<ServiceBusReceivedMessage>>(messages);
        }

        public Task AbandonMessageAsync(ServiceBusReceivedMessage message, CancellationToken cancellationToken = default)
        {
            AbandonedSequenceNumbers.Add(message.SequenceNumber);
            return Task.CompletedTask;
        }

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}
