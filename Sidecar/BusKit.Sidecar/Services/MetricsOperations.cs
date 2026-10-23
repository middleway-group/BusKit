using Azure.Monitor.Query;
using Azure.Monitor.Query.Models;
using BusKit.Sidecar.Grpc;

namespace BusKit.Sidecar.Services;

/// <summary>Queries Azure Monitor metrics for a Service Bus namespace entity.</summary>
public sealed class MetricsOperations(
    Azure.Core.TokenCredential? credential, string? subscriptionId, string? resourceGroup, string? namespaceName)
{
    private static readonly string[] MetricNames =
    [
        "IncomingRequests", "SuccessfulRequests", "ServerErrors",
        "UserErrors", "ThrottledRequests",
        "IncomingMessages", "OutgoingMessages",
    ];

    public async Task<GetTopicMetricsReply> GetTopicMetricsAsync(
        GetTopicMetricsRequest request, CancellationToken ct = default)
    {
        var reply = new GetTopicMetricsReply();
        var (series, error) = await QueryAsync(request.TopicName, request.Hours, ct);
        reply.Series.AddRange(series);
        if (error != null) reply.Error = error;
        return reply;
    }

    public async Task<GetQueueMetricsReply> GetQueueMetricsAsync(
        GetQueueMetricsRequest request, CancellationToken ct = default)
    {
        var reply = new GetQueueMetricsReply();
        var (series, error) = await QueryAsync(request.QueueName, request.Hours, ct);
        reply.Series.AddRange(series);
        if (error != null) reply.Error = error;
        return reply;
    }

    /// <summary>Picks the Azure Monitor time grain so the chart has a sensible number of points.</summary>
    public static TimeSpan GranularityFor(int hours) => hours switch
    {
        <= 1   => TimeSpan.FromMinutes(1),
        <= 12  => TimeSpan.FromMinutes(5),
        <= 24  => TimeSpan.FromMinutes(15),
        <= 168 => TimeSpan.FromHours(1),
        _      => TimeSpan.FromHours(6),
    };

    private async Task<(List<MetricSeries> Series, string? Error)> QueryAsync(
        string entityName, int requestedHours, CancellationToken ct)
    {
        var series = new List<MetricSeries>();

        if (credential == null || subscriptionId == null || resourceGroup == null || namespaceName == null)
            return (series, "Azure AD connection required for metrics.");

        try
        {
            var resourceId = $"/subscriptions/{subscriptionId}/resourceGroups/{resourceGroup}" +
                             $"/providers/Microsoft.ServiceBus/namespaces/{namespaceName}";

            var hours = Math.Max(1, requestedHours);
            var end   = DateTimeOffset.UtcNow;
            var start = end.AddHours(-hours);

            var options = new MetricsQueryOptions
            {
                Granularity = GranularityFor(hours),
                Filter      = $"EntityName eq '{entityName}'",
                TimeRange   = new QueryTimeRange(start, end),
            };
            options.MetricNamespace = "Microsoft.ServiceBus/namespaces";

            var response = await new MetricsQueryClient(credential)
                .QueryResourceAsync(resourceId, MetricNames, options, ct);

            foreach (var metric in response.Value.Metrics)
            {
                var s = new MetricSeries { Name = metric.Name };
                foreach (var ts in metric.TimeSeries)
                {
                    foreach (var dp in ts.Values)
                    {
                        if (dp.TimeStamp == default) continue;
                        s.Points.Add(new MetricDataPoint
                        {
                            TimestampUnix = dp.TimeStamp.ToUnixTimeSeconds(),
                            Value         = dp.Total ?? dp.Average ?? dp.Count ?? 0,
                        });
                    }
                }
                series.Add(s);
            }
            return (series, null);
        }
        catch (Exception ex)
        {
            return (series, ex.Message);
        }
    }
}
