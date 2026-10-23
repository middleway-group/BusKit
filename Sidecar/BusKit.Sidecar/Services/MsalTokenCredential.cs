using Microsoft.Identity.Client;

namespace BusKit.Sidecar.Services;

// Wraps an already-authenticated MSAL account so that Azure SDK clients
// (ArmClient, ServiceBusClient, etc.) can silently refresh tokens via the
// MSAL refresh-token grant without triggering another browser window.
// Falls back to interactive auth (without forcing account selection) only
// if the refresh token itself has expired.
internal sealed class MsalTokenCredential : Azure.Core.TokenCredential
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
