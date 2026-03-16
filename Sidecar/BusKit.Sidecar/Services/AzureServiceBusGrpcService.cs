// using System;
// using System.Collections.Generic;
// using System.Threading.Tasks;
// using Azure.Messaging.ServiceBus;
// using BusKit.Sidecar.Grpc;
// using Grpc.Core;
// using Microsoft.Extensions.Logging;

// namespace BusKit.Sidecar.Services;

// public class AzureServiceBusGrpcService : BusKit.Sidecar.Grpc.BusKitService.BusKitServiceBase
// {
//     private readonly AzureServiceBusManager _manager;
//     private readonly ILogger<AzureServiceBusGrpcService> _logger;

//     public AzureServiceBusGrpcService(
//         AzureServiceBusManager manager,
//         ILogger<AzureServiceBusGrpcService> logger)
//     {
//         _manager = manager;
//         _logger = logger;
//     }

//     public override async Task<ConnectResponse> Connect(
//         ConnectRequest request, ServerCallContext context)
//     {
//         try
//         {
//             await _manager.ConnectAsync(request.ConnectionString);
//             return new ConnectResponse
//             {
//                 Success = true,
//                 NamespaceName = _manager.NamespaceName ?? ""
//             };
//         }
//         catch (Exception ex)
//         {
//             _logger.LogError(ex, "Failed to connect");
//             return new ConnectResponse
//             {
//                 Success = false,
//                 ErrorMessage = ex.Message
//             };
//         }
//     }

//     public override Task<DisconnectResponse> Disconnect(
//         DisconnectRequest request, ServerCallContext context)
//     {
//         _manager.Disconnect();
//         return Task.FromResult(new DisconnectResponse { Success = true });
//     }

//     public override async Task<ListQueuesResponse> ListQueues(
//         ListQueuesRequest request, ServerCallContext context)
//     {
//         var response = new ListQueuesResponse();

//         await foreach (var queue in _manager.ListQueuesAsync())
//         {
//             var runtime = await _manager.GetQueueRuntimePropertiesAsync(queue.Name);
//             response.Queues.Add(new QueueInfo
//             {
//                 Name = queue.Name,
//                 ActiveMessageCount = runtime.ActiveMessageCount,
//                 DeadLetterCount = runtime.DeadLetterMessageCount,
//                 ScheduledCount = runtime.ScheduledMessageCount,
//                 SizeInBytes = runtime.SizeInBytes,
//                 Status = queue.Status.ToString()
//             });
//         }

//         return response;
//     }

//     public override async Task<ListTopicsResponse> ListTopics(
//         ListTopicsRequest request, ServerCallContext context)
//     {
//         var response = new ListTopicsResponse();

//         await foreach (var topic in _manager.ListTopicsAsync())
//         {
//             var runtime = await _manager.GetTopicRuntimePropertiesAsync(topic.Name);
//             response.Topics.Add(new TopicInfo
//             {
//                 Name = topic.Name,
//                 SizeInBytes = topic.MaxSizeInMegabytes,
//                 SubscriptionCount = runtime.SubscriptionCount,
//                 Status = topic.Status.ToString()
//             });
//         }

//         return response;
//     }

//     public override async Task<ListSubscriptionsResponse> ListSubscriptions(
//         ListSubscriptionsRequest request, ServerCallContext context)
//     {
//         var response = new ListSubscriptionsResponse();

//         await foreach (var sub in _manager.ListSubscriptionsAsync(request.TopicName))
//         {
//             var runtime = await _manager.GetSubscriptionRuntimePropertiesAsync(
//                 request.TopicName, sub.SubscriptionName);
//             response.Subscriptions.Add(new SubscriptionInfo
//             {
//                 Name = sub.SubscriptionName,
//                 TopicName = request.TopicName,
//                 ActiveMessageCount = runtime.ActiveMessageCount,
//                 DeadLetterCount = runtime.DeadLetterMessageCount,
//                 Status = sub.Status.ToString()
//             });
//         }

//         return response;
//     }

//     public override async Task<PeekMessagesResponse> PeekMessages(
//         PeekMessagesRequest request, ServerCallContext context)
//     {
//         var maxMessages = request.MaxMessages > 0 ? request.MaxMessages : 50;

//         IReadOnlyList<ServiceBusReceivedMessage> messages;

//         if (!string.IsNullOrEmpty(request.TopicName) &&
//             !string.IsNullOrEmpty(request.SubscriptionName))
//         {
//             messages = await _manager.PeekSubscriptionMessagesAsync(
//                 request.TopicName, request.SubscriptionName,
//                 maxMessages, request.FromSequenceNumber, false);
//         }
//         else
//         {
//             messages = await _manager.PeekMessagesAsync(
//                 request.QueueName, maxMessages,
//                 request.FromSequenceNumber, false);
//         }

