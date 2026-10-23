using Azure;
using Azure.Messaging.ServiceBus;
using Azure.Messaging.ServiceBus.Administration;
using BusKit.Sidecar.Grpc;
using BusKit.Sidecar.Services;

namespace BusKit.Sidecar.Tests;

public class EntityOperationsTests
{
    private static readonly EntityOperations Disconnected = new(null);

    [Fact]
    public async Task WhenNotConnected_MutatingCallsReturnError()
    {
        Assert.NotEmpty((await Disconnected.CreateQueueAsync(new CreateQueueRequest { QueueName = "q" })).Error);
        Assert.NotEmpty((await Disconnected.DeleteQueueAsync(new DeleteQueueRequest { QueueName = "q" })).Error);
        Assert.NotEmpty((await Disconnected.AddRuleAsync(new AddRuleRequest())).Error);
        Assert.NotEmpty((await Disconnected.SetTopicStatusAsync(new SetTopicStatusRequest())).Error);
    }

    [Fact]
    public async Task WhenNotConnected_ListCallsReturnEmpty()
    {
        Assert.Empty((await Disconnected.ListQueuesAsync(new ListQueuesRequest())).Queues);
        Assert.Empty((await Disconnected.ListTopicsAsync(new ListTopicsRequest())).Topics);
    }

    [Fact]
    public async Task CreateQueue_AppliesDefaults_WhenRequestValuesAreZero()
    {
        var admin = new FakeAdmin();

        var reply = await new EntityOperations(admin).CreateQueueAsync(new CreateQueueRequest { QueueName = "orders" });

        Assert.Equal(string.Empty, reply.Error);
        var o = Assert.IsType<CreateQueueOptions>(admin.Created);
        Assert.Equal("orders", o.Name);
        Assert.Equal(1024, o.MaxSizeInMegabytes);
        Assert.Equal(10, o.MaxDeliveryCount);
        Assert.Equal(TimeSpan.FromDays(14), o.DefaultMessageTimeToLive);
        Assert.Equal(TimeSpan.FromMinutes(1), o.LockDuration);
        Assert.Null(o.ForwardTo);
    }

    [Fact]
    public async Task CreateQueue_UsesRequestValues()
    {
        var admin = new FakeAdmin();
        var request = new CreateQueueRequest
        {
            QueueName = "q", MaxDeliveryCount = 3, LockDurationSeconds = 45,
            ForwardTo = "other", RequiresSession = true, AutoDeleteOnIdleSeconds = 600,
        };

        await new EntityOperations(admin).CreateQueueAsync(request);

        var o = Assert.IsType<CreateQueueOptions>(admin.Created);
        Assert.Equal(3, o.MaxDeliveryCount);
        Assert.Equal(TimeSpan.FromSeconds(45), o.LockDuration);
        Assert.Equal("other", o.ForwardTo);
        Assert.True(o.RequiresSession);
        Assert.Equal(TimeSpan.FromMinutes(10), o.AutoDeleteOnIdle);
    }

    [Fact]
    public async Task CreateQueue_ReturnsExceptionMessage_OnFailure()
    {
        var admin = new FakeAdmin { Fail = true };

        var reply = await new EntityOperations(admin).CreateQueueAsync(new CreateQueueRequest { QueueName = "q" });

        Assert.Equal("boom", reply.Error);
    }

    [Fact]
    public async Task CreateSubscription_ForwardsOnlyWhenEnabled_AndHonoursNeverAutoDelete()
    {
        var admin = new FakeAdmin();
        var ops = new EntityOperations(admin);

        await ops.CreateSubscriptionAsync(new CreateSubscriptionRequest
        {
            TopicName = "t", SubscriptionName = "s", ForwardTo = " dest ", AutoDeleteOnIdleSeconds = 300,
        });
        var withoutForward = Assert.IsType<CreateSubscriptionOptions>(admin.Created);
        Assert.Null(withoutForward.ForwardTo);
        Assert.Equal(TimeSpan.FromMinutes(5), withoutForward.AutoDeleteOnIdle);

        await ops.CreateSubscriptionAsync(new CreateSubscriptionRequest
        {
            TopicName = "t", SubscriptionName = "s", ForwardMessages = true, ForwardTo = " dest ",
            NeverAutoDelete = true, AutoDeleteOnIdleSeconds = 300,
        });
        var withForward = Assert.IsType<CreateSubscriptionOptions>(admin.Created);
        Assert.Equal("dest", withForward.ForwardTo);
        Assert.NotEqual(TimeSpan.FromMinutes(5), withForward.AutoDeleteOnIdle);
    }

    [Fact]
    public async Task AddRule_CreatesSqlRule()
    {
        var admin = new FakeAdmin();

        await new EntityOperations(admin).AddRuleAsync(new AddRuleRequest
        {
            TopicName = "t", SubscriptionName = "s", RuleName = "r", SqlFilter = "a = 1",
        });

        var rule = Assert.IsType<CreateRuleOptions>(admin.Created);
        Assert.Equal("r", rule.Name);
        Assert.Equal("a = 1", Assert.IsType<SqlRuleFilter>(rule.Filter).SqlExpression);
    }

