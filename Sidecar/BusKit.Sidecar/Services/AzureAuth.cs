using Azure.ResourceManager;
using Azure.ResourceManager.ServiceBus;
using Microsoft.Identity.Client;

namespace BusKit.Sidecar.Services;

internal sealed record MsalToken(string AccessToken, DateTimeOffset ExpiresOn, IAccount Account);

/// <summary>Thin seam over <see cref="IPublicClientApplication"/>, whose token builders cannot be faked.</summary>
internal interface IMsalClient
{
    /// <summary>Throws <see cref="MsalUiRequiredException"/> when interaction is needed.</summary>
    Task<MsalToken> AcquireSilentAsync(
        IEnumerable<string> scopes, IAccount account, string? tenantId, CancellationToken ct);

    Task<MsalToken> AcquireInteractiveAsync(
        IEnumerable<string> scopes, IAccount? account, string? tenantId, bool selectAccount, CancellationToken ct);
}

internal sealed class MsalClient(IPublicClientApplication app) : IMsalClient
{
    public async Task<MsalToken> AcquireSilentAsync(
        IEnumerable<string> scopes, IAccount account, string? tenantId, CancellationToken ct)
    {
        var builder = app.AcquireTokenSilent(scopes, account);
        if (tenantId != null)
            builder = builder.WithTenantId(tenantId);
        return ToToken(await builder.ExecuteAsync(ct));
    }

    public async Task<MsalToken> AcquireInteractiveAsync(
        IEnumerable<string> scopes, IAccount? account, string? tenantId, bool selectAccount, CancellationToken ct)
    {
        var builder = app.AcquireTokenInteractive(scopes);
        if (selectAccount)
            builder = builder.WithPrompt(Prompt.SelectAccount);
        if (account != null)
            builder = builder.WithAccount(account);
        if (tenantId != null)
            builder = builder.WithTenantId(tenantId);
        return ToToken(await builder.ExecuteAsync(ct));
    }

    private static MsalToken ToToken(AuthenticationResult r) => new(r.AccessToken, r.ExpiresOn, r.Account);
}

internal sealed record AzureSession(
    IMsalClient Client, IAccount Account, Azure.Core.TokenCredential Credential, string UserObjectId);

internal interface IAzureAuthenticator
{
    Task<AzureSession> SignInAsync(CancellationToken ct);
    Task<AzureSession> SelectTenantAsync(AzureSession session, string tenantId, CancellationToken ct);
}

internal sealed class MsalAzureAuthenticator : IAzureAuthenticator
{
    private static readonly string[] ArmScopes = ["https://management.azure.com/.default"];

    public async Task<AzureSession> SignInAsync(CancellationToken ct)
    {
        // A new in-memory app each time means no cached accounts are carried over,
        // so the account picker is always shown and the user can switch accounts freely.
        var app = PublicClientApplicationBuilder
            .Create("04b07795-8ddb-461a-bbee-02f9e1bf7b46") // Azure CLI public client
            .WithAuthority(AzureCloudInstance.AzurePublic,
                           AadAuthorityAudience.AzureAdAndPersonalMicrosoftAccount)
            .WithDefaultRedirectUri()
            .Build();
        var client = new MsalClient(app);

        var token = await client.AcquireInteractiveAsync(ArmScopes, null, null, selectAccount: true, ct);
        return new AzureSession(client, token.Account, new MsalTokenCredential(client, token.Account),
            token.Account.HomeAccountId.ObjectId);
    }

    public async Task<AzureSession> SelectTenantAsync(AzureSession session, string tenantId, CancellationToken ct)
    {
        MsalToken token;
        try
        {
            token = await session.Client.AcquireSilentAsync(ArmScopes, session.Account, tenantId, ct);
        }
        catch (MsalUiRequiredException)
        {
            token = await session.Client.AcquireInteractiveAsync(ArmScopes, session.Account, tenantId, false, ct);
        }

        return new AzureSession(session.Client, token.Account,
            new MsalTokenCredential(session.Client, token.Account, tenantId),
            token.Account.HomeAccountId.ObjectId);
    }
}

internal sealed record SubscriptionEntry(string Id, string DisplayName);
internal sealed record TenantEntry(string TenantId, string? DisplayName);
internal sealed record NamespaceEntry(string Name, string ResourceGroup);

/// <summary>Seam over Azure Resource Manager listing calls.</summary>
internal interface IAzureResourceCatalog
{
    IAsyncEnumerable<SubscriptionEntry> ListSubscriptionsAsync(Azure.Core.TokenCredential credential);
    IAsyncEnumerable<TenantEntry> ListTenantsAsync(Azure.Core.TokenCredential credential);
    IAsyncEnumerable<NamespaceEntry> ListNamespacesAsync(Azure.Core.TokenCredential credential, string subscriptionId);
}

internal sealed class ArmResourceCatalog : IAzureResourceCatalog
{
    public async IAsyncEnumerable<SubscriptionEntry> ListSubscriptionsAsync(Azure.Core.TokenCredential credential)
    {
        await foreach (var sub in new ArmClient(credential).GetSubscriptions().GetAllAsync())
            yield return new SubscriptionEntry(sub.Data.SubscriptionId, sub.Data.DisplayName ?? sub.Data.SubscriptionId);
    }

    public async IAsyncEnumerable<TenantEntry> ListTenantsAsync(Azure.Core.TokenCredential credential)
    {
        await foreach (var tenant in new ArmClient(credential).GetTenants().GetAllAsync())
            yield return new TenantEntry(tenant.Data.TenantId?.ToString() ?? "", tenant.Data.DisplayName);
    }

    public async IAsyncEnumerable<NamespaceEntry> ListNamespacesAsync(
        Azure.Core.TokenCredential credential, string subscriptionId)
    {
        var subscription = new ArmClient(credential)
            .GetSubscriptionResource(new Azure.Core.ResourceIdentifier($"/subscriptions/{subscriptionId}"));
        await foreach (var ns in subscription.GetServiceBusNamespacesAsync())
            yield return new NamespaceEntry(ns.Data.Name, ns.Id.ResourceGroupName ?? "");
    }
}
