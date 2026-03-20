using Azure.Identity;
using Azure.Messaging.ServiceBus;
using Azure.Messaging.ServiceBus.Administration;
using Azure.ResourceManager;
using Azure.ResourceManager.ServiceBus;
using BusKit.Sidecar.Grpc;
using Grpc.Core;
using Microsoft.Identity.Client;

namespace BusKit.Sidecar.Services;

public class BusKitServiceImpl : BusKitService.BusKitServiceBase
{
    private ServiceBusClient? _client;
    private ServiceBusAdministrationClient? _adminClient;
    private string? _connectionString;
    private Azure.Core.TokenCredential? _azureCredential;

    // ── Connect (connection string) ───────────────────────

    public override async Task<ConnectReply> Connect(
        ConnectRequest request, ServerCallContext context)
    {
        try
        {
            _connectionString = request.ConnectionString;
            _client = new ServiceBusClient(_connectionString);
            _adminClient = new ServiceBusAdministrationClient(_connectionString);

            // Verify connectivity by listing queues (one attempt is enough).
            await foreach (var _ in _adminClient.GetQueuesAsync())
            {
                break;
            }

            return new ConnectReply { Success = true };
        }
        catch (Exception ex)
        {
            return new ConnectReply { Success = false, Error = ex.Message };
        }
    }

    // ── Connect with Azure AD (RBAC) ─────────────────────

    public override async Task<ConnectReply> ConnectWithAzureAD(
        ConnectWithAzureADRequest request, ServerCallContext context)
    {
        try
        {
            if (_azureCredential == null)
                return new ConnectReply { Success = false, Error = "Not signed in to Azure. Call ListAzureSubscriptions first." };

            var fqns = request.FullyQualifiedNamespace;
            _connectionString = null;
            _client = new ServiceBusClient(fqns, _azureCredential);
            _adminClient = new ServiceBusAdministrationClient(fqns, _azureCredential);

            // ── 1. Verify admin (HTTP) connectivity ──────────────────────────
            // Collect the first queue and topic/sub while we're at it so we
            // can warm the AMQP path below.
            string? firstQueue = null;
            string? firstTopic = null;
            string? firstSub   = null;

            await foreach (var q in _adminClient.GetQueuesAsync())
            {
                firstQueue = q.Name;
                break;
            }

            await foreach (var t in _adminClient.GetTopicsAsync())
            {
                firstTopic = t.Name;
                await foreach (var s in _adminClient.GetSubscriptionsAsync(t.Name))
                {
                    firstSub = s.SubscriptionName;
                    break;
                }
                break;
            }

            // ── 2. Warm the AMQP messaging token (ServiceBusClient) ──────────
            // The HTTP admin path above primes the BearerTokenAuthenticationPolicy
            // cache, but ServiceBusClient uses a separate AMQP CBS connection that
            // acquires its token lazily on first use. Without this warm-up, the
            // very first PeekMessages/receive call would trigger an interactive
            // browser auth at an unexpected moment (e.g. Dead Letter tab).
            //
            // We force the AMQP connection to establish right here, during the
            // explicit "Connect" step where a browser prompt is acceptable.
            try
            {
                ServiceBusReceiver? warmReceiver = null;

                if (firstQueue != null)
                    warmReceiver = _client.CreateReceiver(firstQueue);
                else if (firstTopic != null && firstSub != null)
                    warmReceiver = _client.CreateReceiver(firstTopic, firstSub);

                if (warmReceiver != null)
                {
                    await using (warmReceiver)
                    {
                        await warmReceiver.PeekMessagesAsync(1, cancellationToken: CancellationToken.None);
                    }
                }
            }
            catch
            {
                // Non-fatal: the AMQP warm-up may fail if the entity has no
                // messages or if RBAC doesn't allow peek. The token is still
                // cached in MSAL from the attempt.
            }

            return new ConnectReply { Success = true };
        }
        catch (Exception ex)
        {
            return new ConnectReply { Success = false, Error = ex.Message };
        }
    }

    // ── List Azure Subscriptions (triggers browser login if not yet signed in) ─

