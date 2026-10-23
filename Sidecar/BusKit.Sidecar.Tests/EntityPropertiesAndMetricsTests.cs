using Azure;
using Azure.Messaging.ServiceBus;
using Azure.Messaging.ServiceBus.Administration;
using BusKit.Sidecar.Grpc;
using BusKit.Sidecar.Services;

namespace BusKit.Sidecar.Tests;

public class EntityPropertiesAndMetricsTests
{
    [Theory]
    [InlineData(1, 1)]
    [InlineData(0, 1)]
    [InlineData(6, 5)]
    [InlineData(12, 5)]
    [InlineData(24, 15)]
    [InlineData(168, 60)]
    [InlineData(169, 360)]
    public void Granularity_ScalesWithRange(int hours, int expectedMinutes)
        => Assert.Equal(TimeSpan.FromMinutes(expectedMinutes), MetricsOperations.GranularityFor(hours));

    [Fact]
    public async Task Metrics_WithoutAzureAdConnection_ReturnsError()
    {
        var ops = new MetricsOperations(null, null, null, null);

        var topic = await ops.GetTopicMetricsAsync(new GetTopicMetricsRequest { TopicName = "t", Hours = 1 });
        var queue = await ops.GetQueueMetricsAsync(new GetQueueMetricsRequest { QueueName = "q", Hours = 1 });

        Assert.Equal("Azure AD connection required for metrics.", topic.Error);
        Assert.Equal("Azure AD connection required for metrics.", queue.Error);
        Assert.Empty(topic.Series);
    }

    [Fact]
    public async Task Properties_WhenNotConnected_ReturnEmptyReplies()
    {
        var ops = new EntityPropertiesOperations(null);

        Assert.Null((await ops.GetQueuePropertiesAsync(new GetQueuePropertiesRequest { Name = "q" })).Properties);
        Assert.Equal("Not connected.",
            (await ops.UpdateSubscriptionTtlAsync(new UpdateSubscriptionTtlRequest())).Error);
    }

    [Fact]
    public async Task GetQueueProperties_MapsPropertiesAndRuntimeCounts()
    {
        var created = DateTimeOffset.FromUnixTimeSeconds(1_700_000_000);
        var admin = new FakeAdmin
        {
            Queue = ServiceBusModelFactory.QueueProperties(
                name: "orders", lockDuration: TimeSpan.FromSeconds(45), maxSizeInMegabytes: 2048,
                defaultMessageTimeToLive: TimeSpan.FromHours(1), autoDeleteOnIdle: TimeSpan.FromDays(14),
                maxDeliveryCount: 7, duplicateDetectionHistoryTimeWindow: TimeSpan.FromMinutes(10),
                userMetadata: "meta", status: EntityStatus.ReceiveDisabled),
            QueueRuntime = ServiceBusModelFactory.QueueRuntimeProperties(
                name: "orders", activeMessageCount: 5, deadLetterMessageCount: 2, sizeInBytes: 1234,
                createdAt: created, updatedAt: created),
        };

        var reply = await new EntityPropertiesOperations(admin)
            .GetQueuePropertiesAsync(new GetQueuePropertiesRequest { Name = "orders" });

        var p = reply.Properties;
        Assert.Equal("orders", p.Name);
        Assert.Equal(2048, p.MaxSizeMb);
        Assert.Equal(3600, p.DefaultMessageTtlSeconds);
        Assert.Equal(45, p.LockDurationSeconds);
        Assert.Equal(7, p.MaxDeliveryCount);
        Assert.Equal("ReceiveDisabled", p.Status);
        Assert.Equal(5, p.ActiveMessageCount);
        Assert.Equal(2, p.DeadLetterCount);
        Assert.Equal(1234, p.SizeBytes);
        Assert.Equal(1_700_000_000, p.CreatedAtUnix);
        Assert.Equal("meta", p.UserMetadata);
        Assert.Equal(string.Empty, p.ForwardTo);
    }

    private sealed class FakeAdmin : ServiceBusAdministrationClient
    {
        public QueueProperties? Queue { get; init; }
        public QueueRuntimeProperties? QueueRuntime { get; init; }

        public override Task<Response<QueueProperties>> GetQueueAsync(
            string name, CancellationToken cancellationToken = default)
            => Task.FromResult(Response.FromValue(Queue!, null!));

        public override Task<Response<QueueRuntimeProperties>> GetQueueRuntimePropertiesAsync(
            string name, CancellationToken cancellationToken = default)
            => Task.FromResult(Response.FromValue(QueueRuntime!, null!));
    }
}
