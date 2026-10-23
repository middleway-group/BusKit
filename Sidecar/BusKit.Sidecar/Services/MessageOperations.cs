using Azure.Messaging.ServiceBus;
using Azure.Messaging.ServiceBus.Administration;
using BusKit.Sidecar.Grpc;

namespace BusKit.Sidecar.Services;

/// <summary>
/// Message-level operations (peek, purge, delete, send) against a connected Service Bus namespace.
/// Kept free of gRPC server types so it can be unit tested with fake <see cref="ServiceBusClient"/>s.
/// </summary>
public sealed class MessageOperations(ServiceBusClient client, ServiceBusAdministrationClient? adminClient)
{
    private readonly ServiceBusClient _client = client;
    private readonly ServiceBusAdministrationClient? _adminClient = adminClient;

    public async Task<PeekMessagesReply> PeekMessagesAsync(PeekMessagesRequest request, CancellationToken ct = default)
    {
        var reply = new PeekMessagesReply();

        var isSubscription = !string.IsNullOrEmpty(request.TopicName)
                          && !string.IsNullOrEmpty(request.SubscriptionName);

        var receiverOptions = new ServiceBusReceiverOptions
        {
            SubQueue = request.DeadLetter ? SubQueue.DeadLetter : SubQueue.None
        };

        var receiver = isSubscription
            ? _client.CreateReceiver(request.TopicName, request.SubscriptionName, receiverOptions)
            : _client.CreateReceiver(request.QueueName, receiverOptions);

        // Azure Service Bus caps a single PeekMessagesAsync call at 250 messages.
        // Paginate using fromSequenceNumber to honour any requested count above that.
        const int azurePageSize = 250;
        int remaining = request.MaxMessages > 0 ? request.MaxMessages : 20;
        long fromSequenceNumber = Math.Max(0, request.FromSequenceNumber);

        try
        {
            while (remaining > 0)
            {
                int batchSize = Math.Min(remaining, azurePageSize);
                var page = await receiver.PeekMessagesAsync(
                    maxMessages: batchSize,
                    fromSequenceNumber: fromSequenceNumber > 0 ? fromSequenceNumber : null);

                if (page.Count == 0)
                    break;

                foreach (var msg in page)
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

                remaining -= page.Count;
                // Next page starts after the highest sequence number we received
                fromSequenceNumber = page.Max(m => m.SequenceNumber) + 1;
            }
        }
        finally
        {
            await receiver.DisposeAsync();
        }

        return reply;
    }

    // ── Purge Messages ───────────────────────────────────

