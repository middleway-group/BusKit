import SwiftUI
import Charts

// MARK: - TopicDetailView

@available(macOS 15.0, *)
struct TopicDetailView: View {
    @Environment(GRPCManager.self) var grpc
    let topic: TopicItem

    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Label("Overview", systemImage: "info.circle").tag(0)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            TopicOverviewTab(topic: topic)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(topic.name)
    }
}

// MARK: - Overview Tab

@available(macOS 15.0, *)
private struct TopicOverviewTab: View {
    @Environment(GRPCManager.self) var grpc
    let topic: TopicItem

    @State private var details: TopicDetailsItem?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var lastUpdated: Date?
    @State private var refreshToken = UUID()

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading properties…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle).foregroundStyle(.red)
                    Text(error).foregroundStyle(.secondary).font(.caption)
                    Button("Retry") { Task { await loadDetails() } }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let d = details {
                TopicOverviewContent(details: d, lastUpdated: lastUpdated, onRefresh: {
                    Task { await loadDetails() }
                })
            }
        }
        .task { await loadDetails() }
        .onChange(of: topic.name) { _, _ in Task { await loadDetails() } }
    }

    private func loadDetails() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            details = try await grpc.getTopicProperties(name: topic.name)
            lastUpdated = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Overview Content

@available(macOS 15.0, *)
private struct TopicOverviewContent: View {
    let details: TopicDetailsItem
    let lastUpdated: Date?
    let onRefresh: () -> Void

    @State private var generalInfoExpanded    = true
    @State private var settingsExpanded       = true
    @State private var messageCountExpanded   = true
    @State private var metricsExpanded        = true
    @State private var selectedTimeRange      = 1

    private let timeRangeOptions = ["1 hour", "6 hours", "12 hours", "1 day", "7 days", "30 days"]

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                // ── Toolbar row ──────────────────────────────────
                HStack {
                    Button(action: onRefresh) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh topic data")

                    Spacer()

                    Text(details.name)
                        .font(.title2).fontWeight(.bold)
                        .accessibilityLabel("Topic name: \(details.name)")

                    Spacer()

                    if let updated = lastUpdated {
                        Text("Last updated: \(updated, style: .relative) ago")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

                Divider()

                // ── Section 1: General Info ──────────────────────
                CollapsibleSection(title: "General Info", isExpanded: $generalInfoExpanded) {
                    GeneralInfoGrid(details: details)
                }

                Divider()

                // ── Section 2: Settings ──────────────────────────
                CollapsibleSection(title: "Settings", isExpanded: $settingsExpanded) {
                    SettingsCards(details: details)
                }

                Divider()

                // ── Section 3: Message Count ─────────────────────
                CollapsibleSection(title: "Message Count", isExpanded: $messageCountExpanded) {
                    MessageCountCards(details: details)
                }

                Divider()

                // ── Section 4: Metrics ───────────────────────────
                CollapsibleSection(title: "Metrics", isExpanded: $metricsExpanded) {
                    MetricsSection(selectedTimeRange: $selectedTimeRange,
                                   timeRangeOptions: timeRangeOptions,
                                   topicName: details.name)
                }

                Spacer(minLength: 24)
            }
        }
        .frame(minWidth: 800)
    }
}

// MARK: - Collapsible Section

@available(macOS 15.0, *)
private struct CollapsibleSection<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                let toggle = { isExpanded.toggle() }
                if reduceMotion {
                    toggle()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { toggle() }
                }
            } label: {
                HStack {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .animation(reduceMotion ? nil : .spring(response: 0.3), value: isExpanded)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title) section, \(isExpanded ? "expanded" : "collapsed")")

            if isExpanded {
                content()
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }
        }
    }
}

// MARK: - General Info Grid

@available(macOS 15.0, *)
private struct GeneralInfoGrid: View {
    let details: TopicDetailsItem

    private var createdFormatted: String {
        details.createdAt.formatted(Date.FormatStyle()
            .month(.abbreviated).day().year().hour().minute())
    }

    private var updatedFormatted: String {
        details.updatedAt.formatted(Date.FormatStyle()
            .month(.abbreviated).day().year().hour().minute())
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 10) {
            GridRow {
                infoField(label: "Status") {
                    StatusBadge(status: details.status)
                }
                infoField(label: "Created") {
                    Text(createdFormatted)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .accessibilityValue(createdFormatted)
                }
            }
            GridRow {
                infoField(label: "Partitioning") {
                    FeatureBadge(enabled: details.enablePartitioning)
                }
                infoField(label: "Updated") {
                    Text(updatedFormatted)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .accessibilityValue(updatedFormatted)
                }
            }
            GridRow {
                infoField(label: "Duplicate Det.") {
                    FeatureBadge(enabled: details.requiresDuplicateDetection)
                }
                infoField(label: "Support Ordering") {
                    FeatureBadge(enabled: details.supportOrdering)
                }
            }
        }
    }

    @ViewBuilder
    private func infoField<V: View>(label: String, @ViewBuilder value: () -> V) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            value()
        }
    }
}

// MARK: - Status Badge

