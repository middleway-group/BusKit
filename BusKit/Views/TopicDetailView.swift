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
