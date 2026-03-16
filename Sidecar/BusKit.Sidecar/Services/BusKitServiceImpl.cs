using Azure.Messaging.ServiceBus;
using Azure.Messaging.ServiceBus.Administration;
using BusKit.Sidecar.Grpc;
using Grpc.Core;

namespace BusKit.Sidecar.Services;

public class BusKitServiceImpl : BusKitService.BusKitServiceBase
{
    private ServiceBusClient? _client;
    private ServiceBusAdministrationClient? _adminClient;
    private string? _connectionString;

    // ── Connect ──────────────────────────────────────────

    public override async Task<ConnectReply> Connect(
        ConnectRequest request, ServerCallContext context)
    {
        try
        {
            _connectionString = request.ConnectionString;
            _client = new ServiceBusClient(_connectionString);
            _adminClient = new ServiceBusAdministrationClient(_connectionString);

            // Test connection by listing queues
            await foreach (var _ in _adminClient.GetQueuesAsync())
            {
                break; // just need one to confirm
            }

            return new ConnectReply { Success = true };
        }
        catch (Exception ex)
        {
            return new ConnectReply { Success = false, Error = ex.Message };
        }
    }

    // ── Disconnect ───────────────────────────────────────

    public override async Task<DisconnectReply> Disconnect(
        DisconnectRequest request, ServerCallContext context)
    {
        if (_client != null)
        {
            await _client.DisposeAsync();
            _client = null;
            _adminClient = null;
        }
        return new DisconnectReply { Success = true };
    }

    // ── List Queues ──────────────────────────────────────

    public override async Task<ListQueuesReply> ListQueues(
        ListQueuesRequest request, ServerCallContext context)
    {
        var reply = new ListQueuesReply();

        if (_adminClient == null)
            return reply;

        await foreach (var queue in _adminClient.GetQueuesRuntimePropertiesAsync())
        {
            reply.Queues.Add(new QueueInfo
            {
                Name = queue.Name,
                MessageCount = queue.ActiveMessageCount,
                DeadLetterCount = queue.DeadLetterMessageCount
            });
        }

        return reply;
    }

    // ── List Topics ──────────────────────────────────────

    public override async Task<ListTopicsReply> ListTopics(
        ListTopicsRequest request, ServerCallContext context)
    {
        var reply = new ListTopicsReply();

        if (_adminClient == null)
            return reply;

        await foreach (var topic in _adminClient.GetTopicsAsync())
        {
            reply.Topics.Add(new TopicInfo { Name = topic.Name });
        }

        return reply;
    }

    // ── List Subscriptions ───────────────────────────────

    public override async Task<ListSubscriptionsReply> ListSubscriptions(
        ListSubscriptionsRequest request, ServerCallContext context)
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

    public override async Task<ListRulesReply> ListRules(
        ListRulesRequest request, ServerCallContext context)
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

    // ── Get Queue Properties ─────────────────────────────

    public override async Task<GetQueuePropertiesReply> GetQueueProperties(
        GetQueuePropertiesRequest request, ServerCallContext context)
    {
        if (_adminClient == null)
            return new GetQueuePropertiesReply();

        var props = await _adminClient.GetQueueAsync(request.Name);
        var runtime = await _adminClient.GetQueueRuntimePropertiesAsync(request.Name);

        var q = props.Value;
        var r = runtime.Value;

        return new GetQueuePropertiesReply
        {
            Properties = new QueueDetails
            {
                Name = q.Name,
                MaxSizeMb = q.MaxSizeInMegabytes,
                DefaultMessageTtlSeconds = (long)q.DefaultMessageTimeToLive.TotalSeconds,
                LockDurationSeconds = (long)q.LockDuration.TotalSeconds,
                RequiresDuplicateDetection = q.RequiresDuplicateDetection,
                RequiresSession = q.RequiresSession,
                MaxDeliveryCount = q.MaxDeliveryCount,
                DeadLetteringOnExpiration = q.DeadLetteringOnMessageExpiration,
                Status = q.Status.ToString(),
                CreatedAtUnix = r.CreatedAt.ToUnixTimeSeconds(),
                UpdatedAtUnix = r.UpdatedAt.ToUnixTimeSeconds(),
                ActiveMessageCount = r.ActiveMessageCount,
                DeadLetterCount = r.DeadLetterMessageCount,
                SizeBytes = r.SizeInBytes,
                ForwardTo = q.ForwardTo ?? "",
                AutoDeleteOnIdleSeconds = (long)q.AutoDeleteOnIdle.TotalSeconds,
            }
        };
    }

