using Azure;
using Azure.Messaging.ServiceBus;
using Azure.Messaging.ServiceBus.Administration;
using BusKit.Sidecar.Grpc;
using BusKit.Sidecar.Services;

namespace BusKit.Sidecar.Tests;

public class TopicSubscriptionRuleTests
{
    private static readonly EntityOperations Disconnected = new(null);

    [Fact]
    public async Task WhenNotConnected_TopicSubscriptionAndRuleCallsReturnError()
    {
        Assert.NotEmpty((await Disconnected.CreateTopicAsync(new CreateTopicRequest { TopicName = "t" })).Error);
        Assert.NotEmpty((await Disconnected.DeleteTopicAsync(new DeleteTopicRequest { TopicName = "t" })).Error);
        Assert.NotEmpty((await Disconnected.DeleteSubscriptionAsync(new DeleteSubscriptionRequest())).Error);
        Assert.NotEmpty((await Disconnected.UpdateRuleAsync(new UpdateRuleRequest())).Error);
        Assert.NotEmpty((await Disconnected.DeleteRuleAsync(new DeleteRuleRequest())).Error);
    }

    [Fact]
    public async Task CreateTopic_AppliesDefaults_WhenRequestValuesAreZero()
    {
        var admin = new FakeAdmin();

        var reply = await new EntityOperations(admin).CreateTopicAsync(new CreateTopicRequest { TopicName = "events" });

        Assert.Equal(string.Empty, reply.Error);
        var o = Assert.IsType<CreateTopicOptions>(admin.Created);
        Assert.Equal("events", o.Name);
        Assert.Equal(1024, o.MaxSizeInMegabytes);
        Assert.Equal(TimeSpan.FromDays(14), o.DefaultMessageTimeToLive);
    }

    [Fact]
    public async Task CreateTopic_UsesRequestValues()
    {
        var admin = new FakeAdmin();

        await new EntityOperations(admin).CreateTopicAsync(new CreateTopicRequest
        {
            TopicName = "t", MaxSizeMb = 2048, DefaultMessageTtlSeconds = 60, RequiresDuplicateDetection = true,
            SupportOrdering = true, AutoDeleteOnIdleSeconds = 600,
        });

        var o = Assert.IsType<CreateTopicOptions>(admin.Created);
        Assert.Equal(2048, o.MaxSizeInMegabytes);
        Assert.Equal(TimeSpan.FromMinutes(1), o.DefaultMessageTimeToLive);
        Assert.True(o.RequiresDuplicateDetection);
        Assert.True(o.SupportOrdering);
        Assert.Equal(TimeSpan.FromMinutes(10), o.AutoDeleteOnIdle);
    }

    [Fact]
    public async Task Mutations_ReturnExceptionMessage_OnFailure()
    {
        var ops = new EntityOperations(new FakeAdmin { Fail = true });

        Assert.Equal("boom", (await ops.CreateTopicAsync(new CreateTopicRequest { TopicName = "t" })).Error);
        Assert.Equal("boom", (await ops.DeleteTopicAsync(new DeleteTopicRequest { TopicName = "t" })).Error);
        Assert.Equal("boom", (await ops.DeleteSubscriptionAsync(new DeleteSubscriptionRequest())).Error);
        Assert.Equal("boom", (await ops.DeleteRuleAsync(new DeleteRuleRequest())).Error);
        Assert.Equal("boom", (await ops.UpdateRuleAsync(new UpdateRuleRequest())).Error);
    }

    [Fact]
    public async Task Deletes_PassNamesToAdminClient()
    {
        var admin = new FakeAdmin();
        var ops = new EntityOperations(admin);

        await ops.DeleteTopicAsync(new DeleteTopicRequest { TopicName = "t" });
        await ops.DeleteSubscriptionAsync(new DeleteSubscriptionRequest { TopicName = "t", SubscriptionName = "s" });
        await ops.DeleteRuleAsync(new DeleteRuleRequest { TopicName = "t", SubscriptionName = "s", RuleName = "r" });

        Assert.Equal(["topic:t", "sub:t/s", "rule:t/s/r"], admin.Deleted);
    }

