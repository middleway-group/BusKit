using Microsoft.Identity.Client;

namespace BusKit.Sidecar.Services;

// Wraps an already-authenticated MSAL account so that Azure SDK clients
// (ArmClient, ServiceBusClient, etc.) can silently refresh tokens via the
// MSAL refresh-token grant without triggering another browser window.
// Falls back to interactive auth (without forcing account selection) only
// if the refresh token itself has expired.
internal sealed class MsalTokenCredential : Azure.Core.TokenCredential
{
    private readonly IMsalClient _client;
    private IAccount _account;
    private readonly string? _tenantId;

    public MsalTokenCredential(IMsalClient client, IAccount account, string? tenantId = null)
    {
        _client = client;
        _account = account;
        _tenantId = tenantId;
    }

    public override Azure.Core.AccessToken GetToken(
        Azure.Core.TokenRequestContext requestContext, CancellationToken cancellationToken)
        => GetTokenAsync(requestContext, cancellationToken).AsTask().GetAwaiter().GetResult();

    public override async ValueTask<Azure.Core.AccessToken> GetTokenAsync(
        Azure.Core.TokenRequestContext requestContext, CancellationToken cancellationToken)
    {
        MsalToken token;
        try
        {
            token = await _client.AcquireSilentAsync(requestContext.Scopes, _account, _tenantId, cancellationToken);
        }
        catch (MsalUiRequiredException)
        {
            token = await _client.AcquireInteractiveAsync(
                requestContext.Scopes, _account, _tenantId, false, cancellationToken);
        }

        _account = token.Account;
        return new Azure.Core.AccessToken(token.AccessToken, token.ExpiresOn);
    }
}
