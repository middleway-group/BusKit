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

public class BusKitServiceImpl : BusKitService.BusKitServiceBase
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

    public BusKitServiceImpl(PermissionEvaluationEngine permissionEngine)
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

    // ── List Queues ──────────────────────────────────────

    public override async Task<ListQueuesReply> ListQueues(
        ListQueuesRequest request, ServerCallContext context)
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

    public override async Task<ListTopicsReply> ListTopics(
        ListTopicsRequest request, ServerCallContext context)
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

    // ── Update Rule ──────────────────────────────────────

    public override async Task<UpdateRuleReply> UpdateRule(
        UpdateRuleRequest request, ServerCallContext context)
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

    public override async Task<AddRuleReply> AddRule(
        AddRuleRequest request, ServerCallContext context)
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

    public override async Task<DeleteRuleReply> DeleteRule(
        DeleteRuleRequest request, ServerCallContext context)
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

    public override async Task<CreateQueueReply> CreateQueue(
        CreateQueueRequest request, ServerCallContext context)
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

    public override async Task<DeleteQueueReply> DeleteQueue(
        DeleteQueueRequest request, ServerCallContext context)
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

    public override async Task<SetQueueStatusReply> SetQueueStatus(
        SetQueueStatusRequest request, ServerCallContext context)
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

    public override async Task<SetTopicStatusReply> SetTopicStatus(
        SetTopicStatusRequest request, ServerCallContext context)
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

    public override async Task<CreateTopicReply> CreateTopic(
        CreateTopicRequest request, ServerCallContext context)
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

    public override async Task<DeleteTopicReply> DeleteTopic(
        DeleteTopicRequest request, ServerCallContext context)
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

    public override async Task<CreateSubscriptionReply> CreateSubscription(
        CreateSubscriptionRequest request, ServerCallContext context)
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

    public override async Task<DeleteSubscriptionReply> DeleteSubscription(
        DeleteSubscriptionRequest request, ServerCallContext context)
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

    // ── Get Topic Properties ──────────────────────────────

    public override async Task<GetTopicPropertiesReply> GetTopicProperties(
        GetTopicPropertiesRequest request, ServerCallContext context)
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

    // ── Get Topic Metrics (Azure Monitor) ────────────────

    public override async Task<GetTopicMetricsReply> GetTopicMetrics(
        GetTopicMetricsRequest request, ServerCallContext context)
    {
        var reply = new GetTopicMetricsReply();

        if (_azureCredential == null || _subscriptionId == null ||
            _resourceGroup == null || _namespaceName == null)
        {
            reply.Error = "Azure AD connection required for metrics.";
            return reply;
        }

        try
        {
            var resourceId = $"/subscriptions/{_subscriptionId}/resourceGroups/{_resourceGroup}" +
                             $"/providers/Microsoft.ServiceBus/namespaces/{_namespaceName}";

            var hours = Math.Max(1, request.Hours);
            var end   = DateTimeOffset.UtcNow;
            var start = end.AddHours(-hours);

            var granularity = hours switch
            {
                <= 1   => TimeSpan.FromMinutes(1),
                <= 12  => TimeSpan.FromMinutes(5),
                <= 24  => TimeSpan.FromMinutes(15),
                <= 168 => TimeSpan.FromHours(1),
                _      => TimeSpan.FromHours(6),
            };

            var metricsClient = new MetricsQueryClient(_azureCredential);

            var metricNames = new[]
            {
                "IncomingRequests", "SuccessfulRequests", "ServerErrors",
                "UserErrors", "ThrottledRequests",
                "IncomingMessages", "OutgoingMessages",
            };

            var options = new MetricsQueryOptions
            {
                Granularity       = granularity,
                Filter            = $"EntityName eq '{request.TopicName}'",
                TimeRange         = new QueryTimeRange(start, end),
            };
            options.MetricNamespace = "Microsoft.ServiceBus/namespaces";

            var response = await metricsClient.QueryResourceAsync(
                resourceId,
                metricNames,
                options,
                context.CancellationToken);

            foreach (var metric in response.Value.Metrics)
            {
                var series = new MetricSeries { Name = metric.Name };
                foreach (var ts in metric.TimeSeries)
                {
                    foreach (var dp in ts.Values)
                    {
                        if (dp.TimeStamp == default) continue;
                        var val = dp.Total ?? dp.Average ?? dp.Count ?? 0;
                        series.Points.Add(new MetricDataPoint
                        {
                            TimestampUnix = dp.TimeStamp.ToUnixTimeSeconds(),
                            Value         = val,
                        });
                    }
                }
                reply.Series.Add(series);
            }
        }
        catch (Exception ex)
        {
            reply.Error = ex.Message;
        }

        return reply;
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

    // ── Update Subscription TTL ──────────────────────────

    public override async Task<UpdateSubscriptionTtlReply> UpdateSubscriptionTtl(
        UpdateSubscriptionTtlRequest request, ServerCallContext context)
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

        // Azure Service Bus caps a single PeekMessagesAsync call at 250 messages.
        // Paginate using fromSequenceNumber to honour any requested count above that.
        const int azurePageSize = 250;
        int remaining = request.MaxMessages > 0 ? request.MaxMessages : 20;
        long fromSequenceNumber = 0;

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

    public override async Task<DeleteMessageReply> DeleteMessage(
        DeleteMessageRequest request, ServerCallContext context)
    {
        if (_client == null)
            return new DeleteMessageReply { Success = false, Error = "Not connected" };

        var isSubscription = !string.IsNullOrEmpty(request.TopicName)
                          && !string.IsNullOrEmpty(request.SubscriptionName);

        var options = new ServiceBusReceiverOptions
        {
            ReceiveMode = ServiceBusReceiveMode.PeekLock,
            SubQueue = request.DeadLetter ? SubQueue.DeadLetter : SubQueue.None
        };

        var receiver = isSubscription
            ? _client.CreateReceiver(request.TopicName, request.SubscriptionName, options)
            : _client.CreateReceiver(request.QueueName, options);

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
                        maxMessages: 50, maxWaitTime: TimeSpan.FromSeconds(3), context.CancellationToken);
                    if (batch.Count == 0) break;
                    held.AddRange(batch);
                    if (held.Any(m => m.SequenceNumber == request.SequenceNumber))
                        break;
                }

                var target = held.FirstOrDefault(m => m.SequenceNumber == request.SequenceNumber);

                await Task.WhenAll(held
                    .Where(m => m.SequenceNumber != request.SequenceNumber)
                    .Select(m => receiver.AbandonMessageAsync(m, cancellationToken: context.CancellationToken)));

                if (target != null)
                {
                    await receiver.CompleteMessageAsync(target, context.CancellationToken);
                    return new DeleteMessageReply { Success = true };
                }

                return new DeleteMessageReply { Success = false, Error = "Message not found" };
            }
            catch
            {
                foreach (var msg in held)
                {
                    try { await receiver.AbandonMessageAsync(msg, cancellationToken: context.CancellationToken); }
                    catch { /* best-effort release */ }
                }
                throw;
            }
        }
    }

    public override async Task<SendMessageReply> SendMessageExtended(
        SendMessageExtendedRequest request, ServerCallContext context)
    {
        if (_client == null)
            return new SendMessageReply { Success = false };

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
            if (!string.IsNullOrEmpty(request.ReplyTo))     message.ReplyTo     = request.ReplyTo;
            if (!string.IsNullOrEmpty(request.ToAddress))   message.To          = request.ToAddress;
            if (!string.IsNullOrEmpty(request.SessionId))   message.SessionId   = request.SessionId;
            if (!string.IsNullOrEmpty(request.PartitionKey)) message.PartitionKey = request.PartitionKey;
            foreach (var prop in request.Properties)
                message.ApplicationProperties[prop.Key] = prop.Value;

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