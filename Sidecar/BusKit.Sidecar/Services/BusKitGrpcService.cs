using Azure.Messaging.ServiceBus;
using BusKit.Sidecar.Grpc;
using Grpc.Core;

namespace BusKit.Sidecar.Services;

public class BusKitGrpcService : BusKitService.BusKitServiceBase
{
    private readonly ConnectionService _connection;

    private ServiceBusClient? _client => _connection.Client;
    private Azure.Messaging.ServiceBus.Administration.ServiceBusAdministrationClient? _adminClient => _connection.AdminClient;

    private readonly Func<ServiceBusClient, string, IMessageProcessor> _processorFactory;

    public BusKitGrpcService(ConnectionService connection)
        : this(connection, static (client, queue) => new ServiceBusMessageProcessor(client.CreateProcessor(queue)))
    {
    }

    internal BusKitGrpcService(
        ConnectionService connection, Func<ServiceBusClient, string, IMessageProcessor> processorFactory)
    {
        _connection = connection;
        _processorFactory = processorFactory;
    }

    // ── Connection & authentication ──────────────────────

    public override Task<ConnectReply> Connect(
        ConnectRequest request, ServerCallContext context)
        => _connection.ConnectAsync(request);

    public override Task<ConnectReply> ConnectWithAzureAD(
        ConnectWithAzureADRequest request, ServerCallContext context)
        => _connection.ConnectWithAzureADAsync(request);

    public override Task<ListAzureSubscriptionsReply> ListAzureSubscriptions(
        ListAzureSubscriptionsRequest request, ServerCallContext context)
        => _connection.ListAzureSubscriptionsAsync();

    public override Task<SelectAzureTenantReply> SelectAzureTenant(
        SelectAzureTenantRequest request, ServerCallContext context)
        => _connection.SelectAzureTenantAsync(request);

    public override Task<ListServiceBusNamespacesReply> ListServiceBusNamespaces(
        ListServiceBusNamespacesRequest request, ServerCallContext context)
        => _connection.ListServiceBusNamespacesAsync(request);

    public override Task<CheckRbacPermissionsReply> CheckRbacPermissions(
        CheckRbacPermissionsRequest request, ServerCallContext context)
        => _connection.CheckRbacPermissionsAsync(request, context.CancellationToken);

    public override Task<DisconnectReply> Disconnect(
        DisconnectRequest request, ServerCallContext context)
        => _connection.DisconnectAsync();

    // ── Entity management (queues, topics, subscriptions, rules) ──

    private EntityOperations Entities => new(_adminClient);

    public override Task<ListQueuesReply> ListQueues(
        ListQueuesRequest request, ServerCallContext context)
        => Entities.ListQueuesAsync(request);

    public override Task<ListTopicsReply> ListTopics(
        ListTopicsRequest request, ServerCallContext context)
        => Entities.ListTopicsAsync(request);

    public override Task<ListSubscriptionsReply> ListSubscriptions(
        ListSubscriptionsRequest request, ServerCallContext context)
        => Entities.ListSubscriptionsAsync(request);

    public override Task<ListRulesReply> ListRules(
        ListRulesRequest request, ServerCallContext context)
        => Entities.ListRulesAsync(request);

    public override Task<UpdateRuleReply> UpdateRule(
        UpdateRuleRequest request, ServerCallContext context)
        => Entities.UpdateRuleAsync(request);

    public override Task<AddRuleReply> AddRule(
        AddRuleRequest request, ServerCallContext context)
        => Entities.AddRuleAsync(request);

    public override Task<DeleteRuleReply> DeleteRule(
        DeleteRuleRequest request, ServerCallContext context)
        => Entities.DeleteRuleAsync(request);

    public override Task<CreateQueueReply> CreateQueue(
        CreateQueueRequest request, ServerCallContext context)
        => Entities.CreateQueueAsync(request);

    public override Task<DeleteQueueReply> DeleteQueue(
        DeleteQueueRequest request, ServerCallContext context)
        => Entities.DeleteQueueAsync(request);

    public override Task<SetQueueStatusReply> SetQueueStatus(
        SetQueueStatusRequest request, ServerCallContext context)
        => Entities.SetQueueStatusAsync(request);

    public override Task<SetTopicStatusReply> SetTopicStatus(
        SetTopicStatusRequest request, ServerCallContext context)
        => Entities.SetTopicStatusAsync(request);

    public override Task<CreateTopicReply> CreateTopic(
        CreateTopicRequest request, ServerCallContext context)
        => Entities.CreateTopicAsync(request);

    public override Task<DeleteTopicReply> DeleteTopic(
        DeleteTopicRequest request, ServerCallContext context)
        => Entities.DeleteTopicAsync(request);

    public override Task<CreateSubscriptionReply> CreateSubscription(
        CreateSubscriptionRequest request, ServerCallContext context)
        => Entities.CreateSubscriptionAsync(request);