private struct StatusBadge: View {
    let status: String

    private var color: Color {
        switch status.lowercased() {
        case "active":   return .green
        case "disabled": return .orange
        default:         return .gray
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(status.isEmpty ? "Unknown" : status)
                .font(.callout)
                .foregroundStyle(.primary)
        }
        .accessibilityLabel("Status: \(status)")
    }
}

// MARK: - Feature Badge

private struct FeatureBadge: View {
    let enabled: Bool

    var body: some View {
        Text(enabled ? "Enabled" : "Disabled")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(enabled ? Color.blue : Color.gray)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .accessibilityLabel(enabled ? "Enabled" : "Disabled")
    }
}

// MARK: - Settings Cards

@available(macOS 15.0, *)
private struct SettingsCards: View {
    let details: TopicDetailsItem

    private var sizeStr: (value: String, unit: String) {
        formatBytes(details.sizeBytes)
    }

    private var maxSizeStr: (value: String, unit: String) {
        ("\(details.maxSizeMb)", "MB")
    }

    private var ttlStr: (value: String, unit: String) {
        formatDurationCard(details.defaultMessageTtlSeconds)
    }

    private var autoDeleteStr: (value: String, unit: String) {
        details.autoDeleteOnIdleSeconds > 0
            ? formatDurationCard(details.autoDeleteOnIdleSeconds)
            : ("∞", "")
    }

    private var freeSpaceStr: (value: String, unit: String) {
        let maxBytes = details.maxSizeMb * 1_024 * 1_024
        let free = max(0, maxBytes - details.sizeBytes)
        return formatBytes(free)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                MetricCard(label: "Current Size",
                           value: sizeStr.value, unit: sizeStr.unit,
                           accentColor: .blue)
                MetricCard(label: "Max Size",
                           value: maxSizeStr.value, unit: maxSizeStr.unit,
                           accentColor: .pink)
                MetricCard(label: "Message TTL",
                           value: ttlStr.value, unit: ttlStr.unit,
                           accentColor: .green)
                MetricCard(label: "Auto-delete",
                           value: autoDeleteStr.value, unit: autoDeleteStr.unit,
                           accentColor: .teal)
                MetricCard(label: "Free Space",
                           value: freeSpaceStr.value, unit: freeSpaceStr.unit,
                           accentColor: .purple)
                if !details.userMetadata.isEmpty {
                    MetricCard(label: "User Metadata",
                               value: details.userMetadata, unit: "",
                               accentColor: .orange)
                }
            }
        }
    }
}

// MARK: - Message Count Cards

@available(macOS 15.0, *)
private struct MessageCountCards: View {
    let details: TopicDetailsItem

    var body: some View {
        HStack(spacing: 12) {
            MetricCard(label: "Scheduled",
                       value: "\(details.scheduledMessageCount)", unit: "MESSAGES",
                       accentColor: .teal)
            Spacer()
        }
    }
}

// MARK: - Metric Card

private struct MetricCard: View {
    let label: String
    let value: String
    let unit: String
    let accentColor: Color

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)

            HStack(spacing: 0) {
                // Left accent bar
                Rectangle()
                    .fill(accentColor)
                    .frame(width: 4)
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 10, bottomLeadingRadius: 10,
                            bottomTrailingRadius: 0, topTrailingRadius: 0
                        )
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text(value)
                        .font(.title.bold())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)

                    if !unit.isEmpty {
                        Text(unit)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
        }
        .frame(minWidth: 130, maxWidth: 160, minHeight: 90, maxHeight: 90)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value) \(unit)")
        .onHover { inside in
            if !inside { NSCursor.arrow.set() }
        }
    }
}

// MARK: - Metrics Section

@available(macOS 15.0, *)
private struct MetricsSection: View {
    @Binding var selectedTimeRange: Int
    let timeRangeOptions: [String]
    let topicName: String

    @Environment(GRPCManager.self) var grpc