//         var response = new PeekMessagesResponse();
//         foreach (var msg in messages)
//         {
//             var busMsg = new BusMessage
//             {
//                 MessageId = msg.MessageId ?? "",
//                 SequenceNumber = msg.SequenceNumber,
//                 ContentType = msg.ContentType ?? "",
//                 Subject = msg.Subject ?? "",
//                 Body = msg.Body.ToString(),
//                 EnqueuedTime = msg.EnqueuedTime.ToString("O"),
//                 ExpiresAt = msg.ExpiresAt.ToString("O"),
//                 DeliveryCount = msg.DeliveryCount,
//                 CorrelationId = msg.CorrelationId ?? "",
//                 DeadLetterReason = msg.DeadLetterReason ?? "",
//                 DeadLetterDescription = msg.DeadLetterErrorDescription ?? "",
//             };

//             foreach (var prop in msg.ApplicationProperties)
//             {
//                 busMsg.ApplicationProperties[prop.Key] = prop.Value?.ToString() ?? "";
//             }

//             response.Messages.Add(busMsg);
//         }

//         return response;
//     }

//     public override async Task<ResubmitMessageResponse> ResubmitMessage(
//         ResubmitMessageRequest request, ServerCallContext context)
//     {
//         try
//         {
//             await _manager.ResubmitMessageAsync(
//                 request.SourceQueue, request.SourceTopic, request.SourceSubscription,
//                 request.FromDeadLetter, request.SequenceNumber,
//                 request.TargetQueue, request.TargetTopic,
//                 request.ModifiedProperties, request.ModifiedBody);

//             return new ResubmitMessageResponse { Success = true };
//         }
//         catch (Exception ex)
//         {
//             return new ResubmitMessageResponse
//             {
//                 Success = false,
//                 ErrorMessage = ex.Message
//             };
//         }
//     }

//     public override async Task<DeleteMessageResponse> DeleteMessage(
//         DeleteMessageRequest request, ServerCallContext context)
//     {
//         try
//         {
//             await _manager.DeleteMessageAsync(
//                 request.QueueName, request.TopicName, request.SubscriptionName,
//                 request.FromDeadLetter, request.SequenceNumber);

//             return new DeleteMessageResponse { Success = true };
//         }
//         catch (Exception ex)
//         {
//             return new DeleteMessageResponse
//             {
//                 Success = false,
//                 ErrorMessage = ex.Message
//             };
//         }
//     }

//     public override Task<PingResponse> Ping(
//         PingRequest request, ServerCallContext context)
//     {
//         return Task.FromResult(new PingResponse
//         {
//             Ready = true,
//             Version = "1.0.0"
//         });
//     }

//     public override async Task<PeekMessagesResponse> PeekDeadLetterMessages(
//         PeekDeadLetterMessagesRequest request, ServerCallContext context)
//     {
//         var maxMessages = request.MaxMessages > 0 ? request.MaxMessages : 50;

//         IReadOnlyList<ServiceBusReceivedMessage> messages;

//         if (!string.IsNullOrEmpty(request.TopicName) &&
//             !string.IsNullOrEmpty(request.SubscriptionName))
//         {
//             messages = await _manager.PeekSubscriptionMessagesAsync(
//                 request.TopicName, request.SubscriptionName,
//                 maxMessages, 0, true);
//         }
//         else
//         {
//             messages = await _manager.PeekMessagesAsync(
//                 request.QueueName, maxMessages, 0, true);
//         }

//         var response = new PeekMessagesResponse();
//         foreach (var msg in messages)
//         {
//             var busMsg = new BusMessage
//             {
//                 MessageId = msg.MessageId ?? "",
//                 SequenceNumber = msg.SequenceNumber,
//                 ContentType = msg.ContentType ?? "",
//                 Subject = msg.Subject ?? "",
//                 Body = msg.Body.ToString(),
//                 EnqueuedTime = msg.EnqueuedTime.ToString("O"),
//                 ExpiresAt = msg.ExpiresAt.ToString("O"),
//                 DeliveryCount = msg.DeliveryCount,
//                 CorrelationId = msg.CorrelationId ?? "",
//                 DeadLetterReason = msg.DeadLetterReason ?? "",
//                 DeadLetterDescription = msg.DeadLetterErrorDescription ?? "",
//             };

//             foreach (var prop in msg.ApplicationProperties)
//             {
//                 busMsg.ApplicationProperties[prop.Key] = prop.Value?.ToString() ?? "";
//             }

//             response.Messages.Add(busMsg);
//         }

//         return response;
//     }
// }