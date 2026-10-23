using Azure.Messaging.ServiceBus.Administration;
using BusKit.Sidecar.Grpc;

namespace BusKit.Sidecar.Services;

/// <summary>
/// Queue, topic, subscription and rule management through the Service Bus administration client.
/// Kept free of gRPC server types so it can be unit tested with a fake admin client.
/// </summary>
public sealed class EntityOperations(ServiceBusAdministrationClient? adminClient)
{
    private readonly ServiceBusAdministrationClient? _adminClient = adminClient;

    // ── List Queues ──────────────────────────────────────

    public async Task<ListQueuesReply> ListQueuesAsync(ListQueuesRequest request)
    {
        var reply = new ListQueuesReply();

        if (_adminClient == null)
            return reply;

        var statusMap = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        await foreach (var q in _adminClient.GetQueuesAsync())
            statusMap[q.Name] = q.Status.ToString();

        await foreach (var queue in _adminClient.GetQueuesRuntimePropertiesAsync())
        {
            reply.Queues.Add(new QueueInfo
            {
                Name = queue.Name,
                MessageCount = queue.ActiveMessageCount,
                DeadLetterCount = queue.DeadLetterMessageCount,
                Status = statusMap.TryGetValue(queue.Name, out var s) ? s : "Active"
            });
        }

        return reply;
    }

    // ── List Topics ──────────────────────────────────────

    public async Task<ListTopicsReply> ListTopicsAsync(ListTopicsRequest request)
    {
        var reply = new ListTopicsReply();

        if (_adminClient == null)
            return reply;

        await foreach (var topic in _adminClient.GetTopicsAsync())
        {
            reply.Topics.Add(new TopicInfo { Name = topic.Name, Status = topic.Status.ToString() });
        }

        return reply;
    }

    // ── List Subscriptions ───────────────────────────────

    public async Task<ListSubscriptionsReply> ListSubscriptionsAsync(ListSubscriptionsRequest request)
    {
        var reply = new ListSubscriptionsReply();

        if (_adminClient == null)
            return reply;

        await foreach (var sub in _adminClient.GetSubscriptionsRuntimePropertiesAsync(request.TopicName))
        {
            reply.Subscriptions.Add(new SubscriptionInfo
            {
                Name = sub.SubscriptionName,
                ActiveMessageCount = sub.ActiveMessageCount,
                DeadLetterCount = sub.DeadLetterMessageCount
            });
        }

        return reply;
    }

    // ── List Rules ───────────────────────────────────────

    public async Task<ListRulesReply> ListRulesAsync(ListRulesRequest request)
    {
        var reply = new ListRulesReply();

        if (_adminClient == null)
            return reply;

        await foreach (var rule in _adminClient.GetRulesAsync(request.TopicName, request.SubscriptionName))
        {
            var filter = rule.Filter switch
            {
                SqlRuleFilter sql => $"SQL: {sql.SqlExpression}",
                CorrelationRuleFilter cor => $"Correlation: {cor.CorrelationId}",
                _ => rule.Filter?.ToString() ?? ""
            };

            reply.Rules.Add(new RuleInfo { Name = rule.Name, Filter = filter });
        }

        return reply;
    }

    // ── Update Rule ──────────────────────────────────────

    public async Task<UpdateRuleReply> UpdateRuleAsync(UpdateRuleRequest request)
    {
        var reply = new UpdateRuleReply();

        if (_adminClient == null)
        {
            reply.Error = "Not connected";
            return reply;
        }

        try
        {
            var ruleResponse = await _adminClient.GetRuleAsync(
                request.TopicName, request.SubscriptionName, request.RuleName);
            var ruleProperties = ruleResponse.Value;
            ruleProperties.Filter = new SqlRuleFilter(request.SqlFilter);
            await _adminClient.UpdateRuleAsync(request.TopicName, request.SubscriptionName, ruleProperties);
        }
        catch (Exception ex)
        {
            reply.Error = ex.Message;
        }

        return reply;
    }

    // ── Add Rule ─────────────────────────────────────────

    public async Task<AddRuleReply> AddRuleAsync(AddRuleRequest request)
    {
        var reply = new AddRuleReply();

        if (_adminClient == null)
        {
            reply.Error = "Not connected";
            return reply;
        }

        try
        {
            var options = new CreateRuleOptions(request.RuleName, new SqlRuleFilter(request.SqlFilter));
            await _adminClient.CreateRuleAsync(request.TopicName, request.SubscriptionName, options);
        }
        catch (Exception ex)
        {
            reply.Error = ex.Message;
        }

        return reply;
    }