    @State private var requestSamples: [MetricSample] = []
    @State private var messageSamples: [MetricSample] = []
    @State private var isLoading = false
    @State private var metricsError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Time Range Selector
            HStack(spacing: 8) {
                Text("Show data for the last:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Picker("", selection: $selectedTimeRange) {
                    ForEach(0..<timeRangeOptions.count, id: \.self) { idx in
                        Text(timeRangeOptions[idx]).tag(idx)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 480)
                .onChange(of: selectedTimeRange) { _, _ in Task { await refreshChartData() } }
                if isLoading {
                    ProgressView().scaleEffect(0.7)
                }
            }

            if let err = metricsError {
                Text(err)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
            } else {
                // Charts
                HStack(alignment: .top, spacing: 16) {
                    MetricChartCard(
                        title: "Requests",
                        series: requestSeriesDefs,
                        samples: requestSamples
                    )
                    MetricChartCard(
                        title: "Messages",
                        series: messageSeriesDefs,
                        samples: messageSamples
                    )
                }
            }
        }
        .onAppear { Task { await refreshChartData() } }
    }

    private var requestSeriesDefs: [SeriesDef] {[
        SeriesDef(key: "IncomingRequests",  label: "Incoming Req.",    color: .blue),
        SeriesDef(key: "SuccessfulRequests",label: "Successful Req.",  color: .pink),
        SeriesDef(key: "ServerErrors",      label: "Server Errors",    color: .teal),
        SeriesDef(key: "UserErrors",        label: "User Errors",      color: .purple),
        SeriesDef(key: "ThrottledRequests", label: "Throttled Req.",   color: .green),
    ]}

    private var messageSeriesDefs: [SeriesDef] {[
        SeriesDef(key: "IncomingMessages", label: "Incoming Msg.",  color: .blue),
        SeriesDef(key: "OutgoingMessages", label: "Outgoing Msg.",  color: .pink),
    ]}

    private func refreshChartData() async {
        isLoading = true
        metricsError = nil
        let hours = hoursForRange(selectedTimeRange)
        do {
            let allSeries = try await grpc.getTopicMetrics(topicName: topicName, hours: hours)
            let seriesMap = Dictionary(uniqueKeysWithValues: allSeries.map { ($0.name, $0) })
            requestSamples = buildSamples(defs: requestSeriesDefs, seriesMap: seriesMap)
            messageSamples = buildSamples(defs: messageSeriesDefs, seriesMap: seriesMap)
        } catch {
            metricsError = error.localizedDescription
        }
        isLoading = false
    }

    private func buildSamples(defs: [SeriesDef], seriesMap: [String: Buskit_MetricSeries]) -> [MetricSample] {
        var samples: [MetricSample] = []
        for def in defs {
            if let series = seriesMap[def.key] {
                for pt in series.points {
                    samples.append(MetricSample(
                        series: def.key,
                        timestamp: Date(timeIntervalSince1970: TimeInterval(pt.timestampUnix)),
                        value: pt.value
                    ))
                }
            }
        }
        return samples
    }

    private func hoursForRange(_ idx: Int) -> Int {
        [1, 6, 12, 24, 168, 720][idx]
    }
}

// MARK: - Chart Data Models

struct MetricSample: Identifiable {
    let id = UUID()
    let series: String
    let timestamp: Date
    let value: Double
}

struct SeriesDef: Identifiable {
    let id = UUID()
    let key: String
    let label: String
    let color: Color
}

// MARK: - Metric Chart Card

@available(macOS 15.0, *)
private struct MetricChartCard: View {
    let title: String
    let series: [SeriesDef]
    let samples: [MetricSample]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 4)

            Chart {
                ForEach(series) { s in
                    ForEach(samples.filter { $0.series == s.key }) { point in
                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Value", point.value)
                        )
                        .foregroundStyle(by: .value("Series", s.label))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
            }
            .chartForegroundStyleScale(
                domain: series.map(\.label),
                range: series.map(\.color)
            )
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: .automatic) {
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color(nsColor: .separatorColor))
                    AxisValueLabel()
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic) {
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color(nsColor: .separatorColor))
                    AxisValueLabel()
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                }
            }
            .frame(height: 220)
            .padding(.horizontal, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))

            // Legend
            ChartLegend(series: series, samples: samples)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) chart")
    }
}

// MARK: - Chart Legend

@available(macOS 15.0, *)
private struct ChartLegend: View {
    let series: [SeriesDef]
    let samples: [MetricSample]

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(series) { s in
                let total = samples.filter { $0.series == s.key }.reduce(0) { $0 + $1.value }
                HStack(spacing: 4) {
                    Circle()
                        .fill(s.color)
                        .frame(width: 8, height: 8)
                    Text(s.label)
                        .font(.caption)
                        .foregroundStyle(.primary)
                    Text(formatMetricValue(total))
                        .font(.caption.bold())
                        .foregroundStyle(.primary)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private func formatMetricValue(_ v: Double) -> String {
        if v >= 1_000_000 { return String(format: "%.2fM", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.2fk", v / 1_000) }
        return "\(Int(v))"
    }
}

// MARK: - Flow Layout

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY
        var rowHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            sv.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
    }
}

// MARK: - Formatting Helpers

private func formatBytes(_ bytes: Int64) -> (value: String, unit: String) {
    let gb: Double = 1_073_741_824
    let mb: Double = 1_048_576
    let kb: Double = 1_024
    let d = Double(bytes)
    if d >= gb { return (String(format: "%.1f", d / gb), "GB") }
    if d >= mb { return (String(format: "%.1f", d / mb), "MB") }
    if d >= kb { return (String(format: "%.1f", d / kb), "KB") }
    return ("\(bytes)", "B")
}

private func formatDurationCard(_ seconds: Int64) -> (value: String, unit: String) {
    guard seconds > 0 else { return ("∞", "") }
    let days    = seconds / 86_400
    let hours   = (seconds % 86_400) / 3_600
    let minutes = (seconds % 3_600) / 60
    if days > 0    { return ("\(days)", days == 1 ? "day" : "days") }
    if hours > 0   { return ("\(hours)", hours == 1 ? "hour" : "hours") }
    if minutes > 0 { return ("\(minutes)", minutes == 1 ? "min" : "mins") }
    return ("\(seconds)", "sec")
}
