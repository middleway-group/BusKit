using Azure.Messaging.ServiceBus;
using Azure.Messaging.ServiceBus.Administration;
using BusKit.Sidecar.Grpc;
using Microsoft.Identity.Client;
using GrpcAccessTier = BusKit.Sidecar.Grpc.AccessTier;

namespace BusKit.Sidecar.Services;

/// <summary>
/// Owns the connection and Azure sign-in state (Service Bus clients, credential,
/// selected namespace) and implements the connect/auth RPC logic.
/// </summary>
public class ConnectionService
{
    private readonly PermissionEvaluationEngine _permissionEngine;
    private readonly Func<string, (ServiceBusClient, ServiceBusAdministrationClient)> _connectionStringFactory;
    private readonly Func<string, Azure.Core.TokenCredential, (ServiceBusClient, ServiceBusAdministrationClient)> _tokenFactory;

    private string? _connectionString;
    private string? _userObjectId;
    private readonly IAzureAuthenticator _authenticator;
    private readonly IAzureResourceCatalog _catalog;
    private AzureSession? _session;

    public ServiceBusClient? Client { get; private set; }
    public ServiceBusAdministrationClient? AdminClient { get; private set; }
    public Azure.Core.TokenCredential? AzureCredential { get; private set; }

    // Stored for Azure Monitor queries (set when CheckRbacPermissions is called)
    public string? SubscriptionId { get; private set; }
    public string? ResourceGroup { get; private set; }
    public string? NamespaceName { get; private set; }

    public ConnectionService(PermissionEvaluationEngine permissionEngine)
        : this(
            permissionEngine,
            cs => (new ServiceBusClient(cs), new ServiceBusAdministrationClient(cs)),
            (fqns, cred) => (new ServiceBusClient(fqns, cred), new ServiceBusAdministrationClient(fqns, cred)))
    {
    }

    internal ConnectionService(
        PermissionEvaluationEngine permissionEngine,
        Func<string, (ServiceBusClient, ServiceBusAdministrationClient)> connectionStringFactory,
        Func<string, Azure.Core.TokenCredential, (ServiceBusClient, ServiceBusAdministrationClient)> tokenFactory,
        IAzureAuthenticator? authenticator = null,
        IAzureResourceCatalog? catalog = null)
    {
        _authenticator = authenticator ?? new MsalAzureAuthenticator();
        _catalog = catalog ?? new ArmResourceCatalog();
        _permissionEngine = permissionEngine;
        _connectionStringFactory = connectionStringFactory;
        _tokenFactory = tokenFactory;
    }

    // Test seam: simulate a completed sign-in.
    internal void SetSignedIn(Azure.Core.TokenCredential credential, string userObjectId)
    {
        AzureCredential = credential;
        _userObjectId = userObjectId;
    }

    // ── Connect (connection string) ───────────────────────

