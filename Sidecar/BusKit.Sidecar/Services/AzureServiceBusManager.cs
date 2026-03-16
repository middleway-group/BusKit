using Azure.Messaging.ServiceBus;
using Azure.Messaging.ServiceBus.Administration;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;

namespace BusKit.Sidecar.Services;

public class AzureServiceBusManager : IDisposable
{
    private ServiceBusClient? _client;
    private ServiceBusAdministrationClient? _adminClient;
    private string? _namespaceName;

    public bool IsConnected => _client != null;
    public string? NamespaceName => _namespaceName;

    public Task ConnectAsync(string connectionString)
    {
        Disconnect();
        _client = new ServiceBusClient(connectionString);
        _adminClient = new ServiceBusAdministrationClient(connectionString);
        
        // Extract namespace from connection string
        var parts = connectionString.Split(';')
            .Select(p => p.Split('=', 2))
            .Where(p => p.Length == 2)
            .ToDictionary(p => p[0].Trim(), p => p[1].Trim(), 
                          StringComparer.OrdinalIgnoreCase);
        
        if (parts.TryGetValue("Endpoint", out var endpoint))
        {
            _namespaceName = new Uri(endpoint).Host.Split('.')[0];
        }
        
        return Task.CompletedTask;
    }

    public void Disconnect()
    {
        _client?.DisposeAsync().AsTask().Wait();
        _client = null;
        _adminClient = null;
        _namespaceName = null;
    }

    public async IAsyncEnumerable<QueueProperties> ListQueuesAsync()
    {
        EnsureConnected();
        await foreach (var queue in _adminClient!.GetQueuesAsync())
        {
            yield return queue;
        }
    }

    public async IAsyncEnumerable<TopicProperties> ListTopicsAsync()
    {
        EnsureConnected();
        await foreach (var topic in _adminClient!.GetTopicsAsync())
        {
            yield return topic;
        }
    }

    public async IAsyncEnumerable<SubscriptionProperties> ListSubscriptionsAsync(
        string topicName)
    {
        EnsureConnected();
        await foreach (var sub in _adminClient!.GetSubscriptionsAsync(topicName))
        {
            yield return sub;
        }
    }

    public async Task<IReadOnlyList<ServiceBusReceivedMessage>> PeekMessagesAsync(
        string entityPath, 
        int maxMessages = 50, 
        long fromSequenceNumber = 0,
        bool deadLetter = false)
    {
        EnsureConnected();
        
        var options = new ServiceBusReceiverOptions
        {
            SubQueue = deadLetter ? SubQueue.DeadLetter : SubQueue.None
        };
        
        await using var receiver = _client!.CreateReceiver(entityPath, options);
        
        return fromSequenceNumber > 0
            ? await receiver.PeekMessagesAsync(maxMessages, fromSequenceNumber)
            : await receiver.PeekMessagesAsync(maxMessages);
    }

    public async Task<IReadOnlyList<ServiceBusReceivedMessage>> PeekSubscriptionMessagesAsync(
        string topicName, string subscriptionName,
        int maxMessages = 50, long fromSequenceNumber = 0,
        bool deadLetter = false)
    {
        EnsureConnected();
        
        var options = new ServiceBusReceiverOptions
        {
            SubQueue = deadLetter ? SubQueue.DeadLetter : SubQueue.None
        };
        
        await using var receiver = _client!.CreateReceiver(
            topicName, subscriptionName, options);
        
        return fromSequenceNumber > 0
            ? await receiver.PeekMessagesAsync(maxMessages, fromSequenceNumber)
            : await receiver.PeekMessagesAsync(maxMessages);
    }

