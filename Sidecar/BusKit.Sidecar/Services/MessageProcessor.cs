using Azure.Messaging.ServiceBus;

namespace BusKit.Sidecar.Services;

internal sealed record ProcessedMessage(string MessageId, string Body, string ContentType, long EnqueuedTimeUnix);

/// <summary>Seam over <see cref="ServiceBusProcessor"/>, whose events cannot be raised from a fake.</summary>
internal interface IMessageProcessor : IAsyncDisposable
{
    /// <summary>The message is completed once all handlers finish successfully.</summary>
    event Func<ProcessedMessage, Task> MessageReceived;
    event Func<Exception, Task> ErrorOccurred;
    Task StartAsync();
    Task StopAsync();
}

internal sealed class ServiceBusMessageProcessor : IMessageProcessor
{
    private readonly ServiceBusProcessor _processor;

    public ServiceBusMessageProcessor(ServiceBusProcessor processor)
    {
        _processor = processor;

        _processor.ProcessMessageAsync += async args =>
        {
            var m = args.Message;
            var handler = MessageReceived;
            if (handler != null)
            {
                await handler(new ProcessedMessage(
                    m.MessageId ?? "", m.Body.ToString(), m.ContentType ?? "", m.EnqueuedTime.ToUnixTimeSeconds()));
            }
            await args.CompleteMessageAsync(m);
        };

        _processor.ProcessErrorAsync += args => ErrorOccurred?.Invoke(args.Exception) ?? Task.CompletedTask;
    }

    public event Func<ProcessedMessage, Task>? MessageReceived;
    public event Func<Exception, Task>? ErrorOccurred;

    public Task StartAsync() => _processor.StartProcessingAsync();
    public Task StopAsync() => _processor.StopProcessingAsync();
    public ValueTask DisposeAsync() => _processor.DisposeAsync();
}