    public override async Task<ListAzureSubscriptionsReply> ListAzureSubscriptions(
        ListAzureSubscriptionsRequest request, ServerCallContext context)
    {
        var reply = new ListAzureSubscriptionsReply();
        try
        {
            // Tear down any existing connection so a sign-in always starts clean.
            if (_client != null)
            {
                await _client.DisposeAsync();
                _client = null;
                _adminClient = null;
            }
            _connectionString = null;

            // Build a fresh MSAL public client with an in-memory cache.
            // A new instance every time means no cached accounts are carried
            // over, so the account picker is always shown regardless of any
            // prior sign-in — the user can switch accounts freely.
            var msalApp = PublicClientApplicationBuilder
                .Create("04b07795-8ddb-461a-bbee-02f9e1bf7b46") // Azure CLI public client
                .WithAuthority(AzureCloudInstance.AzurePublic,
                               AadAuthorityAudience.AzureAdAndPersonalMicrosoftAccount)
                .WithDefaultRedirectUri()
                .Build();

            // Prompt.SelectAccount always shows the account picker in the
            // browser — SSO never auto-signs in the previous account.
            var authResult = await msalApp
                .AcquireTokenInteractive(new[] { "https://management.azure.com/.default" })
                .WithPrompt(Prompt.SelectAccount)
                .ExecuteAsync(CancellationToken.None);

            _azureCredential = new MsalTokenCredential(msalApp, authResult.Account);

            var armClient = new ArmClient(_azureCredential);

            await foreach (var sub in armClient.GetSubscriptions().GetAllAsync())
            {
                reply.Subscriptions.Add(new AzureSubscriptionInfo
                {
                    SubscriptionId = sub.Data.SubscriptionId,
                    DisplayName = sub.Data.DisplayName ?? sub.Data.SubscriptionId
                });
            }

            // Pre-warm the Service Bus token using the refresh token already
            // held by MSAL. On first use this may open a second browser for
            // SB consent; afterwards it is always silent.
            try
            {
                await _azureCredential.GetTokenAsync(
                    new Azure.Core.TokenRequestContext(
                        new[] { "https://servicebus.azure.net/.default" }),
                    CancellationToken.None);
            }
            catch (Exception warmEx)
            {
                Console.WriteLine($"[BusKit] SB token pre-warm failed: {warmEx.Message}");
            }
        }
        catch (Exception ex)
        {
            if (reply.Subscriptions.Count == 0)
                _azureCredential = null;
            reply.Error = ex.Message;
        }
        return reply;
    }

    // ── List Service Bus Namespaces ───────────────────────

    public override async Task<ListServiceBusNamespacesReply> ListServiceBusNamespaces(
        ListServiceBusNamespacesRequest request, ServerCallContext context)
    {
        var reply = new ListServiceBusNamespacesReply();
        try
        {
            if (_azureCredential == null)
            {
                reply.Error = "Not signed in to Azure. Call ListAzureSubscriptions first.";
                return reply;
            }

            var armClient = new ArmClient(_azureCredential);
            var subscriptionId = new Azure.Core.ResourceIdentifier($"/subscriptions/{request.SubscriptionId}");
            var subscription = armClient.GetSubscriptionResource(subscriptionId);

            await foreach (var ns in subscription.GetServiceBusNamespacesAsync())
            {
                var fqns = $"{ns.Data.Name}.servicebus.windows.net";
                var resourceGroup = ns.Id.ResourceGroupName ?? "";
                reply.Namespaces.Add(new ServiceBusNamespaceInfo
                {
                    Name = ns.Data.Name,
                    FullyQualifiedNamespace = fqns,
                    ResourceGroup = resourceGroup
                });
            }
        }
        catch (Exception ex)
        {
            reply.Error = ex.Message;
        }
        return reply;
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
        _connectionString = null;
        // Do NOT clear _azureCredential here — authentication state is separate
        // from connection state. Clearing it forces a full re-sign-in just to
        // switch namespaces. It is only cleared when the user explicitly signs out
        // via ListAzureSubscriptions (which resets and re-creates the credential).
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

    // ── MSAL token credential wrapper ────────────────────
    // Wraps an already-authenticated MSAL account so that Azure SDK clients
    // (ArmClient, ServiceBusClient, etc.) can silently refresh tokens via the
    // MSAL refresh-token grant without triggering another browser window.
    // Falls back to interactive auth (without forcing account selection) only
    // if the refresh token itself has expired.

    private sealed class MsalTokenCredential : Azure.Core.TokenCredential
    {
        private readonly IPublicClientApplication _app;
        private IAccount _account;

        public MsalTokenCredential(IPublicClientApplication app, IAccount account)
        {
            _app = app;
            _account = account;
        }

        public override Azure.Core.AccessToken GetToken(
            Azure.Core.TokenRequestContext requestContext, CancellationToken cancellationToken)
            => GetTokenAsync(requestContext, cancellationToken).AsTask().GetAwaiter().GetResult();

        public override async ValueTask<Azure.Core.AccessToken> GetTokenAsync(
            Azure.Core.TokenRequestContext requestContext, CancellationToken cancellationToken)
        {
            try
            {
                var result = await _app
                    .AcquireTokenSilent(requestContext.Scopes, _account)
                    .ExecuteAsync(cancellationToken);
                _account = result.Account;
                return new Azure.Core.AccessToken(result.AccessToken, result.ExpiresOn);
            }
            catch (MsalUiRequiredException)
            {
                // Refresh token expired — go interactive with the known account
                // (no Prompt.SelectAccount here; this is a background refresh).
                var result = await _app
                    .AcquireTokenInteractive(requestContext.Scopes)
                    .WithAccount(_account)
                    .ExecuteAsync(cancellationToken);
                _account = result.Account;
                return new Azure.Core.AccessToken(result.AccessToken, result.ExpiresOn);
            }
        }
    }
}