    // ── Delete Rule ───────────────────────────────────────

    public async Task<DeleteRuleReply> DeleteRuleAsync(DeleteRuleRequest request)
    {
        var reply = new DeleteRuleReply();

        if (_adminClient == null)
        {
            reply.Error = "Not connected";
            return reply;
        }

        try
        {
            await _adminClient.DeleteRuleAsync(request.TopicName, request.SubscriptionName, request.RuleName);
        }
        catch (Exception ex)
        {
            reply.Error = ex.Message;
        }

        return reply;
    }

    // ── Create Queue ──────────────────────────────────────

    public async Task<CreateQueueReply> CreateQueueAsync(CreateQueueRequest request)
    {
        var reply = new CreateQueueReply();

        if (_adminClient == null)
        {
            reply.Error = "Not connected";
            return reply;
        }

        try
        {
            var options = new Azure.Messaging.ServiceBus.Administration.CreateQueueOptions(request.QueueName)
            {
                MaxSizeInMegabytes = request.MaxSizeMb > 0 ? (long)request.MaxSizeMb : 1024,
                MaxDeliveryCount = request.MaxDeliveryCount > 0 ? (int)request.MaxDeliveryCount : 10,
                DefaultMessageTimeToLive = request.DefaultMessageTtlSeconds > 0
                    ? TimeSpan.FromSeconds(request.DefaultMessageTtlSeconds)
                    : TimeSpan.FromDays(14),
                LockDuration = request.LockDurationSeconds > 0
                    ? TimeSpan.FromSeconds(request.LockDurationSeconds)
                    : TimeSpan.FromMinutes(1),
                RequiresDuplicateDetection = request.RequiresDuplicateDetection,
                RequiresSession = request.RequiresSession,
                DeadLetteringOnMessageExpiration = request.DeadLetteringOnExpiration,
                EnablePartitioning = request.EnablePartitioning,
            };

            if (!string.IsNullOrWhiteSpace(request.ForwardTo))
                options.ForwardTo = request.ForwardTo;

            if (request.AutoDeleteOnIdleSeconds > 0)
                options.AutoDeleteOnIdle = TimeSpan.FromSeconds(request.AutoDeleteOnIdleSeconds);

            await _adminClient.CreateQueueAsync(options);
        }
        catch (Exception ex)
        {
            reply.Error = ex.Message;
        }

        return reply;
    }

    // ── Delete Queue ─────────────────────────────────────

    public async Task<DeleteQueueReply> DeleteQueueAsync(DeleteQueueRequest request)
    {
        var reply = new DeleteQueueReply();
        try
        {
            if (_adminClient == null)
            {
                reply.Error = "Not connected to Service Bus.";
                return reply;
            }
            await _adminClient.DeleteQueueAsync(request.QueueName);
        }
        catch (Exception ex)
        {
            reply.Error = ex.Message;
        }
        return reply;
    }

    // ── Set Queue Status ──────────────────────────────────

    public async Task<SetQueueStatusReply> SetQueueStatusAsync(SetQueueStatusRequest request)
    {
        var reply = new SetQueueStatusReply();
        try
        {
            if (_adminClient == null)
            {
                reply.Error = "Not connected to Service Bus.";
                return reply;
            }

            var props = await _adminClient.GetQueueAsync(request.QueueName);

            props.Value.Status = request.Status switch
            {
                "Active"          => EntityStatus.Active,
                "Disabled"        => EntityStatus.Disabled,
                "SendDisabled"    => EntityStatus.SendDisabled,
                "ReceiveDisabled" => EntityStatus.ReceiveDisabled,
                _ => throw new ArgumentException($"Unknown status: {request.Status}")
            };

            await _adminClient.UpdateQueueAsync(props.Value);
        }
        catch (Exception ex)
        {
            reply.Error = ex.Message;
        }
        return reply;
    }

    // ── Set Topic Status ──────────────────────────────────

    public async Task<SetTopicStatusReply> SetTopicStatusAsync(SetTopicStatusRequest request)
    {
        var reply = new SetTopicStatusReply();
        try
        {
            if (_adminClient == null)
            {
                reply.Error = "Not connected to Service Bus.";
                return reply;
            }

            var props = await _adminClient.GetTopicAsync(request.TopicName);

            props.Value.Status = request.Status switch
            {
                "Active"          => EntityStatus.Active,
                "Disabled"        => EntityStatus.Disabled,
                "SendDisabled"    => EntityStatus.SendDisabled,
                "ReceiveDisabled" => EntityStatus.ReceiveDisabled,
                _ => throw new ArgumentException($"Unknown status: {request.Status}")
            };

            await _adminClient.UpdateTopicAsync(props.Value);
        }
        catch (Exception ex)
        {
            reply.Error = ex.Message;
        }
        return reply;
    }