    public override Task<DeleteSubscriptionReply> DeleteSubscription(
        DeleteSubscriptionRequest request, ServerCallContext context)
        => Entities.DeleteSubscriptionAsync(request);

    // ── Entity properties ────────────────────────────────

    private EntityPropertiesOperations Properties => new(_adminClient);

    public override Task<GetQueuePropertiesReply> GetQueueProperties(
        GetQueuePropertiesRequest request, ServerCallContext context)
        => Properties.GetQueuePropertiesAsync(request);

    public override Task<GetTopicPropertiesReply> GetTopicProperties(
        GetTopicPropertiesRequest request, ServerCallContext context)
        => Properties.GetTopicPropertiesAsync(request);

    public override Task<GetSubscriptionPropertiesReply> GetSubscriptionProperties(
        GetSubscriptionPropertiesRequest request, ServerCallContext context)
        => Properties.GetSubscriptionPropertiesAsync(request);

    public override Task<UpdateSubscriptionTtlReply> UpdateSubscriptionTtl(
        UpdateSubscriptionTtlRequest request, ServerCallContext context)
        => Properties.UpdateSubscriptionTtlAsync(request);

    // ── Metrics (Azure Monitor) ──────────────────────────

    private MetricsOperations Metrics => new(
        _connection.AzureCredential, _connection.SubscriptionId,
        _connection.ResourceGroup, _connection.NamespaceName);

    public override Task<GetTopicMetricsReply> GetTopicMetrics(
        GetTopicMetricsRequest request, ServerCallContext context)
        => Metrics.GetTopicMetricsAsync(request, context.CancellationToken);

    public override Task<GetQueueMetricsReply> GetQueueMetrics(
        GetQueueMetricsRequest request, ServerCallContext context)
        => Metrics.GetQueueMetricsAsync(request, context.CancellationToken);

    // ── Messages ─────────────────────────────────────────

    private MessageOperations Messages(ServiceBusClient client) => new(client, _adminClient);

    public override Task<PeekMessagesReply> PeekMessages(
        PeekMessagesRequest request, ServerCallContext context)
        => _client is null
            ? Task.FromResult(new PeekMessagesReply())
            : Messages(_client).PeekMessagesAsync(request);

    public override Task<PurgeMessagesReply> PurgeMessages(
        PurgeMessagesRequest request, ServerCallContext context)
        => _client is null
            ? Task.FromResult(new PurgeMessagesReply())
            : Messages(_client).PurgeMessagesAsync(request, context.CancellationToken);

    public override Task<DeleteMessageReply> DeleteMessage(
        DeleteMessageRequest request, ServerCallContext context)
        => _client is null
            ? Task.FromResult(new DeleteMessageReply { Success = false, Error = "Not connected" })
            : Messages(_client).DeleteMessageAsync(request, context.CancellationToken);

    public override Task<DeleteMessagesReply> DeleteMessages(
        DeleteMessagesRequest request, ServerCallContext context)
        => _client is null
            ? Task.FromResult(new DeleteMessagesReply { Error = "Not connected" })
            : Messages(_client).DeleteMessagesAsync(request, context.CancellationToken);

    public override Task<SendMessageReply> SendMessageExtended(
        SendMessageExtendedRequest request, ServerCallContext context)
        => _client is null
            ? Task.FromResult(new SendMessageReply { Success = false })
            : Messages(_client).SendMessageExtendedAsync(request, context.CancellationToken);

    public override async Task<SendMessageReply> SendMessage(
        SendMessageRequest request, ServerCallContext context)
    {
        if (_client == null)
            return new SendMessageReply { Success = false };

        ServiceBusSender? sender = null;
        try
        {
            sender = _client.CreateSender(request.QueueName);
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
                MessageId = message.MessageId ?? string.Empty
            };
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

    // ── Subscribe (Server Streaming) ─────────────────────

    public override async Task SubscribeMessages(
        SubscribeRequest request,
        IServerStreamWriter<BusMessage> responseStream,
        ServerCallContext context)
    {
        if (_client == null) return;

        var processor = _processorFactory(_client, request.QueueName);

        processor.MessageReceived += message => responseStream.WriteAsync(new BusMessage
        {
            MessageId = message.MessageId,
            Body = message.Body,
            ContentType = message.ContentType,
            EnqueuedTimeUnix = message.EnqueuedTimeUnix
        });

        processor.ErrorOccurred += ex =>
        {
            Console.WriteLine($"Error: {ex.Message}");
            return Task.CompletedTask;
        };

        await processor.StartAsync();

        // Wait until client cancels
        try
        {
            await Task.Delay(Timeout.Infinite, context.CancellationToken);
        }
        catch (OperationCanceledException) { }

        await processor.StopAsync();
        await processor.DisposeAsync();
    }
}
