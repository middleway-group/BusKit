using Azure.Monitor.Query;
using Azure.Monitor.Query.Models;
using BusKit.Sidecar.Grpc;

namespace BusKit.Sidecar.Services;

/// <summary>Queries Azure Monitor metrics for a Service Bus namespace entity.</summary>
public sealed class MetricsOperations(
    Azure.Core.TokenCredential? credential, string? subscriptionId, string? resourceGroup, string? namespaceName,
    IMetricsQuery? query = null)
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

            var results = await (query ?? new AzureMonitorMetricsQuery(credential)).QueryAsync(
                resourceId, MetricNames, $"EntityName eq '{entityName}'", GranularityFor(hours), start, end, ct);

            foreach (var metric in results)
            {
                var s = new MetricSeries { Name = metric.Name };
                foreach (var dp in metric.Samples)
                {
                    if (dp.TimeStamp == default) continue;
                    s.Points.Add(new MetricDataPoint
                    {
                        TimestampUnix = dp.TimeStamp.ToUnixTimeSeconds(),
                        Value         = dp.Total ?? dp.Average ?? dp.Count ?? 0,
                    });
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

public sealed record MetricSample(DateTimeOffset TimeStamp, double? Total, double? Average, double? Count);

public sealed record MetricResult(string Name, IReadOnlyList<MetricSample> Samples);

/// <summary>Seam over the Azure Monitor metrics client.</summary>
public interface IMetricsQuery
{
    Task<IReadOnlyList<MetricResult>> QueryAsync(
        string resourceId, IReadOnlyList<string> metricNames, string filter, TimeSpan granularity,
        DateTimeOffset start, DateTimeOffset end, CancellationToken ct);
}

internal sealed class AzureMonitorMetricsQuery(Azure.Core.TokenCredential credential) : IMetricsQuery
{
    public async Task<IReadOnlyList<MetricResult>> QueryAsync(
        string resourceId, IReadOnlyList<string> metricNames, string filter, TimeSpan granularity,
        DateTimeOffset start, DateTimeOffset end, CancellationToken ct)
    {
        var options = new MetricsQueryOptions
        {
            Granularity = granularity,
            Filter      = filter,
            TimeRange   = new QueryTimeRange(start, end),
        };
        options.MetricNamespace = "Microsoft.ServiceBus/namespaces";

        var response = await new MetricsQueryClient(credential).QueryResourceAsync(resourceId, metricNames, options, ct);

        return response.Value.Metrics
            .Select(m => new MetricResult(
                m.Name,
                m.TimeSeries.SelectMany(ts => ts.Values)
                    .Select(v => new MetricSample(v.TimeStamp, v.Total, v.Average, v.Count))
                    .ToList()))
            .ToList();
    }
}