    // ── Get Subscription Properties ──────────────────────

    public override async Task<GetSubscriptionPropertiesReply> GetSubscriptionProperties(
        GetSubscriptionPropertiesRequest request, ServerCallContext context)
    {
        if (_adminClient == null)
            return new GetSubscriptionPropertiesReply();

        var props = await _adminClient.GetSubscriptionAsync(request.TopicName, request.SubscriptionName);
        var runtime = await _adminClient.GetSubscriptionRuntimePropertiesAsync(request.TopicName, request.SubscriptionName);

        var s = props.Value;
        var r = runtime.Value;

        return new GetSubscriptionPropertiesReply
        {
            Properties = new SubscriptionDetails
            {
                TopicName = s.TopicName,
                Name = s.SubscriptionName,
                DefaultMessageTtlSeconds = (long)s.DefaultMessageTimeToLive.TotalSeconds,
                LockDurationSeconds = (long)s.LockDuration.TotalSeconds,
                MaxDeliveryCount = s.MaxDeliveryCount,
                DeadLetteringOnExpiration = s.DeadLetteringOnMessageExpiration,
                DeadLetteringOnFilterEvaluation = s.EnableDeadLetteringOnFilterEvaluationExceptions,
                Status = s.Status.ToString(),
                CreatedAtUnix = r.CreatedAt.ToUnixTimeSeconds(),
                UpdatedAtUnix = r.UpdatedAt.ToUnixTimeSeconds(),
                ActiveMessageCount = r.ActiveMessageCount,
                DeadLetterCount = r.DeadLetterMessageCount,
                ForwardTo = s.ForwardTo ?? "",
                AutoDeleteOnIdleSeconds = (long)s.AutoDeleteOnIdle.TotalSeconds,
            }
        };
    }

    // ── Peek Messages ────────────────────────────────────

    public override async Task<PeekMessagesReply> PeekMessages(
        PeekMessagesRequest request, ServerCallContext context)
    {
        var reply = new PeekMessagesReply();

        if (_client == null)
            return reply;

        var isSubscription = !string.IsNullOrEmpty(request.TopicName)
                          && !string.IsNullOrEmpty(request.SubscriptionName);

        var receiverOptions = new ServiceBusReceiverOptions
        {
            SubQueue = request.DeadLetter ? SubQueue.DeadLetter : SubQueue.None
        };

        var receiver = isSubscription
            ? _client.CreateReceiver(request.TopicName, request.SubscriptionName, receiverOptions)
            : _client.CreateReceiver(request.QueueName, receiverOptions);

        try
        {
            var messages = await receiver.PeekMessagesAsync(
                maxMessages: request.MaxMessages > 0 ? request.MaxMessages : 20);

            foreach (var msg in messages)
            {
                var busMsg = new BusMessage
                {
                    MessageId = msg.MessageId ?? "",
                    Body = msg.Body.ToString(),
                    ContentType = msg.ContentType ?? "",
                    EnqueuedTimeUnix = msg.EnqueuedTime.ToUnixTimeSeconds(),
                    SequenceNumber = msg.SequenceNumber,
                    DeliveryCount = msg.DeliveryCount,
                    ExpiresAtUnix = msg.ExpiresAt.ToUnixTimeSeconds(),
                    Subject = msg.Subject ?? "",
                    CorrelationId = msg.CorrelationId ?? "",
                    ReplyTo = msg.ReplyTo ?? "",
                    ToAddress = msg.To ?? "",
                    SessionId = msg.SessionId ?? "",
                    PartitionKey = msg.PartitionKey ?? "",
                };

                foreach (var prop in msg.ApplicationProperties)
                {
                    busMsg.Properties[prop.Key] = prop.Value?.ToString() ?? "";
                }

                reply.Messages.Add(busMsg);
            }
        }
        finally
        {
            await receiver.DisposeAsync();
        }

        return reply;
    }