    [Fact]
    public async Task UpdateRule_ReplacesFilterWithSqlFilter()
    {
        var admin = new FakeAdmin();

        var reply = await new EntityOperations(admin).UpdateRuleAsync(new UpdateRuleRequest
        {
            TopicName = "t", SubscriptionName = "s", RuleName = "r", SqlFilter = "b = 2",
        });

        Assert.Equal(string.Empty, reply.Error);
        Assert.Equal("b = 2", Assert.IsType<SqlRuleFilter>(admin.UpdatedRule!.Filter).SqlExpression);
    }

    [Fact]
    public async Task GetTopicProperties_MapsPropertiesAndRuntimeValues()
    {
        var created = DateTimeOffset.FromUnixTimeSeconds(1_700_000_000);
        var admin = new FakeAdmin
        {
            Topic = ServiceBusModelFactory.TopicProperties(
                name: "events", maxSizeInMegabytes: 4096, requiresDuplicateDetection: true,
                defaultMessageTimeToLive: TimeSpan.FromHours(2), autoDeleteOnIdle: TimeSpan.FromMinutes(30),
                duplicateDetectionHistoryTimeWindow: TimeSpan.FromMinutes(10),
                status: EntityStatus.SendDisabled),
            TopicRuntime = ServiceBusModelFactory.TopicRuntimeProperties(
                name: "events", sizeInBytes: 99, createdAt: created, updatedAt: created, scheduledMessageCount: 3),
        };

        var p = (await new EntityPropertiesOperations(admin)
            .GetTopicPropertiesAsync(new GetTopicPropertiesRequest { Name = "events" })).Properties;

        Assert.Equal("events", p.Name);
        Assert.Equal(4096, p.MaxSizeMb);
        Assert.Equal(7200, p.DefaultMessageTtlSeconds);
        Assert.Equal(1800, p.AutoDeleteOnIdleSeconds);
        Assert.True(p.RequiresDuplicateDetection);
        Assert.Equal("SendDisabled", p.Status);
        Assert.Equal(99, p.SizeBytes);
        Assert.Equal(3, p.ScheduledMessageCount);
        Assert.Equal(1_700_000_000, p.CreatedAtUnix);
    }

    [Fact]
    public async Task GetSubscriptionProperties_MapsPropertiesAndRuntimeValues()
    {
        var created = DateTimeOffset.FromUnixTimeSeconds(1_700_000_000);
        var admin = new FakeAdmin
        {
            Subscription = ServiceBusModelFactory.SubscriptionProperties(
                topicName: "events", subscriptionName: "audit", lockDuration: TimeSpan.FromSeconds(30),
                requiresSession: false, defaultMessageTimeToLive: TimeSpan.FromHours(1),
                deadLetteringOnMessageExpiration: true, maxDeliveryCount: 5,
                autoDeleteOnIdle: TimeSpan.FromDays(1), forwardTo: "other", status: EntityStatus.Active, userMetadata: ""),
            SubscriptionRuntime = ServiceBusModelFactory.SubscriptionRuntimeProperties(
                topicName: "events", subscriptionName: "audit", activeMessageCount: 8, deadLetterMessageCount: 1,
                createdAt: created, updatedAt: created),
        };

        var p = (await new EntityPropertiesOperations(admin).GetSubscriptionPropertiesAsync(
            new GetSubscriptionPropertiesRequest { TopicName = "events", SubscriptionName = "audit" })).Properties;

        Assert.Equal("events", p.TopicName);
        Assert.Equal("audit", p.Name);
        Assert.Equal(30, p.LockDurationSeconds);
        Assert.Equal(3600, p.DefaultMessageTtlSeconds);
        Assert.Equal(5, p.MaxDeliveryCount);
        Assert.True(p.DeadLetteringOnExpiration);
        Assert.Equal("other", p.ForwardTo);
        Assert.Equal(8, p.ActiveMessageCount);
        Assert.Equal(1, p.DeadLetterCount);
        Assert.Equal(86400, p.AutoDeleteOnIdleSeconds);
    }

