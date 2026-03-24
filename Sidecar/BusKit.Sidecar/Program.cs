using BusKit.Sidecar.Services;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddGrpc();
builder.Services.AddMemoryCache();
builder.Services.AddHttpClient(nameof(PermissionEvaluationEngine));
builder.Services.AddSingleton<PermissionEvaluationEngine>();
builder.Services.AddSingleton<BusKitServiceImpl>();

builder.WebHost.ConfigureKestrel(options =>
{
    options.ListenLocalhost(50051, o => o.Protocols =
        Microsoft.AspNetCore.Server.Kestrel.Core.HttpProtocols.Http2);
});

var app = builder.Build();
app.MapGrpcService<BusKitServiceImpl>();

Console.WriteLine("🚀 BusKit Sidecar listening on localhost:50051");
app.Run();
