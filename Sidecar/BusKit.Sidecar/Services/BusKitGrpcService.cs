using Azure.Identity;
using Azure.Messaging.ServiceBus;
using Azure.Messaging.ServiceBus.Administration;
using Azure.Monitor.Query;
using Azure.Monitor.Query.Models;
using Azure.ResourceManager;
using Azure.ResourceManager.ServiceBus;
using BusKit.Sidecar.Grpc;
using BusKit.Sidecar.Models;
using Grpc.Core;
using Microsoft.Identity.Client;
using GrpcAccessTier = BusKit.Sidecar.Grpc.AccessTier;

namespace BusKit.Sidecar.Services;

public class BusKitGrpcService : BusKitService.BusKitServiceBase
{
    private ServiceBusClient? _client;
    private ServiceBusAdministrationClient? _adminClient;
    private string? _connectionString;
    private Azure.Core.TokenCredential? _azureCredential;
    private string? _userObjectId;
    private IPublicClientApplication? _msalApp;
    private IAccount? _msalAccount;

    // Stored for Azure Monitor queries (set when CheckRbacPermissions is called)
    private string? _subscriptionId;
    private string? _resourceGroup;
    private string? _namespaceName;

    private readonly PermissionEvaluationEngine _permissionEngine;

    public BusKitGrpcService(PermissionEvaluationEngine permissionEngine)
    {
        _permissionEngine = permissionEngine;
    }

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
            _azureCredential = null;
            _userObjectId = null;
            _msalApp = null;
            _msalAccount = null;

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
            _msalApp = msalApp;

            // Prompt.SelectAccount always shows the account picker in the
            // browser — SSO never auto-signs in the previous account.
            var authResult = await msalApp
                .AcquireTokenInteractive(new[] { "https://management.azure.com/.default" })
                .WithPrompt(Prompt.SelectAccount)
                .ExecuteAsync(CancellationToken.None);
            _msalAccount = authResult.Account;

            _azureCredential = new MsalTokenCredential(msalApp, authResult.Account);
            _userObjectId    = authResult.Account.HomeAccountId.ObjectId;

            var armClient = new ArmClient(_azureCredential);

            await foreach (var sub in armClient.GetSubscriptions().GetAllAsync())
            {
                reply.Subscriptions.Add(new AzureSubscriptionInfo
                {
                    SubscriptionId = sub.Data.SubscriptionId,
                    DisplayName = sub.Data.DisplayName ?? sub.Data.SubscriptionId
                });
            }

