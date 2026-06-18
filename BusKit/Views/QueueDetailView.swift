import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - QueueDetailView

@available(macOS 15.0, *)
struct QueueDetailView: View {
    @Environment(GRPCManager.self) var grpc
    @Environment(EntityActionStore.self) var actionStore
    let queue: QueueItem

    @State private var selectedTab = 0

    // Trigger state for each messages tab
    @State private var messagesTrigger     = UUID()
    @State private var messagesCount: Int32 = 10
    @State private var dlqTrigger          = UUID()
    @State private var dlqCount: Int32      = 10

    var body: some View {
        VStack(spacing: 0) {
            // Segmented picker lives inside the content area so it never
            // interferes with the window toolbar where ConnectionToolbar lives.
            Picker("", selection: $selectedTab) {
                Label("Overview",       systemImage: "info.circle").tag(0)
                Label("Messages",          systemImage: "list.bullet.rectangle").tag(1)
                Label("Deadletter",        systemImage: "tray.and.arrow.down").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            Group {
                switch selectedTab {
                case 1:
                    if grpc.rbacAccessLevel.hasDataAccess {
                        MessagesTab(queue: queue, isDLQ: false,
                                    trigger: messagesTrigger, requestedCount: messagesCount)
                    } else {
                        DataAccessRestrictedView()
                    }
                case 2:
                    if grpc.rbacAccessLevel.hasDataAccess {
                        MessagesTab(queue: queue, isDLQ: true,
                                    trigger: dlqTrigger, requestedCount: dlqCount)
                    } else {
                        DataAccessRestrictedView()
                    }
                default:
                    QueueOverviewTab(queue: queue, selectedTab: $selectedTab)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(queue.name)
        .onChange(of: actionStore.pendingAction) { _, action in
            guard let action, action.entityKey == EntityActionStore.queueKey(queue.name) else { return }
            if grpc.rbacAccessLevel.hasDataAccess {
                if action.isDLQ {
                    dlqCount    = action.count
                    dlqTrigger  = UUID()
                    selectedTab = 2
                } else {
                    messagesCount   = action.count
                    messagesTrigger = UUID()
                    selectedTab     = 1
                }
            }
        }
    }
}

// MARK: - Overview Tab

@available(macOS 15.0, *)
private struct QueueOverviewTab: View {
    @Environment(GRPCManager.self) var grpc
    let queue: QueueItem
    @Binding var selectedTab: Int

    @State private var details: QueueDetailsItem?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var lastUpdated: Date?
    @State private var metricsRefreshTrigger = UUID()

    @State private var essentialsExpanded = true
    @State private var settingsExpanded = true
    @State private var messageCountExpanded = true
    @State private var metricsExpanded = true

    @State private var selectedTimeRange = 1
    private let timeRangeOptions = ["1 hour", "6 hours", "12 hours", "1 day", "7 days", "30 days"]

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading overview…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.red)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let details {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack(spacing: 12) {
                            Button {
                                Task { await loadDetails() }
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.borderless)
                            .help("Refresh overview")

                            Spacer()

                            if let lastUpdated {
                                Text("Updated \(lastUpdated, style: .relative) ago")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        CollapsibleSection(title: "Essentials", isExpanded: $essentialsExpanded) {
                            QueueEssentialsGrid(details: details)
                        }

                        CollapsibleSection(title: "Settings", isExpanded: $settingsExpanded) {
                            QueueSettingsCards(details: details)
                        }

                        CollapsibleSection(title: "Message Counts", isExpanded: $messageCountExpanded) {
                            QueueMessageCountCards(details: details, onTabSelect: { selectedTab = $0 })
                        }

                        CollapsibleSection(title: "Metrics", isExpanded: $metricsExpanded) {
                            QueueMetricsSection(
                                selectedTimeRange: $selectedTimeRange,
                                timeRangeOptions: timeRangeOptions,
                                queueName: details.name,
                                refreshTrigger: metricsRefreshTrigger
                            )
                        }
                    }
                    .padding(20)
                }
            }
        }
        .task { await loadDetails() }
        .onChange(of: queue.name) { _, _ in Task { await loadDetails() } }
    }

    private func loadDetails() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            details = try await grpc.getQueueProperties(name: queue.name)
            lastUpdated = .now
            metricsRefreshTrigger = UUID()
        } catch {
            details = nil
            errorMessage = error.localizedDescription
        }
    }
}

@available(macOS 15.0, *)
private struct QueueEssentialsGrid: View {
    @Environment(GRPCManager.self) var grpc
    let details: QueueDetailsItem

    private var namespace: String {
        grpc.namespaceName ?? ""
    }

    private var namespaceURL: String? {
        namespace.isEmpty ? nil : "https://\(fqns)"
    }

    private var fqns: String {
        namespace.hasSuffix(".servicebus.windows.net")
            ? namespace
            : "\(namespace).servicebus.windows.net"
    }

    private var queueURL: String? {
        namespace.isEmpty ? nil : "https://\(fqns)/\(details.name)"
    }

