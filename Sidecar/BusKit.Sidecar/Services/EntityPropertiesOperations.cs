using Azure.Messaging.ServiceBus.Administration;
using BusKit.Sidecar.Grpc;

namespace BusKit.Sidecar.Services;

/// <summary>Reads and updates entity properties (queues, topics, subscriptions).</summary>
public sealed class EntityPropertiesOperations(ServiceBusAdministrationClient? adminClient)
{
    private readonly ServiceBusAdministrationClient? _adminClient = adminClient;

    // ── Get Queue Properties ─────────────────────────────

    public async Task<GetQueuePropertiesReply> GetQueuePropertiesAsync(GetQueuePropertiesRequest request)
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
                ScheduledMessageCount = r.ScheduledMessageCount,
                TransferMessageCount = r.TransferMessageCount,
                TransferDeadLetterCount = r.TransferDeadLetterMessageCount,
                MaxMessageSizeBytes = (q.MaxMessageSizeInKilobytes ?? 0) * 1024,
                DuplicateDetectionWindowSeconds = (long)q.DuplicateDetectionHistoryTimeWindow.TotalSeconds,
                UserMetadata = q.UserMetadata ?? "",
                EnablePartitioning = q.EnablePartitioning,
            }
        };
    }

    // ── Get Topic Properties ──────────────────────────────

    public async Task<GetTopicPropertiesReply> GetTopicPropertiesAsync(GetTopicPropertiesRequest request)
    {
        if (_adminClient == null)
            return new GetTopicPropertiesReply();

        var props   = await _adminClient.GetTopicAsync(request.Name);
        var runtime = await _adminClient.GetTopicRuntimePropertiesAsync(request.Name);

        var t = props.Value;
        var r = runtime.Value;

        return new GetTopicPropertiesReply
        {
            Properties = new TopicDetails
            {
                Name                        = t.Name,
                MaxSizeMb                   = t.MaxSizeInMegabytes,
                DefaultMessageTtlSeconds    = (long)t.DefaultMessageTimeToLive.TotalSeconds,
                RequiresDuplicateDetection  = t.RequiresDuplicateDetection,
                SupportOrdering             = t.SupportOrdering,
                EnablePartitioning          = t.EnablePartitioning,
                Status                      = t.Status.ToString(),
                CreatedAtUnix               = r.CreatedAt.ToUnixTimeSeconds(),
                UpdatedAtUnix               = r.UpdatedAt.ToUnixTimeSeconds(),
                ScheduledMessageCount       = r.ScheduledMessageCount,
                SizeBytes                   = r.SizeInBytes,
                MaxMessageSizeBytes         = (t.MaxMessageSizeInKilobytes ?? 0) * 1024,
                AutoDeleteOnIdleSeconds     = (long)t.AutoDeleteOnIdle.TotalSeconds,
                UserMetadata                = t.UserMetadata ?? "",
            }
        };
    }

    // ── Get Subscription Properties ──────────────────────

    public async Task<GetSubscriptionPropertiesReply> GetSubscriptionPropertiesAsync(GetSubscriptionPropertiesRequest request)
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

    // ── Update Subscription TTL ──────────────────────────

    public async Task<UpdateSubscriptionTtlReply> UpdateSubscriptionTtlAsync(UpdateSubscriptionTtlRequest request)
    {
        var reply = new UpdateSubscriptionTtlReply();
        try
        {
            if (_adminClient == null)
            {
                reply.Error = "Not connected.";
                return reply;
            }

            var props = await _adminClient.GetSubscriptionAsync(request.TopicName, request.SubscriptionName);
            var s = props.Value;
            s.DefaultMessageTimeToLive = TimeSpan.FromSeconds(request.DefaultMessageTtlSeconds);
            await _adminClient.UpdateSubscriptionAsync(s);
        }
        catch (Exception ex)
        {
            reply.Error = ex.Message;
        }
        return reply;
    }
}