    [Fact]
    public async Task ListRules_FormatsFilterDescriptions()
    {
        var admin = new FakeAdmin
        {
            Rules =
            [
                ServiceBusModelFactory.RuleProperties("sql", new SqlRuleFilter("x > 1"), null),
                ServiceBusModelFactory.RuleProperties("cor", new CorrelationRuleFilter { CorrelationId = "abc" }, null),
                ServiceBusModelFactory.RuleProperties("all", new TrueRuleFilter(), null),
            ],
        };

        var reply = await new EntityOperations(admin).ListRulesAsync(
            new ListRulesRequest { TopicName = "t", SubscriptionName = "s" });

        Assert.Equal("SQL: x > 1", reply.Rules[0].Filter);
        Assert.Equal("Correlation: abc", reply.Rules[1].Filter);
        Assert.Equal("sql,cor,all", string.Join(",", reply.Rules.Select(r => r.Name)));
        Assert.False(string.IsNullOrEmpty(reply.Rules[2].Filter));
    }

    [Fact]
    public async Task SetQueueStatus_UnknownStatus_ReturnsError_AndDoesNotUpdate()
    {
        var admin = new FakeAdmin { Queue = NewQueue("q") };

        var reply = await new EntityOperations(admin).SetQueueStatusAsync(
            new SetQueueStatusRequest { QueueName = "q", Status = "Bogus" });

        Assert.Contains("Unknown status", reply.Error);
        Assert.Null(admin.Updated);
    }

    [Fact]
    public async Task SetQueueStatus_AppliesStatus()
    {
        var admin = new FakeAdmin { Queue = NewQueue("q") };

        var reply = await new EntityOperations(admin).SetQueueStatusAsync(
            new SetQueueStatusRequest { QueueName = "q", Status = "SendDisabled" });

        Assert.Equal(string.Empty, reply.Error);
        Assert.Equal(EntityStatus.SendDisabled, Assert.IsType<QueueProperties>(admin.Updated).Status);
    }

    private static QueueProperties NewQueue(string name) => ServiceBusModelFactory.QueueProperties(
        name: name, lockDuration: TimeSpan.FromMinutes(1), maxSizeInMegabytes: 1024,
        defaultMessageTimeToLive: TimeSpan.FromDays(14), autoDeleteOnIdle: TimeSpan.FromDays(14),
        maxDeliveryCount: 10, duplicateDetectionHistoryTimeWindow: TimeSpan.FromMinutes(10), userMetadata: "");

    // ── fakes ────────────────────────────────────────────────────────────────

    private sealed class FakeAdmin : ServiceBusAdministrationClient
    {
        public bool Fail { get; init; }
        public object? Created { get; private set; }
        public object? Updated { get; private set; }
        public QueueProperties? Queue { get; init; }
        public List<RuleProperties> Rules { get; init; } = [];

        private void ThrowIfFailing()
        {
            if (Fail) throw new InvalidOperationException("boom");
        }

        public override Task<Response<QueueProperties>> CreateQueueAsync(
            CreateQueueOptions options, CancellationToken cancellationToken = default)
        {
            ThrowIfFailing();
            Created = options;
            return Task.FromResult(Response.FromValue(NewQueue(options.Name), new FakeResponse()));
        }

        public override Task<Response<SubscriptionProperties>> CreateSubscriptionAsync(
            CreateSubscriptionOptions options, CancellationToken cancellationToken = default)
        {
            Created = options;
            return Task.FromResult(Response.FromValue<SubscriptionProperties>(null!, new FakeResponse()));
        }

        public override Task<Response<RuleProperties>> CreateRuleAsync(
            string topicName, string subscriptionName, CreateRuleOptions options,
            CancellationToken cancellationToken = default)
        {
            Created = options;
            return Task.FromResult(Response.FromValue(ServiceBusModelFactory.RuleProperties(options.Name, options.Filter, null), new FakeResponse()));
        }

        public override Task<Response<QueueProperties>> GetQueueAsync(
            string name, CancellationToken cancellationToken = default)
            => Task.FromResult(Response.FromValue(Queue!, new FakeResponse()));

        public override Task<Response<QueueProperties>> UpdateQueueAsync(
            QueueProperties queue, CancellationToken cancellationToken = default)
        {
            Updated = queue;
            return Task.FromResult(Response.FromValue(queue, new FakeResponse()));
        }

        public override AsyncPageable<RuleProperties> GetRulesAsync(
            string topicName, string subscriptionName, CancellationToken cancellationToken = default)
            => AsyncPageable<RuleProperties>.FromPages([Page<RuleProperties>.FromValues(Rules, null, new FakeResponse())]);
    }

    private sealed class FakeResponse : Response
    {
        public override int Status => 200;
        public override string ReasonPhrase => "OK";
        public override Stream? ContentStream { get; set; }
        public override string ClientRequestId { get; set; } = "";
        public override void Dispose() { }
        protected override bool TryGetHeader(string name, out string? value) { value = null; return false; }
        protected override bool TryGetHeaderValues(string name, out IEnumerable<string>? values) { values = null; return false; }
        protected override bool ContainsHeader(string name) => false;
        protected override IEnumerable<Azure.Core.HttpHeader> EnumerateHeaders() => [];
    }
}