    public async Task<PurgeMessagesReply> PurgeMessagesAsync(PurgeMessagesRequest request, CancellationToken ct = default)
    {

        var isSubscription = !string.IsNullOrEmpty(request.TopicName)
                          && !string.IsNullOrEmpty(request.SubscriptionName);

        // The dead-letter sub-queue is never session-aware, even for a session-enabled
        // queue/subscription, so only check/purge sessions for the main entity.
        var requiresSession = !request.DeadLetter
            && await IsSessionEnabledAsync(isSubscription, request.QueueName, request.TopicName, request.SubscriptionName);

        if (requiresSession)
            return await PurgeSessionEnabledEntity(request, isSubscription, ct);

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
            int consecutiveEmptyBatches = 0;
            while (!ct.IsCancellationRequested)
            {
                try
                {
                    var batch = await receiver.ReceiveMessagesAsync(100, TimeSpan.FromSeconds(2), ct);
                    if (batch.Count == 0)
                    {
                        // A single empty batch doesn't necessarily mean the entity is drained:
                        // partitioned entities can transiently return zero messages from the
                        // partition picked for this receive even though other partitions still
                        // hold plenty of messages. Only stop once several consecutive attempts
                        // come back empty.
                        consecutiveEmptyBatches++;
                        if (consecutiveEmptyBatches >= EmptyBatchesBeforeStop) break;
                        continue;
                    }

                    consecutiveEmptyBatches = 0;
                    count += batch.Count;
                } 
                catch(TaskCanceledException)
                {
                    // Cancel requested from the user, stopping the purge operation
                    await receiver.CloseAsync();
                    break;
                }
            }
            return new PurgeMessagesReply { PurgedCount = count };
        }
    }

    // Number of consecutive empty receive batches required before concluding an entity has
    // been fully drained. Guards against partitioned entities transiently reporting no
    // messages on a given partition while others still have messages pending.
    private const int EmptyBatchesBeforeStop = 5;

    private async Task<bool> IsSessionEnabledAsync(
        bool isSubscription, string queueName, string topicName, string subscriptionName)
    {
        if (_adminClient == null) return false;

        try
        {
            return isSubscription
                ? (await _adminClient.GetSubscriptionAsync(topicName, subscriptionName)).Value.RequiresSession
                : (await _adminClient.GetQueueAsync(queueName)).Value.RequiresSession;
        }
        catch (Exception)
        {
            // Entity metadata could not be retrieved; fall back to a plain receiver.
            return false;
        }
    }

    // Drains every session of a session-enabled queue/subscription, one session at a time,
    // until no more sessions with pending messages are available.
    private async Task<PurgeMessagesReply> PurgeSessionEnabledEntity(
        PurgeMessagesRequest request, bool isSubscription, CancellationToken ct)
    {
        var sessionOptions = new ServiceBusSessionReceiverOptions
        {
            ReceiveMode = ServiceBusReceiveMode.ReceiveAndDelete
        };

        int count = 0;
        while (!ct.IsCancellationRequested)
        {
            ServiceBusSessionReceiver sessionReceiver;
            try
            {
                sessionReceiver = isSubscription
                    ? await _client.AcceptNextSessionAsync(request.TopicName, request.SubscriptionName, sessionOptions, ct)
                    : await _client.AcceptNextSessionAsync(request.QueueName, sessionOptions, ct);
            }
            catch (ServiceBusException ex) when (ex.Reason == ServiceBusFailureReason.ServiceTimeout)
            {
                break; // No more sessions with pending messages.
            }

            await using (sessionReceiver)
            {
                while (true)
                {
                    var batch = await sessionReceiver.ReceiveMessagesAsync(1000, TimeSpan.FromSeconds(2),
                        ct);
                    if (batch.Count == 0) break;
                    count += batch.Count;
                }
            }
        }

        return new PurgeMessagesReply { PurgedCount = count };
    }


    public async Task<DeleteMessageReply> DeleteMessageAsync(DeleteMessageRequest request, CancellationToken ct = default)
    {

        var isSubscription = !string.IsNullOrEmpty(request.TopicName)
                          && !string.IsNullOrEmpty(request.SubscriptionName);

        // The dead-letter sub-queue is never session-aware, even for a session-enabled
        // queue/subscription, so only use a session receiver for the main entity.
        var useSessionReceiver = !request.DeadLetter && !string.IsNullOrEmpty(request.SessionId);

        ServiceBusReceiver receiver;
        try
        {
            if (useSessionReceiver)
            {
                var sessionOptions = new ServiceBusSessionReceiverOptions
                {
                    ReceiveMode = ServiceBusReceiveMode.PeekLock
                };

                receiver = isSubscription
                    ? await _client.AcceptSessionAsync(request.TopicName, request.SubscriptionName, request.SessionId, sessionOptions, ct)
                    : await _client.AcceptSessionAsync(request.QueueName, request.SessionId, sessionOptions, ct);
            }
            else
            {
                var options = new ServiceBusReceiverOptions
                {
                    ReceiveMode = ServiceBusReceiveMode.PeekLock,
                    SubQueue = request.DeadLetter ? SubQueue.DeadLetter : SubQueue.None
                };

                receiver = isSubscription
                    ? _client.CreateReceiver(request.TopicName, request.SubscriptionName, options)
                    : _client.CreateReceiver(request.QueueName, options);
            }
        }
        catch (ServiceBusException ex)
        {
            return new DeleteMessageReply { Success = false, Error = ex.Message };
        }

        await using (receiver)
        {
            // Accumulate all received messages while keeping their locks held.
            // Abandoning inside the loop would immediately return messages to the queue,
            // causing the next receive to re-fetch the same messages and spin indefinitely.
            var held = new List<ServiceBusReceivedMessage>();
            try
            {
                while (true)
                {
                    var batch = await receiver.ReceiveMessagesAsync(
                        maxMessages: 50, maxWaitTime: TimeSpan.FromSeconds(3), ct);
                    if (batch.Count == 0) break;
                    held.AddRange(batch);
                    if (held.Any(m => m.SequenceNumber == request.SequenceNumber))
                        break;
                }

                var target = held.FirstOrDefault(m => m.SequenceNumber == request.SequenceNumber);

                await Task.WhenAll(held
                    .Where(m => m.SequenceNumber != request.SequenceNumber)
                    .Select(m => receiver.AbandonMessageAsync(m, cancellationToken: ct)));

                if (target != null)
                {
                    await receiver.CompleteMessageAsync(target, ct);
                    return new DeleteMessageReply { Success = true };
                }

                return new DeleteMessageReply { Success = false, Error = "Message not found" };
            }
            catch
            {
                foreach (var msg in held)
                {
                    try { await receiver.AbandonMessageAsync(msg, cancellationToken: ct); }
                    catch { /* best-effort release */ }
                }
                throw;
            }
        }
    }

    public async Task<DeleteMessagesReply> DeleteMessagesAsync(DeleteMessagesRequest request, CancellationToken ct = default)
    {

        var remaining = new HashSet<long>(request.SequenceNumbers);
        var reply = new DeleteMessagesReply();
        if (remaining.Count == 0) return reply;

        var options = new ServiceBusReceiverOptions
        {
            ReceiveMode = ServiceBusReceiveMode.PeekLock,
            PrefetchCount = 500,
            SubQueue = request.DeadLetter ? SubQueue.DeadLetter : SubQueue.None
        };
        var isSubscription = !string.IsNullOrEmpty(request.TopicName)
                          && !string.IsNullOrEmpty(request.SubscriptionName);

        // Non-matching messages stay locked until the scan ends; abandoning them
        // earlier would just make the next receive return them again.
        var skipped = new List<ServiceBusReceivedMessage>();
        try
        {
            await using var receiver = isSubscription
                ? _client.CreateReceiver(request.TopicName, request.SubscriptionName, options)
                : _client.CreateReceiver(request.QueueName, options);

            try
            {
                while (remaining.Count > 0)
                {
                    var batch = await receiver.ReceiveMessagesAsync(
                        maxMessages: 500, maxWaitTime: TimeSpan.FromSeconds(3), ct);
                    if (batch.Count == 0) break;

                    foreach (var msg in batch)
                    {
                        if (remaining.Remove(msg.SequenceNumber))
                        {
                            await receiver.CompleteMessageAsync(msg, ct);
                            reply.DeletedCount++;
                        }
                        else
                        {
                            skipped.Add(msg);
                        }
                    }
                }
            }
            finally
            {
                foreach (var msg in skipped)
                {
                    try { await receiver.AbandonMessageAsync(msg); }
                    catch { /* best-effort release */ }
                }
            }
        }
        catch (Exception ex) when (ex is ServiceBusException or InvalidOperationException)
        {
            reply.Error = ex.Message;
        }

        reply.NotFoundSequenceNumbers.AddRange(remaining);
        return reply;
    }

    public async Task<SendMessageReply> SendMessageExtendedAsync(SendMessageExtendedRequest request, CancellationToken ct = default)
    {

        ServiceBusSender? sender = null;
        try
        {
            sender = _client.CreateSender(request.QueueOrTopic);
            var message = new ServiceBusMessage(request.Body)
            {
                ContentType  = string.IsNullOrEmpty(request.ContentType)  ? null : request.ContentType,
                Subject      = string.IsNullOrEmpty(request.Subject)      ? null : request.Subject,
                CorrelationId = string.IsNullOrEmpty(request.CorrelationId) ? null : request.CorrelationId,
            };
            if (!string.IsNullOrEmpty(request.ReplyTo))      message.ReplyTo      = request.ReplyTo;
            if (!string.IsNullOrEmpty(request.ToAddress))    message.To           = request.ToAddress;
            if (!string.IsNullOrEmpty(request.SessionId))    message.SessionId    = request.SessionId;
            if (!string.IsNullOrEmpty(request.PartitionKey)) message.PartitionKey = request.PartitionKey;
            if (!string.IsNullOrEmpty(request.MessageId))    message.MessageId    = request.MessageId;

            // Apply custom application properties, intercepting reserved BusKit keys
            // that map to broker-level ServiceBusMessage properties.
            foreach (var prop in request.Properties)
            {
                if (prop.Key == "x-buskit-ttl-seconds" &&
                    long.TryParse(prop.Value, out var ttlSeconds) && ttlSeconds > 0)
                {
                    message.TimeToLive = TimeSpan.FromSeconds(ttlSeconds);
                }
                else if (prop.Key == "x-buskit-scheduled-enqueue-time-unix" &&
                         long.TryParse(prop.Value, out var unixSeconds))
                {
                    message.ScheduledEnqueueTime = DateTimeOffset.FromUnixTimeSeconds(unixSeconds);
                }
                else
                {
                    message.ApplicationProperties[prop.Key] = prop.Value;
                }
            }

            await sender.SendMessageAsync(message);
            return new SendMessageReply { Success = true, MessageId = message.MessageId ?? string.Empty };
        }
        catch (Exception ex)
        {
            return new SendMessageReply { Success = false, Error = ex.Message ?? string.Empty };
        }
        finally
        {
            if (sender != null)
                _ = sender.DisposeAsync().AsTask().ContinueWith(static _ => { });
        }
    }
}
