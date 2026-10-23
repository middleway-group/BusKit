using Azure;
using Azure.Core;
using Azure.Messaging.ServiceBus;
using Azure.Messaging.ServiceBus.Administration;
using BusKit.Sidecar.Grpc;
using BusKit.Sidecar.Services;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Logging.Abstractions;

namespace BusKit.Sidecar.Tests;

public class ConnectionServiceTests
{
    [Fact]
    public async Task Connect_Success_ExposesClients()
    {
        var admin = new FakeAdmin();
        var service = Create(connectionString: _ => (new FakeClient(), admin));

        var reply = await service.ConnectAsync(new ConnectRequest { ConnectionString = "Endpoint=sb://x/" });

        Assert.True(reply.Success);
        Assert.NotNull(service.Client);
        Assert.Same(admin, service.AdminClient);
    }

    [Fact]
    public async Task Connect_FactoryThrows_ReturnsError()
    {
        var service = Create(connectionString: _ => throw new FormatException("bad connection string"));

        var reply = await service.ConnectAsync(new ConnectRequest { ConnectionString = "nope" });

        Assert.False(reply.Success);
        Assert.Equal("bad connection string", reply.Error);
    }

    [Fact]
    public async Task Connect_VerificationFails_ReturnsError()
    {
        var service = Create(connectionString: _ => (new FakeClient(), new FakeAdmin { Fail = true }));

        var reply = await service.ConnectAsync(new ConnectRequest { ConnectionString = "x" });

        Assert.False(reply.Success);
        Assert.Equal("unauthorized", reply.Error);
    }

    [Fact]
    public async Task ConnectWithAzureAD_NotSignedIn_ReturnsError()
    {
        var service = Create();

        var reply = await service.ConnectWithAzureADAsync(
            new ConnectWithAzureADRequest { FullyQualifiedNamespace = "ns.servicebus.windows.net" });

        Assert.False(reply.Success);
        Assert.Contains("Not signed in", reply.Error);
    }

    [Fact]
    public async Task ConnectWithAzureAD_SignedIn_UsesCredentialAndNamespace()
    {
        string? usedNamespace = null;
        TokenCredential? usedCredential = null;
        var cred = new FakeCredential();
        var service = Create(token: (ns, c) =>
        {
            usedNamespace = ns;
            usedCredential = c;
            return (new FakeClient(), new FakeAdmin());
        });
        service.SetSignedIn(cred, "oid");

        var reply = await service.ConnectWithAzureADAsync(
            new ConnectWithAzureADRequest { FullyQualifiedNamespace = "ns.servicebus.windows.net" });

        Assert.True(reply.Success);
        Assert.Equal("ns.servicebus.windows.net", usedNamespace);
        Assert.Same(cred, usedCredential);
    }

    [Fact]
    public async Task Disconnect_ClearsClients_ButKeepsCredential()
    {
        var cred = new FakeCredential();
        var service = Create(connectionString: _ => (new FakeClient(), new FakeAdmin()));
        service.SetSignedIn(cred, "oid");
        await service.ConnectAsync(new ConnectRequest { ConnectionString = "x" });

        var reply = await service.DisconnectAsync();

        Assert.True(reply.Success);
        Assert.Null(service.Client);
        Assert.Null(service.AdminClient);
        Assert.Same(cred, service.AzureCredential);
    }

    [Fact]
    public async Task Disconnect_WhenNotConnected_Succeeds()
    {
        var reply = await Create().DisconnectAsync();
        Assert.True(reply.Success);
    }

    [Fact]
    public async Task ListServiceBusNamespaces_NotSignedIn_ReturnsError()
    {
        var reply = await Create().ListServiceBusNamespacesAsync(
            new ListServiceBusNamespacesRequest { SubscriptionId = "sub" });

        Assert.Contains("Not signed in", reply.Error);
    }

    [Fact]
    public async Task SelectAzureTenant_NotSignedIn_ReturnsError()
    {
        var reply = await Create().SelectAzureTenantAsync(new SelectAzureTenantRequest { TenantId = "t" });

        Assert.Contains("Not signed in", reply.Error);
    }

    [Fact]
    public async Task CheckRbac_NotSignedIn_ReportsFailure()
    {
        var reply = await Create().CheckRbacPermissionsAsync(
            new CheckRbacPermissionsRequest(), CancellationToken.None);

        Assert.True(reply.CheckFailed);
        Assert.Equal("Not signed in to Azure.", reply.Error);
    }

    [Fact]
    public async Task CheckRbac_TokenFailure_ReportsFailure_AndDoesNotStoreNamespace()
    {
        var service = Create();
        service.SetSignedIn(new FakeCredential { Throw = true }, "oid");

        var reply = await service.CheckRbacPermissionsAsync(
            new CheckRbacPermissionsRequest { SubscriptionId = "s", ResourceGroup = "rg", NamespaceName = "ns" },
            CancellationToken.None);

        Assert.True(reply.CheckFailed);
        Assert.Equal("token boom", reply.Error);
        Assert.Null(service.NamespaceName);
    }

    private static ConnectionService Create(
        Func<string, (ServiceBusClient, ServiceBusAdministrationClient)>? connectionString = null,
        Func<string, TokenCredential, (ServiceBusClient, ServiceBusAdministrationClient)>? token = null)
    {
        var engine = new PermissionEvaluationEngine(
            new MemoryCache(new MemoryCacheOptions()),
            new NoHttpFactory(),
            NullLogger<PermissionEvaluationEngine>.Instance);

        return new ConnectionService(
            engine,
            connectionString ?? (_ => throw new InvalidOperationException("unexpected")),
            token ?? ((_, _) => throw new InvalidOperationException("unexpected")));
    }

    private sealed class NoHttpFactory : IHttpClientFactory
    {
        public HttpClient CreateClient(string name) => new();
    }

    private sealed class FakeCredential : TokenCredential
    {
        public bool Throw { get; init; }

        public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken)
            => Throw
                ? throw new InvalidOperationException("token boom")
                : new AccessToken("t", DateTimeOffset.UtcNow.AddHours(1));

        public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext requestContext, CancellationToken cancellationToken)
            => new(GetToken(requestContext, cancellationToken));
    }

    private sealed class FakeClient : ServiceBusClient
    {
        public override ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    private sealed class FakeAdmin : ServiceBusAdministrationClient
    {
        public bool Fail { get; init; }

        public override AsyncPageable<QueueProperties> GetQueuesAsync(CancellationToken cancellationToken = default)
        {
            if (Fail) throw new UnauthorizedAccessException("unauthorized");
            return AsyncPageable<QueueProperties>.FromPages([Page<QueueProperties>.FromValues([], null, null!)]);
        }

        public override AsyncPageable<TopicProperties> GetTopicsAsync(CancellationToken cancellationToken = default)
            => AsyncPageable<TopicProperties>.FromPages([Page<TopicProperties>.FromValues([], null, null!)]);
    }
}