    // ── Create Topic ─────────────────────────────────────

    public async Task<CreateTopicReply> CreateTopicAsync(CreateTopicRequest request)
    {
        var reply = new CreateTopicReply();

        if (_adminClient == null)
        {
            reply.Error = "Not connected";
            return reply;
        }

        try
        {
            var options = new Azure.Messaging.ServiceBus.Administration.CreateTopicOptions(request.TopicName)
            {
                MaxSizeInMegabytes = request.MaxSizeMb > 0 ? (long)request.MaxSizeMb : 1024,
                DefaultMessageTimeToLive = request.DefaultMessageTtlSeconds > 0
                    ? TimeSpan.FromSeconds(request.DefaultMessageTtlSeconds)
                    : TimeSpan.FromDays(14),
                RequiresDuplicateDetection = request.RequiresDuplicateDetection,
                EnablePartitioning = request.EnablePartitioning,
                SupportOrdering = request.SupportOrdering,
            };

            if (request.AutoDeleteOnIdleSeconds > 0)
                options.AutoDeleteOnIdle = TimeSpan.FromSeconds(request.AutoDeleteOnIdleSeconds);

            await _adminClient.CreateTopicAsync(options);
        }
        catch (Exception ex)
        {
            reply.Error = ex.Message;
        }

        return reply;
    }

    // ── Delete Topic ─────────────────────────────────────

    public async Task<DeleteTopicReply> DeleteTopicAsync(DeleteTopicRequest request)
    {
        var reply = new DeleteTopicReply();
        try
        {
            if (_adminClient == null)
            {
                reply.Error = "Not connected to Service Bus.";
                return reply;
            }
            await _adminClient.DeleteTopicAsync(request.TopicName);
        }
        catch (Exception ex)
        {
            reply.Error = ex.Message;
        }
        return reply;
    }

    // ── Create Subscription ───────────────────────────────

    public async Task<CreateSubscriptionReply> CreateSubscriptionAsync(CreateSubscriptionRequest request)
    {
        var reply = new CreateSubscriptionReply();

        if (_adminClient == null)
        {
            reply.Error = "Not connected";
            return reply;
        }

        try
        {
            var options = new Azure.Messaging.ServiceBus.Administration.CreateSubscriptionOptions(
                request.TopicName, request.SubscriptionName)
            {
                MaxDeliveryCount = request.MaxDeliveryCount > 0 ? request.MaxDeliveryCount : 10,
                DefaultMessageTimeToLive = request.DefaultMessageTtlSeconds > 0
                    ? TimeSpan.FromSeconds(request.DefaultMessageTtlSeconds)
                    : TimeSpan.FromDays(14),
                LockDuration = request.LockDurationSeconds > 0
                    ? TimeSpan.FromSeconds(request.LockDurationSeconds)
                    : TimeSpan.FromMinutes(1),
                RequiresSession = request.EnableSessions,
                DeadLetteringOnMessageExpiration = request.DeadLetteringOnExpiration,
                EnableDeadLetteringOnFilterEvaluationExceptions = request.DeadLetteringOnFilterEvaluation,
            };

            if (!request.NeverAutoDelete && request.AutoDeleteOnIdleSeconds > 0)
                options.AutoDeleteOnIdle = TimeSpan.FromSeconds(request.AutoDeleteOnIdleSeconds);

            if (request.ForwardMessages && !string.IsNullOrWhiteSpace(request.ForwardTo))
                options.ForwardTo = request.ForwardTo.Trim();

            await _adminClient.CreateSubscriptionAsync(options);
        }
        catch (Exception ex)
        {
            reply.Error = ex.Message;
        }

        return reply;
    }

    // ── Delete Subscription ───────────────────────────────

    public async Task<DeleteSubscriptionReply> DeleteSubscriptionAsync(DeleteSubscriptionRequest request)
    {
        var reply = new DeleteSubscriptionReply();

        if (_adminClient == null)
        {
            reply.Error = "Not connected";
            return reply;
        }

        try
        {
            await _adminClient.DeleteSubscriptionAsync(request.TopicName, request.SubscriptionName);
        }
        catch (Exception ex)
        {
            reply.Error = ex.Message;
        }

        return reply;
    }
}