    private var deadLetterName: String {
        "\(details.name)/$DeadLetterQueue"
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 10) {
            GridRow {
                infoField(label: "Namespace") {
                    if let namespaceURL {
                        QueueOverviewLink(text: namespace, urlString: namespaceURL)
                    } else {
                        Text("—")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                infoField(label: "Queue URL") {
                    if let queueURL {
                        QueueOverviewLink(text: queueURL, urlString: queueURL,
                                          lineLimit: 1, helpText: queueURL,
                                          copyValue: queueURL)
                    } else {
                        Text("—")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            GridRow {
                infoField(label: "Status") {
                    QueueStatusBadge(status: details.status)
                }
                infoField(label: "Created") {
                    Text(queueFormatDate(details.createdAt))
                        .font(.callout)
                        .foregroundStyle(.primary)
                }
            }

            GridRow {
                infoField(label: "Partitioning") {
                    QueueFeatureBadge(enabled: details.enablePartitioning)
                }
                infoField(label: "Updated") {
                    Text(queueFormatDate(details.updatedAt))
                        .font(.callout)
                        .foregroundStyle(.primary)
                }
            }

            GridRow {
                infoField(label: "Duplicate Detection") {
                    QueueFeatureBadge(enabled: details.requiresDuplicateDetection)
                }
                infoField(label: "Sessions") {
                    QueueFeatureBadge(enabled: details.requiresSession)
                }
            }

            GridRow {
                infoField(label: "Dead Lettering") {
                    Text(deadLetterName)
                        .font(.callout)
                        .foregroundStyle(.tint)
                        .underline()
                        .help(deadLetterName)
                }
                infoField(label: "Forward Messages") {
                    if details.forwardTo.isEmpty {
                        QueueFeatureBadge(enabled: false)
                    } else {
                        Text(details.forwardTo)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(details.forwardTo)
                    }
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
                .frame(width: 140, alignment: .trailing)
            value()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@available(macOS 15.0, *)
private struct QueueSettingsCards: View {
    let details: QueueDetailsItem

    private var currentSize: (value: String, unit: String) {
        queueFormatSize(details.sizeBytes)
    }

    private var maxSize: (value: String, unit: String) {
        details.maxSizeMb >= 1024
            ? ("\(details.maxSizeMb / 1024)", "GB")
            : ("\(details.maxSizeMb)", "MB")
    }

    private var ttl: (value: String, unit: String) {
        queueFormatDurationCard(details.defaultMessageTtlSeconds)
    }

    private var autoDelete: (value: String, unit: String) {
        details.autoDeleteOnIdleSeconds == 0
            ? ("NEVER", "")
            : queueFormatDurationCard(details.autoDeleteOnIdleSeconds)
    }

    private var duplicateWindow: (value: String, unit: String) {
        details.duplicateDetectionWindowSeconds == 0
            ? ("—", "")
            : queueFormatDurationCard(details.duplicateDetectionWindowSeconds)
    }

    private var messageLock: (value: String, unit: String) {
        queueFormatDurationCard(details.lockDurationSeconds)
    }

    private var freeSpace: (value: String, unit: String) {
        let maxBytes = Double(details.maxSizeMb) * 1_024 * 1_024
        guard maxBytes > 0 else { return ("0.0", "%") }
        let percent = max(0, 100 * (1 - (Double(details.sizeBytes) / maxBytes)))
        return (String(format: "%.1f", percent), "%")
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                MetricCard(label: "Max Delivery Count", value: "\(details.maxDeliveryCount)", unit: "", accentColor: .orange)
                MetricCard(label: "Current Size", value: currentSize.value, unit: currentSize.unit, accentColor: .blue)
                MetricCard(label: "Max Size", value: maxSize.value, unit: maxSize.unit, accentColor: .pink)
                MetricCard(label: "Message TTL", value: ttl.value, unit: ttl.unit, accentColor: .green)
                MetricCard(label: "Auto-delete", value: autoDelete.value, unit: autoDelete.unit, accentColor: .teal)
                MetricCard(label: "Duplicate Det. Window", value: duplicateWindow.value, unit: duplicateWindow.unit, accentColor: .indigo)
                MetricCard(label: "Message Lock", value: messageLock.value, unit: messageLock.unit, accentColor: .purple)
                MetricCard(label: "Free Space", value: freeSpace.value, unit: freeSpace.unit, accentColor: .cyan)
                MetricCard(label: "User Metadata", value: details.userMetadata.isEmpty ? "—" : details.userMetadata, unit: "", accentColor: .orange)
            }
            .padding(.vertical, 2)
        }
    }
}

@available(macOS 15.0, *)
private struct QueueMessageCountCards: View {
    let details: QueueDetailsItem
    var onTabSelect: ((Int) -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            QueueMessageCountCard(label: "Active", value: details.activeMessageCount, accentColor: .purple, onTap: { onTabSelect?(1) })
            QueueMessageCountCard(label: "Scheduled", value: details.scheduledMessageCount, accentColor: .green)
            QueueMessageCountCard(
                label: "Dead-letter",
                value: details.deadLetterCount,
                accentColor: details.deadLetterCount == 0 ? .pink : .orange,
                showWarning: details.deadLetterCount > 0,
                onTap: { onTabSelect?(2) }
            )
            QueueMessageCountCard(label: "Transfer", value: details.transferMessageCount, accentColor: .blue)
            QueueMessageCountCard(
                label: "Transfer Dead-letter",
                value: details.transferDeadLetterCount,
                accentColor: details.transferDeadLetterCount > 0 ? .red : .secondary,
                showWarning: details.transferDeadLetterCount > 0
            )
        }
    }
}

@available(macOS 15.0, *)
private struct QueueMessageCountCard: View {
    let label: String
    let value: Int64
    let accentColor: Color
    var showWarning = false
    var onTap: (() -> Void)? = nil

    var body: some View {
        let card = MetricCard(label: label, value: "\(value)", unit: "MESSAGES", accentColor: accentColor)
            .overlay(alignment: .topTrailing) {
                if showWarning {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .padding(10)
                }
            }

        if let onTap {
            Button(action: onTap) { card }
                .buttonStyle(.plain)
                .onHover { inside in inside ? NSCursor.pointingHand.set() : NSCursor.arrow.set() }
                .help("Open \(label) tab")
        } else {
            card
        }
    }
}

@available(macOS 15.0, *)
private struct QueueMetricsSection: View {
    @Binding var selectedTimeRange: Int
    let timeRangeOptions: [String]
    let queueName: String
    let refreshTrigger: UUID

    @Environment(GRPCManager.self) var grpc

    @State private var requestSamples: [MetricSample] = []
    @State private var messageSamples: [MetricSample] = []
    @State private var isLoading = false
    @State private var metricsError: String?

    private var requestSeriesDefs: [SeriesDef] {[
        SeriesDef(key: "IncomingRequests", label: "Incoming Req.", color: .blue),
        SeriesDef(key: "SuccessfulRequests", label: "Successful Req.", color: .pink),
        SeriesDef(key: "ServerErrors", label: "Server Errors", color: .teal),
        SeriesDef(key: "UserErrors", label: "User Errors", color: .purple),
        SeriesDef(key: "ThrottledRequests", label: "Throttled Req.", color: .green),
    ]}

    private var messageSeriesDefs: [SeriesDef] {[
        SeriesDef(key: "IncomingMessages", label: "Incoming Msg.", color: .blue),
        SeriesDef(key: "OutgoingMessages", label: "Outgoing Msg.", color: .pink),
    ]}

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }

            if let metricsError {
                Text(metricsError)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    MetricChartCard(title: "Requests", series: requestSeriesDefs, samples: requestSamples)
                    MetricChartCard(title: "Messages", series: messageSeriesDefs, samples: messageSamples)
                }
            }
        }
        .onAppear { Task { await refreshChartData() } }
        .onChange(of: refreshTrigger) { _, _ in Task { await refreshChartData() } }
    }

    private func refreshChartData() async {
        isLoading = true
        metricsError = nil
        let hours = queueHoursForRange(selectedTimeRange)

        do {
            let allSeries = try await grpc.getQueueMetrics(queueName: queueName, hours: hours)
            let seriesMap = Dictionary(uniqueKeysWithValues: allSeries.map { ($0.name, $0) })
            requestSamples = queueBuildSamples(defs: requestSeriesDefs, seriesMap: seriesMap)
            messageSamples = queueBuildSamples(defs: messageSeriesDefs, seriesMap: seriesMap)
        } catch {
            metricsError = error.localizedDescription
        }

        isLoading = false
    }
}

@available(macOS 15.0, *)
private struct QueueStatusBadge: View {
    let status: String

    private var color: Color {
        switch status.lowercased() {
        case "active": return .green
        case "disabled": return .orange
        default: return .gray
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

@available(macOS 15.0, *)
private struct QueueFeatureBadge: View {
    let enabled: Bool
    var label: String? = nil

    var body: some View {
        Text(label ?? (enabled ? "Enabled" : "Disabled"))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(enabled ? Color.blue : Color.gray)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .accessibilityLabel(label ?? (enabled ? "Enabled" : "Disabled"))
    }
}

@available(macOS 15.0, *)
private struct QueueOverviewLink: View {
    let text: String
    let urlString: String
    var lineLimit: Int? = nil
    var helpText: String? = nil
    var copyValue: String? = nil

    @State private var copied = false

    var body: some View {
        HStack(spacing: 4) {
            Button {
                guard let url = URL(string: urlString) else { return }
                NSWorkspace.shared.open(url)
            } label: {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.tint)
                    .underline()
                    .lineLimit(lineLimit)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .help(helpText ?? text)

            if let copyValue {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyValue, forType: .string)
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { copied = false }
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(copied ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help("Copy URL")
            }
        }
    }
}

private func queueFormatDate(_ date: Date) -> String {
    date.formatted(Date.FormatStyle().month(.abbreviated).day().year().hour().minute())
}

private func queueFormatSize(_ bytes: Int64) -> (value: String, unit: String) {
    let gb: Double = 1_073_741_824
    let mb: Double = 1_048_576
    let kb: Double = 1_024
    let value = Double(bytes)

    if value >= gb { return (String(format: "%.1f", value / gb), "GB") }
    if value >= mb { return (String(format: "%.1f", value / mb), "MB") }
    if value >= kb { return (String(format: "%.1f", value / kb), "KB") }
    return ("\(bytes)", "B")
}

private func queueFormatDurationCard(_ seconds: Int64) -> (value: String, unit: String) {
    guard seconds > 0 else { return ("—", "") }
    if seconds < 60 { return ("\(seconds)s", "") }
    if seconds < 3_600 { return ("\(seconds / 60)", "MIN") }
    if seconds < 86_400 { return ("\(seconds / 3_600)", "HRS") }
    return ("\(seconds / 86_400)", "DAYS")
}

private func queueHoursForRange(_ index: Int) -> Int {
    let options = [1, 6, 12, 24, 168, 720]
    let safeIndex = min(max(index, 0), options.count - 1)
    return options[safeIndex]
}

private func queueBuildSamples(defs: [SeriesDef], seriesMap: [String: Buskit_MetricSeries]) -> [MetricSample] {
    var samples: [MetricSample] = []
    for definition in defs {
        guard let series = seriesMap[definition.key] else { continue }
        for point in series.points {
            samples.append(MetricSample(
                series: definition.key,
                timestamp: Date(timeIntervalSince1970: TimeInterval(point.timestampUnix)),
                value: point.value
            ))
        }
    }
    return samples
}

// MARK: - Messages Tab (active & dead-letter)

@available(macOS 15.0, *)
private struct MessagesTab: View {
    @Environment(GRPCManager.self) var grpc
    @Environment(EntityActionStore.self) var actionStore
    @Environment(AppStatusModel.self) var appStatus
    @Environment(ActivityLogStore.self) var activityLog
    let queue: QueueItem
    let isDLQ: Bool
    let trigger: UUID          // change this UUID to reload
    let requestedCount: Int32

    @State private var messages: [MessageItem] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var selectedMessageIDs: Set<UUID> = []
    @State private var showRepairSheet = false
    @State private var showBulkResubmitSheet = false
    @State private var bulkResubmitDidSubmit = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false

    private var selectedMessage: MessageItem? {
        guard let id = selectedMessageIDs.first else { return nil }
        return messages.first { $0.id == id }
    }

    private var selectedMessages: [MessageItem] {
        messages.filter { selectedMessageIDs.contains($0.id) }
    }

    private var actionToolbar: some View {
        HStack(spacing: 0) {
            if isDLQ {
                Button {
                    showBulkResubmitSheet = true
                } label: {
                    let count = selectedMessageIDs.count
                    Label(count > 1 ? "Resubmit Selected (\(count))" : "Resubmit Selected",
                          systemImage: "arrow.uturn.forward")
                        .padding(.horizontal, 8).padding(.vertical, 4)
                }
                .buttonStyle(.borderless)
                .disabled(selectedMessageIDs.isEmpty)
                .help("Resubmit selected dead-letter messages, optionally stripping DLQ properties")

                toolbarDivider
            }

            if isDLQ {
                Button {
                    showRepairSheet = true
                } label: {
                    Label("Repair & Resubmit", systemImage: "wrench.and.screwdriver")
                        .padding(.horizontal, 8).padding(.vertical, 4)
                }
                .buttonStyle(.borderless)
                .disabled(selectedMessageIDs.count != 1)
                .help("Repair and resubmit the selected message")

                toolbarDivider
            }

            toolbarDivider

            Button {
                saveMessages(selectedMessages)
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
                    .padding(.horizontal, 8).padding(.vertical, 4)
            }
            .buttonStyle(.borderless)
            .disabled(selectedMessageIDs.isEmpty)
            .help("Save selected message(s) to disk")

            if isDLQ {
                Button {
                    if !selectedMessageIDs.isEmpty { showDeleteConfirm = true }
                } label: {
                    Label("Delete", systemImage: "trash")
                        .padding(.horizontal, 8).padding(.vertical, 4)
                }
                .buttonStyle(.borderless)
                .disabled(selectedMessageIDs.isEmpty)
                .help("Permanently delete selected message(s)")
            }

            Spacer()

            toolbarDivider

            Button {
                Task { await loadMessages() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .padding(.horizontal, 8).padding(.vertical, 4)
            }
            .disabled(isLoading)
            .buttonStyle(.borderless)
            .help("Refresh messages")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(.bar)
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Action toolbar ───────────────────────────────────
            actionToolbar

            Divider()

            VSplitView {
                // ── Top: message table ──────────────────────────────
                Group {
                    if isLoading {
                        ProgressView("Loading messages…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let error = loadError {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.largeTitle).foregroundStyle(.red)
                            Text(error).foregroundStyle(.secondary).font(.caption)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if messages.isEmpty {
                        Text("No \(isDLQ ? "dead-letter " : "")messages in \(queue.name)")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Table(messages, selection: $selectedMessageIDs) {
                            TableColumn("Message ID") { msg in
                                Text(msg.messageId.isEmpty ? "—" : msg.messageId)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                            }
                            .width(min: 120, ideal: 180)

                            TableColumn("Sequence") { msg in
                                Text(String(msg.sequenceNumber))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .width(min: 60, ideal: 80)

                            TableColumn("Subject") { msg in
                                Text(msg.subject.isEmpty ? "—" : msg.subject)
                                    .font(.system(.caption))
                                    .lineLimit(1)
                            }
                            .width(min: 80, ideal: 120)

                            TableColumn("Content Type") { msg in
                                Text(msg.contentType.isEmpty ? "—" : msg.contentType)
                                    .font(.system(.caption))
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                            }
                            .width(min: 80, ideal: 120)

                            TableColumn("Enqueued") { msg in
                                Text(msg.enqueuedTime, style: .relative)
                                    .font(.system(.caption, weight: .light))
                                    .foregroundStyle(Color(nsColor: .systemGray))
                                    .help(msg.enqueuedTime.formatted(
                                        date: .complete, time: .complete))
                            }
                            .width(min: 90, ideal: 110)

                            TableColumn("Deliveries") { msg in
                                DeliveryBadge(count: msg.deliveryCount)
                            }
                            .width(65)
                        }
                        .contextMenu(forSelectionType: UUID.self) { ids in
                            if isDLQ && !ids.isEmpty {
                                Button(ids.count == 1
                                       ? "Resubmit Selected Message"
                                       : "Resubmit \(ids.count) Messages") {
                                    selectedMessageIDs = ids
                                    showBulkResubmitSheet = true
                                }
                                Divider()
                            }
                            if ids.count == 1, let id = ids.first,
                               let msg = messages.first(where: { $0.id == id }) {
                                Button("Repair and Resubmit") {
                                    selectedMessageIDs = [id]
                                    showRepairSheet = true
                                }
                                Divider()
                            }
                            if !ids.isEmpty {
                                Button(ids.count == 1 ? "Save Message" : "Save \(ids.count) Messages") {
                                    saveMessages(messages.filter { ids.contains($0.id) })
                                }
                            }
                            if isDLQ && !ids.isEmpty {
                                Button(ids.count == 1
                                       ? "Delete Message"
                                       : "Delete \(ids.count) Messages",
                                       role: .destructive) {
                                    selectedMessageIDs = ids
                                    showDeleteConfirm = true
                                }
                            }
                        }
                    }
                }
                .frame(minHeight: 162)

                // ── Bottom: body + properties side by side ──────────
                HSplitView {
                    MessageBodyPanel(message: selectedMessage)
                        .frame(minWidth: 220)

                    MessagePropertiesPanel(message: selectedMessage)
                        .frame(minWidth: 220)
                }
                .frame(minHeight: 160)
            }
        }
        // Prevent the bottom panel from extending behind the status bar.
        // NSSplitView (VSplitView/HSplitView) does not automatically respect
        // SwiftUI safeAreaInset, so we add explicit bottom padding here.
        .padding(.bottom, 22)
        .task { await loadMessages() }
        .onChange(of: queue.name) { _, _ in Task { await loadMessages() } }
        .onChange(of: trigger)    { _, _ in Task { await loadMessages() } }
        .sheet(isPresented: $showRepairSheet) {
            if let msg = selectedMessage {
                RepairResubmitSheet(message: msg, queueOrTopic: queue.name)
            }
        }
        .sheet(isPresented: $showBulkResubmitSheet, onDismiss: {
            if bulkResubmitDidSubmit {
                selectedMessageIDs.removeAll()
                Task { await loadMessages() }
                bulkResubmitDidSubmit = false
            }
        }) {
            BulkResubmitSheet(messages: selectedMessages, queueOrTopic: queue.name, didResubmit: $bulkResubmitDidSubmit)
        }
        .confirmationDialog(
            selectedMessageIDs.count == 1 ? "Delete Message?" : "Delete \(selectedMessageIDs.count) Messages?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(selectedMessageIDs.count == 1 ? "Delete" : "Delete \(selectedMessageIDs.count) Messages",
                   role: .destructive) {
                Task { await deleteSelectedMessages() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if selectedMessageIDs.count == 1, let msg = selectedMessage {
                Text("Message \(msg.messageId) will be permanently removed.")
            } else {
                Text("\(selectedMessageIDs.count) messages will be permanently removed.")
            }
        }
    }

    private func loadMessages() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            messages = try await grpc.peekMessages(queueName: queue.name,
                                                   isDLQ: isDLQ,
                                                   maxCount: requestedCount)
            appStatus.lastRefreshTime   = Date()
            appStatus.visibleMessageCount = messages.count
        } catch {
            messages = []
            loadError = error.localizedDescription
        }
    }

    private func saveMessages(_ msgs: [MessageItem]) {
        guard !msgs.isEmpty else { return }

        if msgs.count == 1 {
            saveSingleMessage(msgs[0])
            return
        }

        let allJSON = msgs.allSatisfy { isValidJSONBody($0.body) }
        let panel   = NSSavePanel()
        if allJSON {
            panel.allowedContentTypes  = [.json]
            panel.nameFieldStringValue = "messages-\(msgs.count).json"
        } else {
            panel.allowedContentTypes  = [.plainText]
            panel.nameFieldStringValue = "messages-\(msgs.count).txt"
        }

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let fileData: Data
                if allJSON {
                    let objects = msgs.compactMap { msg -> Any? in
                        guard let data = msg.body.data(using: .utf8) else { return nil }
                        return try? JSONSerialization.jsonObject(with: data)
                    }
                    fileData = try JSONSerialization.data(withJSONObject: objects,
                                                         options: [.prettyPrinted, .sortedKeys])
                } else {
                    fileData = msgs.map(\.body).joined(separator: " ").data(using: .utf8) ?? Data()
                }
                try fileData.write(to: url)
                Task { @MainActor in
                    activityLog.log(action: .save, messageId: "",
                                    result: .success("Saved \(msgs.count) messages to \(url.lastPathComponent)"))
                }
            } catch {
                Task { @MainActor in
                    activityLog.log(action: .save, messageId: "",
                                    result: .failure("Save failed: \(error.localizedDescription)"),
                                    hint: "Check write permissions for the chosen location.")
                }
            }
        }
    }

    private func saveSingleMessage(_ msg: MessageItem) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "message-\(msg.messageId).json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let data: [String: Any] = [
                "id": msg.messageId,
                "sequenceNumber": msg.sequenceNumber,
                "body": msg.body,
                "contentType": msg.contentType,
                "subject": msg.subject,
                "correlationId": msg.correlationId,
                "replyTo": msg.replyTo,
                "toAddress": msg.toAddress,
                "sessionId": msg.sessionId,
                "partitionKey": msg.partitionKey,
                "deliveryCount": msg.deliveryCount,
                "enqueuedTime": ISO8601DateFormatter().string(from: msg.enqueuedTime),
                "properties": msg.properties
            ]
            do {
                let json = try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
                try json.write(to: url)
                Task { @MainActor in
                    activityLog.log(action: .save, messageId: msg.messageId,
                                    result: .success("Saved to \(url.lastPathComponent)"))
                }
            } catch {
                Task { @MainActor in
                    activityLog.log(action: .save, messageId: msg.messageId,
                                    result: .failure("Save failed: \(error.localizedDescription)"),
                                    hint: "Check write permissions for the chosen location.")
                }
            }
        }
    }

    private func isValidJSONBody(_ string: String) -> Bool {
        guard let data = string.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else { return false }
        return true
    }

    private func deleteSelectedMessages() async {
        let toDelete = selectedMessages
        guard !toDelete.isEmpty else { return }
        isDeleting = true
        defer { isDeleting = false }
        for msg in toDelete {
            do {
                try await grpc.deleteMessage(
                    queueName: queue.name,
                    isDLQ: isDLQ,
                    sequenceNumber: msg.sequenceNumber
                )
                messages.removeAll { $0.sequenceNumber == msg.sequenceNumber }
                selectedMessageIDs.remove(msg.id)
                activityLog.log(action: .delete, messageId: msg.messageId,
                                result: .success("Deleted successfully"))
            } catch {
                activityLog.log(action: .delete, messageId: msg.messageId,
                                result: .failure(error.localizedDescription),
                                hint: "The message may have already been consumed or the queue lock expired.")
            }
        }
        actionStore.requestRefresh(.queue(queue.name))
    }
}

// MARK: - Toolbar divider helper

private var toolbarDivider: some View {
    Divider()
        .frame(height: 16)
        .padding(.horizontal, 2)
}

// MARK: - Delivery badge

struct DeliveryBadge: View {
    let count: Int32
    var body: some View {
        if count > 5 {
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.red)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else if count > 1 {
            Text("\(count)")
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.orange)
        } else {
            Text("\(count)")
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Banner View

/// Inline error/warning/info/success banner that sits above the status bar
/// and pushes content up rather than overlapping it.
@available(macOS 15.0, *)
struct BannerView: View {

    enum Severity {
        case error, warning, info, success

        var borderColor: Color {
            switch self {
            case .error:   return Color(red: 1.00, green: 0.231, blue: 0.188) // #FF3B30
            case .warning: return Color(red: 1.00, green: 0.584, blue: 0.000) // #FF9500
            case .info:    return Color(red: 0.00, green: 0.439, blue: 0.788) // #0070C9
            case .success: return Color(red: 0.204, green: 0.780, blue: 0.349) // #34C759
            }
        }

        var lightBackground: Color {
            switch self {
            case .error:   return Color(red: 1.000, green: 0.949, blue: 0.949) // #FFF2F2
            case .warning: return Color(red: 1.000, green: 0.984, blue: 0.941) // #FFFBF0
            case .info:    return Color(red: 0.941, green: 0.969, blue: 1.000) // #F0F7FF
            case .success: return Color(red: 0.949, green: 1.000, blue: 0.961) // #F2FFF5
            }
        }

        var darkBackground: Color {
            switch self {
            case .error:   return Color(red: 0.227, green: 0.000, blue: 0.000) // #3A0000
            case .warning: return Color(red: 0.200, green: 0.130, blue: 0.000) // #332100
            case .info:    return Color(red: 0.000, green: 0.110, blue: 0.220) // #001C38
            case .success: return Color(red: 0.000, green: 0.180, blue: 0.050) // #002E0D
            }
        }

        var iconName: String {
            switch self {
            case .error, .warning: return "exclamationmark.triangle.fill"
            case .info:            return "info.circle.fill"
            case .success:         return "checkmark.circle.fill"
            }
        }

        var textColor: Color {
            switch self {
            case .error:   return Color(red: 0.80, green: 0.00, blue: 0.00) // #CC0000
            case .warning: return Color(red: 0.55, green: 0.30, blue: 0.00) // #8C4D00
            case .info:    return Color(red: 0.00, green: 0.28, blue: 0.56) // #004790
            case .success: return Color(red: 0.08, green: 0.44, blue: 0.18) // #14712E
            }
        }
    }

    let message: String
    let severity: Severity
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            // Left accent border
            Rectangle()
                .fill(severity.borderColor)
                .frame(width: 4)

            HStack(spacing: 8) {
                Image(systemName: severity.iconName)
                    .font(.system(size: 13))
                    .foregroundStyle(severity.borderColor)

                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(severity.textColor)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            .padding(.horizontal, 12)
        }
        .frame(minHeight: 36)
        .background(colorScheme == .dark ? severity.darkBackground : severity.lightBackground)
        .shadow(color: .black.opacity(0.10), radius: 4, x: 0, y: -2)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - JSON Syntax Highlighter

enum JSONHighlighter {

    struct Result {
        let pretty: String
        let attributed: AttributedString
    }

    /// Returns a pretty-printed, syntax-highlighted `AttributedString` when
    /// `raw` is valid JSON, or `nil` otherwise.
    static func highlight(_ raw: String) -> Result? {
        guard
            let data  = raw.data(using: .utf8),
            let obj   = try? JSONSerialization.jsonObject(with: data),
            let pData = try? JSONSerialization.data(withJSONObject: obj,
                                                    options: [.prettyPrinted, .sortedKeys]),
            let pretty = String(data: pData, encoding: .utf8)
        else { return nil }

        let ns = nsAttributed(pretty)
        let attributed = (try? AttributedString(ns, including: \.appKit))
                       ?? AttributedString(pretty)
        return Result(pretty: pretty, attributed: attributed)
    }

    // MARK: Internal helper (used by MessageBodyPanel.swift)

    static func nsAttributed(_ json: String) -> NSAttributedString {
        let monoFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize,
                                                   weight: .regular)
        let base: [NSAttributedString.Key: Any] = [
            .font:            monoFont,
            .foregroundColor: NSColor.labelColor,
        ]
        let result = NSMutableAttributedString(string: json, attributes: base)

        let pattern = #"""
        ("(?:[^"\\]|\\.)*")\s*:   # JSON key
        |("(?:[^"\\]|\\.)*")       # string value
        |-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?  # number
        |\b(true|false|null)\b     # literal
        """#

        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                    options: .allowCommentsAndWhitespace)
        else { return result }

        // Adaptive spec colors — correct for both Light and Dark mode.
        let keyColor = NSColor(name: nil) { t in
            t.name == .darkAqua
                ? NSColor(calibratedRed: 0.42, green: 0.70, blue: 1.00, alpha: 1) // lighter
                : NSColor(calibratedRed: 0.00, green: 0.44, blue: 0.79, alpha: 1) // #0070C9
        }
        let stringColor = NSColor(name: nil) { t in
            t.name == .darkAqua
                ? NSColor(calibratedRed: 1.00, green: 0.47, blue: 0.43, alpha: 1) // lighter
                : NSColor(calibratedRed: 0.77, green: 0.10, blue: 0.09, alpha: 1) // #C41A16
        }
        let numberColor = NSColor(name: nil) { t in
            t.name == .darkAqua
                ? NSColor(calibratedRed: 0.53, green: 0.60, blue: 1.00, alpha: 1) // lighter
                : NSColor(calibratedRed: 0.11, green: 0.00, blue: 0.81, alpha: 1) // #1C00CF
        }
        let boolColor = NSColor(name: nil) { t in
            t.name == .darkAqua
                ? NSColor(calibratedRed: 0.78, green: 0.52, blue: 1.00, alpha: 1) // lighter
                : NSColor(calibratedRed: 0.61, green: 0.14, blue: 0.58, alpha: 1) // #9B2393
        }

        let nsLen = (json as NSString).length
        for match in regex.matches(in: json, range: NSRange(location: 0, length: nsLen)) {
            if match.range(at: 1).location != NSNotFound {
                result.addAttribute(.foregroundColor, value: keyColor,
                                    range: match.range(at: 1))
            } else if match.range(at: 2).location != NSNotFound {
                result.addAttribute(.foregroundColor, value: stringColor,
                                    range: match.range(at: 2))
            } else if match.range(at: 3).location != NSNotFound {
                result.addAttribute(.foregroundColor, value: numberColor,
                                    range: match.range(at: 3))
            } else {
                result.addAttribute(.foregroundColor, value: boolColor,
                                    range: match.range)
            }
        }

        return result
    }
}

// MARK: - Message Properties Panel

@available(macOS 15.0, *)
struct MessagePropertiesPanel: View {
    let message: MessageItem?

    struct PropRow: Identifiable {
        let id = UUID()
        let isSystem: Bool
        let key: String
        let value: String
    }

    var rows: [PropRow] {
        guard let m = message else { return [] }
        var result: [PropRow] = []

        func sys(_ key: String, _ value: String) {
            guard !value.isEmpty else { return }
            result.append(PropRow(isSystem: true, key: key, value: value))
        }

        sys("messageId",      m.messageId)
        sys("sequenceNumber", "\(m.sequenceNumber)")
        sys("deliveryCount",  "\(m.deliveryCount)")
        sys("contentType",    m.contentType)
        sys("subject",        m.subject)
        sys("correlationId",  m.correlationId)
        sys("replyTo",        m.replyTo)
        sys("to",             m.toAddress)
        sys("sessionId",      m.sessionId)
        sys("partitionKey",   m.partitionKey)
        if m.expiresAt.timeIntervalSince1970 > 0 {
            sys("expiresAt", m.expiresAt.formatted(date: .abbreviated, time: .shortened))
        }
        for (k, v) in m.properties.sorted(by: { $0.key < $1.key }) {
            result.append(PropRow(isSystem: false, key: k, value: v))
        }
        return result
    }

    @Environment(\.colorScheme) private var colorScheme

    private var panelBackground: Color {
        colorScheme == .dark
            ? Color(red: 0x1E/255, green: 0x21/255, blue: 0x28/255)  // #1E2128
            : Color.clear
    }

    private var separatorColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color(red: 229/255, green: 229/255, blue: 234/255)      // #E5E5EA
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header ──────────────────────────────────────────
            HStack {
                Text("Properties")
                    .font(.caption)
                    .foregroundStyle(colorScheme == .dark ? Color.white : Color.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)

            Rectangle()
                .fill(separatorColor)
                .frame(height: 1)

            if rows.isEmpty {
                Text(message == nil
                     ? "Select a message to view its properties."
                     : "No properties.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                            PropRowView(row: row)
                            if idx < rows.count - 1 {
                                Rectangle()
                                    .fill(separatorColor)
                                    .frame(height: 1)
                            }
                        }
                    }
                }
            }
        }
        .background(panelBackground)
    }
}

// MARK: - PropRowView

@available(macOS 15.0, *)
private struct PropRowView: View {
    let row: MessagePropertiesPanel.PropRow

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered  = false
    @State private var isExpanded = false
    @State private var copied     = false

    // Key column is 188pt total: 12pt leading padding + 176pt text content
    private static let keyColumnWidth:  CGFloat = 176
    private static let keyLeadingPad:   CGFloat = 12
    private static let copyButtonSize:  CGFloat = 16
    private static let copyLeadingGap:  CGFloat = 8   // gap between key column edge and copy button
    private static let valueLeadingGap: CGFloat = 8   // gap between copy button and value
    private static let valueTrailingPad: CGFloat = 16

    private var borderColor: Color {
        row.isSystem
            ? Color(red: 0/255,   green: 112/255, blue: 201/255)  // #0070C9
            : Color(red: 155/255, green:  35/255, blue: 147/255)  // #9B2393
    }

    private var displayValue: String { row.value.isEmpty ? "—" : row.value }

    private var valueColor: Color {
        if row.value.isEmpty {
            return colorScheme == .dark
                ? Color.white.opacity(0.3)
                : Color(red: 199/255, green: 199/255, blue: 204/255)  // #C7C7CC
        }
        return colorScheme == .dark
            ? Color(red: 0xE8/255, green: 0xEA/255, blue: 0xF0/255)  // #E8EAF0
            : Color(red: 0,        green: 0,         blue: 0)          // #000000
    }

    private var keyColor: Color {
        colorScheme == .dark
            ? Color(red: 0x8B/255, green: 0x9B/255, blue: 0xB4/255)  // #8B9BB4
            : Color(red: 60/255,   green: 60/255,    blue: 67/255)    // #3C3C43
    }

    private var hoverBackground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.06)
            : Color(red: 242/255, green: 242/255, blue: 247/255)      // #F2F2F7
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // ── 4pt color-coded left border ───────────────────────
            Rectangle()
                .fill(borderColor)
                .frame(width: 4)

            // ── Key column: 160pt fixed (12pt pad + 148pt text) ───
            Text(row.key)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(keyColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(row.key)
                .frame(width: Self.keyColumnWidth, alignment: .leading)
                .padding(.leading, Self.keyLeadingPad)

            // ── Copy button: 16×16pt, anchored after key column ───
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.value, forType: .string)
                withAnimation(.easeInOut(duration: 0.15)) { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation(.easeInOut(duration: 0.15)) { copied = false }
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(
                        copied
                            ? Color.green
                            : Color(red: 142/255, green: 142/255, blue: 147/255)  // #8E8E93
                    )
            }
            .buttonStyle(.plain)
            .help("Copy value")
            .frame(width: Self.copyButtonSize, height: Self.copyButtonSize)
            .padding(.leading, Self.copyLeadingGap)
            .opacity(isHovered ? 1 : 0)

            // ── Value column: flexible, truncates with ellipsis ───
            Text(displayValue)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(valueColor)
                .lineLimit(isExpanded ? nil : 1)
                .truncationMode(.tail)
                .help(row.value)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, Self.valueLeadingGap)
                .padding(.trailing, Self.valueTrailingPad)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                }
        }
        .frame(minHeight: 28)
        .background(
            isHovered
                ? hoverBackground
                : Color.clear
        )
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.1),  value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: copied)
    }
}

// MARK: - Data Access Restricted View

@available(macOS 15.0, *)
struct DataAccessRestrictedView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Message Operations Restricted")
                .font(.headline)
            Text("The **Azure Service Bus Data Owner** role is required to peek, receive, or manage messages.\n\nContact your Azure administrator to assign this role.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preview

@available(macOS 15.0, *)
#Preview {
    NavigationStack {
        QueueDetailView(queue: QueueItem(name: "preview-queue", messageCount: 5, deadLetterCount: 2, status: "Active"))
            .environment(GRPCManager())
            .environment(EntityActionStore())
    }
    .frame(width: 800, height: 600)
}