    [Fact]
    public async Task UpdateSubscriptionTtl_AppliesNewTtl()
    {
        var admin = new FakeAdmin
        {
            Subscription = ServiceBusModelFactory.SubscriptionProperties(
                topicName: "t", subscriptionName: "s", lockDuration: TimeSpan.FromMinutes(1),
                defaultMessageTimeToLive: TimeSpan.FromDays(1), maxDeliveryCount: 10,
                autoDeleteOnIdle: TimeSpan.FromDays(1), userMetadata: ""),
        };

        var reply = await new EntityPropertiesOperations(admin).UpdateSubscriptionTtlAsync(
            new UpdateSubscriptionTtlRequest { TopicName = "t", SubscriptionName = "s", DefaultMessageTtlSeconds = 120 });

        Assert.Equal(string.Empty, reply.Error);
        Assert.Equal(TimeSpan.FromMinutes(2), admin.UpdatedSubscription!.DefaultMessageTimeToLive);
    }

    // ── fakes ────────────────────────────────────────────────────────────────

    private sealed class FakeAdmin : ServiceBusAdministrationClient
    {
        public bool Fail { get; init; }
        public object? Created { get; private set; }
        public List<string> Deleted { get; } = [];
        public RuleProperties? UpdatedRule { get; private set; }
        public SubscriptionProperties? UpdatedSubscription { get; private set; }
        public TopicProperties? Topic { get; init; }
        public TopicRuntimeProperties? TopicRuntime { get; init; }
        public SubscriptionProperties? Subscription { get; init; }
        public SubscriptionRuntimeProperties? SubscriptionRuntime { get; init; }

        private void ThrowIfFailing()
        {
            if (Fail) throw new InvalidOperationException("boom");
        }

        public override Task<Response<TopicProperties>> CreateTopicAsync(
            CreateTopicOptions options, CancellationToken cancellationToken = default)
        {
            ThrowIfFailing();
            Created = options;
            return Task.FromResult(Response.FromValue<TopicProperties>(null!, null!));
        }

        public override Task<Response> DeleteTopicAsync(string topicName, CancellationToken cancellationToken = default)
        {
            ThrowIfFailing();
            Deleted.Add($"topic:{topicName}");
            return Task.FromResult<Response>(null!);
        }

        public override Task<Response> DeleteSubscriptionAsync(
            string topicName, string subscriptionName, CancellationToken cancellationToken = default)
        {
            ThrowIfFailing();
            Deleted.Add($"sub:{topicName}/{subscriptionName}");
            return Task.FromResult<Response>(null!);
        }

        public override Task<Response> DeleteRuleAsync(
            string topicName, string subscriptionName, string ruleName, CancellationToken cancellationToken = default)
        {
            ThrowIfFailing();
            Deleted.Add($"rule:{topicName}/{subscriptionName}/{ruleName}");
            return Task.FromResult<Response>(null!);
        }

        public override Task<Response<RuleProperties>> GetRuleAsync(
            string topicName, string subscriptionName, string ruleName, CancellationToken cancellationToken = default)
        {
            ThrowIfFailing();
            return Task.FromResult(Response.FromValue(
                ServiceBusModelFactory.RuleProperties(ruleName, new TrueRuleFilter(), null), null!));
        }

        public override Task<Response<RuleProperties>> UpdateRuleAsync(
            string topicName, string subscriptionName, RuleProperties rule, CancellationToken cancellationToken = default)
        {
            UpdatedRule = rule;
            return Task.FromResult(Response.FromValue(rule, null!));
        }

        public override Task<Response<TopicProperties>> GetTopicAsync(
            string name, CancellationToken cancellationToken = default)
            => Task.FromResult(Response.FromValue(Topic!, null!));

        public override Task<Response<TopicRuntimeProperties>> GetTopicRuntimePropertiesAsync(
            string name, CancellationToken cancellationToken = default)
            => Task.FromResult(Response.FromValue(TopicRuntime!, null!));

        public override Task<Response<SubscriptionProperties>> GetSubscriptionAsync(
            string topicName, string subscriptionName, CancellationToken cancellationToken = default)
            => Task.FromResult(Response.FromValue(Subscription!, null!));

        public override Task<Response<SubscriptionRuntimeProperties>> GetSubscriptionRuntimePropertiesAsync(
            string topicName, string subscriptionName, CancellationToken cancellationToken = default)
            => Task.FromResult(Response.FromValue(SubscriptionRuntime!, null!));

        public override Task<Response<SubscriptionProperties>> UpdateSubscriptionAsync(
            SubscriptionProperties subscription, CancellationToken cancellationToken = default)
        {
            UpdatedSubscription = subscription;
            return Task.FromResult(Response.FromValue(subscription, null!));
        }
    }
}