    public async Task ResubmitMessageAsync(
        string sourceEntity, string? topicName, string? subscriptionName,
        bool fromDeadLetter, long sequenceNumber,
        string? destinationEntity, string? destinationTopic,
        IDictionary<string, string>? modifiedProperties = null,
        string? modifiedBody = null)
    {
        EnsureConnected();

        // Receive (destructive) the specific message
        var receiverOptions = new ServiceBusReceiverOptions
        {
            SubQueue = fromDeadLetter ? SubQueue.DeadLetter : SubQueue.None,
            ReceiveMode = ServiceBusReceiveMode.PeekLock
        };

        ServiceBusReceiver receiver;
        if (!string.IsNullOrEmpty(topicName) && !string.IsNullOrEmpty(subscriptionName))
            receiver = _client!.CreateReceiver(topicName, subscriptionName, receiverOptions);
        else
            receiver = _client!.CreateReceiver(sourceEntity, receiverOptions);

        await using (receiver)
        {
            // Receive messages and find the one with matching sequence number
            var messages = await receiver.ReceiveMessagesAsync(100, TimeSpan.FromSeconds(5));
            var target = messages.FirstOrDefault(m => m.SequenceNumber == sequenceNumber);

            if (target == null)
                throw new InvalidOperationException(
                    $"Message with sequence number {sequenceNumber} not found");

            // Create new message
            var newMessage = new ServiceBusMessage(
                modifiedBody != null 
                    ? BinaryData.FromString(modifiedBody) 
                    : target.Body)
            {
                ContentType = target.ContentType,
                Subject = target.Subject,
                CorrelationId = target.CorrelationId,
                MessageId = Guid.NewGuid().ToString(),
            };

            // Copy application properties
            foreach (var prop in target.ApplicationProperties)
            {
                newMessage.ApplicationProperties[prop.Key] = prop.Value;
            }

            // Apply modifications
            if (modifiedProperties != null)
            {
                foreach (var prop in modifiedProperties)
                {
                    newMessage.ApplicationProperties[prop.Key] = prop.Value;
                }
            }

            // Send to destination
            var dest = !string.IsNullOrEmpty(destinationTopic) 
                ? destinationTopic 
                : !string.IsNullOrEmpty(destinationEntity) 
                    ? destinationEntity 
                    : sourceEntity;

            await using var sender = _client!.CreateSender(dest);
            await sender.SendMessageAsync(newMessage);

            // Complete the original message (removes from DLQ/queue)
            await receiver.CompleteMessageAsync(target);
        }
    }

    public async Task DeleteMessageAsync(
        string queueName, string? topicName, string? subscriptionName,
        bool fromDeadLetter, long sequenceNumber)
    {
        EnsureConnected();

        var options = new ServiceBusReceiverOptions
        {
            SubQueue = fromDeadLetter ? SubQueue.DeadLetter : SubQueue.None,
            ReceiveMode = ServiceBusReceiveMode.PeekLock
        };

        ServiceBusReceiver receiver;
        if (!string.IsNullOrEmpty(topicName) && !string.IsNullOrEmpty(subscriptionName))
            receiver = _client!.CreateReceiver(topicName, subscriptionName, options);
        else
            receiver = _client!.CreateReceiver(queueName, options);

        await using (receiver)
        {
            var messages = await receiver.ReceiveMessagesAsync(100, TimeSpan.FromSeconds(5));
            var target = messages.FirstOrDefault(m => m.SequenceNumber == sequenceNumber);

            if (target == null)
                throw new InvalidOperationException(
                    $"Message with sequence number {sequenceNumber} not found");

            await receiver.CompleteMessageAsync(target);
        }
    }

    public async Task<QueueRuntimeProperties> GetQueueRuntimePropertiesAsync(string queueName)
    {
        EnsureConnected();
        return await _adminClient!.GetQueueRuntimePropertiesAsync(queueName);
    }

    public async Task<TopicRuntimeProperties> GetTopicRuntimePropertiesAsync(string topicName)
    {
        EnsureConnected();
        return await _adminClient!.GetTopicRuntimePropertiesAsync(topicName);
    }

    public async Task<SubscriptionRuntimeProperties> GetSubscriptionRuntimePropertiesAsync(
        string topicName, string subscriptionName)
    {
        EnsureConnected();
        return await _adminClient!.GetSubscriptionRuntimePropertiesAsync(
            topicName, subscriptionName);
    }

    private void EnsureConnected()
    {
        if (_client == null || _adminClient == null)
            throw new InvalidOperationException("Not connected to Azure Service Bus");
    }

    public void Dispose()
    {
        Disconnect();
    }
}