            await foreach (var tenant in armClient.GetTenants().GetAllAsync())
            {
                var tenantId = tenant.Data.TenantId?.ToString() ?? "";
                var displayName = tenant.Data.DisplayName;
                if (!string.IsNullOrEmpty(tenantId))
                {
                    reply.Tenants.Add(new AzureTenantInfo
                    {
                        TenantId = tenantId,
                        DisplayName = string.IsNullOrEmpty(displayName) ? tenantId : displayName
                    });
                }
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

    public override async Task<SelectAzureTenantReply> SelectAzureTenant(
        SelectAzureTenantRequest request, ServerCallContext context)
    {
        var reply = new SelectAzureTenantReply();
        try
        {
            if (_msalApp == null || _msalAccount == null)
            {
                reply.Error = "Not signed in. Call ListAzureSubscriptions first.";
                return reply;
            }

            AuthenticationResult authResult;
            try
            {
                authResult = await _msalApp
                    .AcquireTokenSilent(new[] { "https://management.azure.com/.default" }, _msalAccount)
                    .WithTenantId(request.TenantId)
                    .ExecuteAsync(CancellationToken.None);
            }
            catch (MsalUiRequiredException)
            {
                authResult = await _msalApp
                    .AcquireTokenInteractive(new[] { "https://management.azure.com/.default" })
                    .WithAccount(_msalAccount)
                    .WithTenantId(request.TenantId)
                    .ExecuteAsync(CancellationToken.None);
            }

            _msalAccount = authResult.Account;
            _azureCredential = new MsalTokenCredential(_msalApp, authResult.Account, request.TenantId);
            _userObjectId    = authResult.Account.HomeAccountId.ObjectId;

            var armClient = new ArmClient(_azureCredential);

            await foreach (var sub in armClient.GetSubscriptions().GetAllAsync())
            {
                reply.Subscriptions.Add(new AzureSubscriptionInfo
                {
                    SubscriptionId = sub.Data.SubscriptionId,
                    DisplayName = sub.Data.DisplayName ?? sub.Data.SubscriptionId
                });
            }

            try
            {
                await _azureCredential.GetTokenAsync(
                    new Azure.Core.TokenRequestContext(new[] { "https://servicebus.azure.net/.default" }),
                    CancellationToken.None);
            }
            catch (Exception warmEx)
            {
                Console.WriteLine($"[BusKit] SB token pre-warm failed: {warmEx.Message}");
            }
        }
        catch (Exception ex)
        {
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

    // ── Check RBAC Permissions ───────────────────────────

    public override async Task<CheckRbacPermissionsReply> CheckRbacPermissions(
        CheckRbacPermissionsRequest request, ServerCallContext context)
    {
        var reply = new CheckRbacPermissionsReply();

        if (_azureCredential == null || string.IsNullOrEmpty(_userObjectId))
        {
            reply.CheckFailed = true;
            reply.Error = "Not signed in to Azure.";
            return reply;
        }

        try
        {
            var tokenCtx = new Azure.Core.TokenRequestContext(
                new[] { "https://management.azure.com/.default" });
            var token = await _azureCredential.GetTokenAsync(tokenCtx, context.CancellationToken);

            // Store for later Azure Monitor queries
            _subscriptionId = request.SubscriptionId;
            _resourceGroup  = request.ResourceGroup;
            _namespaceName  = request.NamespaceName;

            var result = await _permissionEngine.EvaluateAsync(
                request.SubscriptionId,
                request.ResourceGroup,
                request.NamespaceName,
                _userObjectId,
                token.Token,
                context.CancellationToken);

            // ── Tier-based fields ─────────────────────────────────
            reply.AccessTier      = (GrpcAccessTier)result.Tier;
            reply.IsPartialAccess = result.IsPartialAccess;
            reply.TierLabel       = result.TierLabel;

            reply.CanBrowseEntities  = result.Capabilities.BrowseEntities;
            reply.CanViewProperties  = result.Capabilities.ViewProperties;
            reply.CanPeekFetch       = result.Capabilities.PeekFetch;
            reply.CanPurge           = result.Capabilities.Purge;
            reply.CanResubmitDlq     = result.Capabilities.ResubmitDlq;
            reply.CanCreateResources = result.Capabilities.CreateResources;
            reply.CanManageFilters   = result.Capabilities.ManageFilters;

            if (result.UpgradeRecommendation is { } rec)
            {
                reply.RecommendedRoleName        = rec.RoleName;
                reply.RecommendedRoleId          = rec.RoleDefinitionId;
                reply.RecommendedRoleDescription = rec.Description;
                reply.RecommendedTargetTier      = (GrpcAccessTier)rec.TargetTier;
            }

            reply.EvaluatedAtUnixMs = result.EvaluatedAt.ToUnixTimeMilliseconds();
            reply.ExpiresAtUnixMs   = result.ExpiresAt.ToUnixTimeMilliseconds();

            // ── Legacy fields (for backward-compatible UI path) ───
            reply.HasDataOwnerRole   = result.Capabilities.PeekFetch;
            reply.HasContributorRole = result.Capabilities.CreateResources;

            if (result.EvaluationFailed)
            {
                reply.CheckFailed = true;
                reply.Error       = result.ErrorMessage ?? "Permission evaluation failed.";
            }
        }
        catch (Exception ex)
        {
            reply.CheckFailed = true;
            reply.Error       = ex.Message;
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

    private MetricsOperations Metrics => new(_azureCredential, _subscriptionId, _resourceGroup, _namespaceName);

    public override Task<GetTopicMetricsReply> GetTopicMetrics(
        GetTopicMetricsRequest request, ServerCallContext context)
        => Metrics.GetTopicMetricsAsync(request, context.CancellationToken);

    public override Task<GetQueueMetricsReply> GetQueueMetrics(
        GetQueueMetricsRequest request, ServerCallContext context)
        => Metrics.GetQueueMetricsAsync(request, context.CancellationToken);

    // ── Peek / Purge ─────────────────────────────────────

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

    private MessageOperations Messages(ServiceBusClient client) => new(client, _adminClient);


    // ── Send Message ─────────────────────────────────────

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
        private readonly string? _tenantId;

        public MsalTokenCredential(IPublicClientApplication app, IAccount account, string? tenantId = null)
        {
            _app = app;
            _account = account;
            _tenantId = tenantId;
        }

        public override Azure.Core.AccessToken GetToken(
            Azure.Core.TokenRequestContext requestContext, CancellationToken cancellationToken)
            => GetTokenAsync(requestContext, cancellationToken).AsTask().GetAwaiter().GetResult();

        public override async ValueTask<Azure.Core.AccessToken> GetTokenAsync(
            Azure.Core.TokenRequestContext requestContext, CancellationToken cancellationToken)
        {
            try
            {
                var builder = _app.AcquireTokenSilent(requestContext.Scopes, _account);
                if (_tenantId != null)
                    builder = builder.WithTenantId(_tenantId);
                var result = await builder.ExecuteAsync(cancellationToken);
                _account = result.Account;
                return new Azure.Core.AccessToken(result.AccessToken, result.ExpiresOn);
            }
            catch (MsalUiRequiredException)
            {
                var builder = _app.AcquireTokenInteractive(requestContext.Scopes).WithAccount(_account);
                if (_tenantId != null)
                    builder = builder.WithTenantId(_tenantId);
                var result = await builder.ExecuteAsync(cancellationToken);
                _account = result.Account;
                return new Azure.Core.AccessToken(result.AccessToken, result.ExpiresOn);
            }
        }
    }
}