    // ── Purge Messages ───────────────────────────────────

    public override async Task<PurgeMessagesReply> PurgeMessages(
        PurgeMessagesRequest request, ServerCallContext context)
    {
        if (_client == null)
            return new PurgeMessagesReply();

        var isSubscription = !string.IsNullOrEmpty(request.TopicName)
                          && !string.IsNullOrEmpty(request.SubscriptionName);

        var options = new ServiceBusReceiverOptions
        {
            ReceiveMode = ServiceBusReceiveMode.ReceiveAndDelete,
            SubQueue = request.DeadLetter ? SubQueue.DeadLetter : SubQueue.None
        };

        var receiver = isSubscription
            ? _client.CreateReceiver(request.TopicName, request.SubscriptionName, options)
            : _client.CreateReceiver(request.QueueName, options);

        await using (receiver)
        {
            int count = 0;
            while (!context.CancellationToken.IsCancellationRequested)
            {
                var batch = await receiver.ReceiveMessagesAsync(100, TimeSpan.FromSeconds(2),
                    context.CancellationToken);
                if (batch.Count == 0) break;
                count += batch.Count;
            }
            return new PurgeMessagesReply { PurgedCount = count };
        }
    }

    // ── Send Message ─────────────────────────────────────

    public override async Task<SendMessageReply> SendMessage(
        SendMessageRequest request, ServerCallContext context)
    {
        if (_client == null)
            return new SendMessageReply { Success = false };

        var sender = _client.CreateSender(request.QueueName);

        try
        {
            var message = new ServiceBusMessage(request.Body)
            {
                ContentType = request.ContentType
            };

            foreach (var prop in request.Properties)
            {
                message.ApplicationProperties[prop.Key] = prop.Value;
            }

            await sender.SendMessageAsync(message);

            return new SendMessageReply
            {
                Success = true,
                MessageId = message.MessageId
            };
        }
        finally
        {
            await sender.DisposeAsync();
        }
    }

    // ── Subscribe (Server Streaming) ─────────────────────

    public override async Task SubscribeMessages(
        SubscribeRequest request,
        IServerStreamWriter<BusMessage> responseStream,
        ServerCallContext context)
    {
        if (_client == null) return;

        var processor = _client.CreateProcessor(request.QueueName);

        processor.ProcessMessageAsync += async args =>
        {
            var busMsg = new BusMessage
            {
                MessageId = args.Message.MessageId ?? "",
                Body = args.Message.Body.ToString(),
                ContentType = args.Message.ContentType ?? "",
                EnqueuedTimeUnix = args.Message.EnqueuedTime.ToUnixTimeSeconds()
            };

            await responseStream.WriteAsync(busMsg);
            await args.CompleteMessageAsync(args.Message);
        };

        processor.ProcessErrorAsync += args =>
        {
            Console.WriteLine($"Error: {args.Exception.Message}");
            return Task.CompletedTask;
        };

        await processor.StartProcessingAsync();

        // Wait until client cancels
        try
        {
            await Task.Delay(Timeout.Infinite, context.CancellationToken);
        }
        catch (OperationCanceledException) { }

        await processor.StopProcessingAsync();
        await processor.DisposeAsync();
    }
}