    public async Task<ConnectReply> ConnectAsync(ConnectRequest request)
    {
        try
        {
            _connectionString = request.ConnectionString;
            (Client, AdminClient) = _connectionStringFactory(_connectionString);

            // Verify connectivity by listing queues (one attempt is enough).
            await foreach (var _ in AdminClient.GetQueuesAsync())
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

    public async Task<ConnectReply> ConnectWithAzureADAsync(ConnectWithAzureADRequest request)
    {
        try
        {
            if (AzureCredential == null)
                return new ConnectReply { Success = false, Error = "Not signed in to Azure. Call ListAzureSubscriptions first." };

            _connectionString = null;
            (Client, AdminClient) = _tokenFactory(request.FullyQualifiedNamespace, AzureCredential);
            var client = Client;
            var admin = AdminClient;

            // ── 1. Verify admin (HTTP) connectivity ──────────────────────────
            // Collect the first queue and topic/sub while we're at it so we
            // can warm the AMQP path below.
            string? firstQueue = null;
            string? firstTopic = null;
            string? firstSub   = null;

            await foreach (var q in admin.GetQueuesAsync())
            {
                firstQueue = q.Name;
                break;
            }

            await foreach (var t in admin.GetTopicsAsync())
            {
                firstTopic = t.Name;
                await foreach (var s in admin.GetSubscriptionsAsync(t.Name))
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
                    warmReceiver = client.CreateReceiver(firstQueue);
                else if (firstTopic != null && firstSub != null)
                    warmReceiver = client.CreateReceiver(firstTopic, firstSub);

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

    public async Task<ListAzureSubscriptionsReply> ListAzureSubscriptionsAsync()
    {
        var reply = new ListAzureSubscriptionsReply();
        try
        {
            // Tear down any existing connection so a sign-in always starts clean.
            if (Client != null)
            {
                await Client.DisposeAsync();
                Client = null;
                AdminClient = null;
            }
            _connectionString = null;
            AzureCredential = null;
            _userObjectId = null;
            _session = null;

            _session = await _authenticator.SignInAsync(CancellationToken.None);
            AzureCredential = _session.Credential;
            _userObjectId = _session.UserObjectId;

            await foreach (var sub in _catalog.ListSubscriptionsAsync(AzureCredential))
            {
                reply.Subscriptions.Add(new AzureSubscriptionInfo
                {
                    SubscriptionId = sub.Id,
                    DisplayName = sub.DisplayName
                });
            }

            await foreach (var tenant in _catalog.ListTenantsAsync(AzureCredential))
            {
                if (!string.IsNullOrEmpty(tenant.TenantId))
                {
                    reply.Tenants.Add(new AzureTenantInfo
                    {
                        TenantId = tenant.TenantId,
                        DisplayName = string.IsNullOrEmpty(tenant.DisplayName) ? tenant.TenantId : tenant.DisplayName
                    });
                }
            }

            // Pre-warm the Service Bus token using the refresh token already
            // held by MSAL. On first use this may open a second browser for
            // SB consent; afterwards it is always silent.
            try
            {
                await AzureCredential.GetTokenAsync(
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
                AzureCredential = null;
            reply.Error = ex.Message;
        }
        return reply;
    }

    public async Task<SelectAzureTenantReply> SelectAzureTenantAsync(SelectAzureTenantRequest request)
    {
        var reply = new SelectAzureTenantReply();
        try
        {
            if (_session == null)
            {
                reply.Error = "Not signed in. Call ListAzureSubscriptions first.";
                return reply;
            }

            _session = await _authenticator.SelectTenantAsync(_session, request.TenantId, CancellationToken.None);
            AzureCredential = _session.Credential;
            _userObjectId = _session.UserObjectId;

            await foreach (var sub in _catalog.ListSubscriptionsAsync(AzureCredential))
            {
                reply.Subscriptions.Add(new AzureSubscriptionInfo
                {
                    SubscriptionId = sub.Id,
                    DisplayName = sub.DisplayName
                });
            }

            try
            {
                await AzureCredential.GetTokenAsync(
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

    public async Task<ListServiceBusNamespacesReply> ListServiceBusNamespacesAsync(
        ListServiceBusNamespacesRequest request)
    {
        var reply = new ListServiceBusNamespacesReply();
        try
        {
            if (AzureCredential == null)
            {
                reply.Error = "Not signed in to Azure. Call ListAzureSubscriptions first.";
                return reply;
            }

            await foreach (var ns in _catalog.ListNamespacesAsync(AzureCredential, request.SubscriptionId))
            {
                reply.Namespaces.Add(new ServiceBusNamespaceInfo
                {
                    Name = ns.Name,
                    FullyQualifiedNamespace = $"{ns.Name}.servicebus.windows.net",
                    ResourceGroup = ns.ResourceGroup
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

    public async Task<CheckRbacPermissionsReply> CheckRbacPermissionsAsync(
        CheckRbacPermissionsRequest request, CancellationToken cancellationToken)
    {
        var reply = new CheckRbacPermissionsReply();

        if (AzureCredential == null || string.IsNullOrEmpty(_userObjectId))
        {
            reply.CheckFailed = true;
            reply.Error = "Not signed in to Azure.";
            return reply;
        }

        try
        {
            var tokenCtx = new Azure.Core.TokenRequestContext(
                new[] { "https://management.azure.com/.default" });
            var token = await AzureCredential.GetTokenAsync(tokenCtx, cancellationToken);

            // Store for later Azure Monitor queries
            SubscriptionId = request.SubscriptionId;
            ResourceGroup  = request.ResourceGroup;
            NamespaceName  = request.NamespaceName;

            var result = await _permissionEngine.EvaluateAsync(
                request.SubscriptionId,
                request.ResourceGroup,
                request.NamespaceName,
                _userObjectId,
                token.Token,
                cancellationToken);

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

    public async Task<DisconnectReply> DisconnectAsync()
    {
        if (Client != null)
        {
            await Client.DisposeAsync();
            Client = null;
            AdminClient = null;
        }
        _connectionString = null;
        // Do NOT clear AzureCredential here — authentication state is separate
        // from connection state. Clearing it forces a full re-sign-in just to
        // switch namespaces. It is only cleared when the user explicitly signs out
        // via ListAzureSubscriptions (which resets and re-creates the credential).
        return new DisconnectReply { Success = true };
    }
}
