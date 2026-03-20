import SwiftUI

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
        TabView(selection: $selectedTab) {
            DescriptionTab(queue: queue)
                .tabItem { Label("Description", systemImage: "info.circle") }
                .tag(0)

            MessagesTab(queue: queue, isDLQ: false, trigger: messagesTrigger, requestedCount: messagesCount)
                .tabItem { Label("Messages", systemImage: "list.bullet.rectangle") }
                .tag(1)

            MessagesTab(queue: queue, isDLQ: true, trigger: dlqTrigger, requestedCount: dlqCount)
                .tabItem { Label("Deadletter Messages", systemImage: "tray.and.arrow.down") }
                .tag(2)
        }
        .navigationTitle(queue.name)
        .onChange(of: actionStore.pendingAction) { _, action in
            guard let action, action.entityKey == EntityActionStore.queueKey(queue.name) else { return }
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

// MARK: - Description Tab

@available(macOS 15.0, *)
private struct DescriptionTab: View {
    @Environment(GRPCManager.self) var grpc
    let queue: QueueItem

    @State private var details: QueueDetailsItem?
    @State private var isLoading = true
    @State private var errorMessage: String?

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
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let d = details {
                ScrollView {
                    Form {
                        Section("Identity") {
                            LabeledContent("Name", value: d.name)
                            LabeledContent("Status", value: d.status)
                        }

                        Section("Configuration") {
                            LabeledContent("Max Size", value: "\(d.maxSizeMb) MB")
                            LabeledContent("Default TTL", value: formatDuration(d.defaultMessageTtlSeconds))
                            LabeledContent("Lock Duration", value: formatDuration(d.lockDurationSeconds))
                            LabeledContent("Max Delivery Count", value: "\(d.maxDeliveryCount)")
                            LabeledContent("Auto Delete on Idle", value: formatDuration(d.autoDeleteOnIdleSeconds))
                            LabeledContent("Requires Duplicate Detection") {
                                Text(d.requiresDuplicateDetection ? "Yes" : "No")
                                    .foregroundStyle(d.requiresDuplicateDetection ? .primary : .secondary)
                            }
                            LabeledContent("Requires Session") {
                                Text(d.requiresSession ? "Yes" : "No")
                                    .foregroundStyle(d.requiresSession ? .primary : .secondary)
                            }
                            LabeledContent("Dead Letter on Expiration") {
                                Text(d.deadLetteringOnExpiration ? "Yes" : "No")
                                    .foregroundStyle(d.deadLetteringOnExpiration ? .orange : .secondary)
                            }
                            if !d.forwardTo.isEmpty {
                                LabeledContent("Forward To", value: d.forwardTo)
                            }
                        }

                        Section("Statistics") {
                            LabeledContent("Active Messages") {
                                Text("\(d.activeMessageCount)").foregroundStyle(.blue)
                            }
                            LabeledContent("Dead Letter") {
                                Text("\(d.deadLetterCount)")
                                    .foregroundStyle(d.deadLetterCount > 0 ? .red : .secondary)
                            }
                            LabeledContent("Size") {
                                Text(ByteCountFormatter.string(fromByteCount: d.sizeBytes, countStyle: .file))
                            }
                            LabeledContent("Created", value: d.createdAt.formatted(date: .abbreviated, time: .shortened))
                            LabeledContent("Updated", value: d.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                    .formStyle(.grouped)
                    .padding(.bottom)
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func formatDuration(_ seconds: Int64) -> String {
        guard seconds > 0 else { return "—" }
        let days    = seconds / 86_400
        let hours   = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        let secs    = seconds % 60
        var parts: [String] = []
        if days    > 0 { parts.append("\(days)d") }
        if hours   > 0 { parts.append("\(hours)h") }
        if minutes > 0 { parts.append("\(minutes)m") }
        if secs    > 0 { parts.append("\(secs)s") }
        return parts.joined(separator: " ")
    }
}

// MARK: - Messages Tab (active & dead-letter)

@available(macOS 15.0, *)
private struct MessagesTab: View {
    @Environment(GRPCManager.self) var grpc
    let queue: QueueItem
    let isDLQ: Bool
    let trigger: UUID          // change this UUID to reload
    let requestedCount: Int32

    @State private var messages: [MessageItem] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var selectedMessageID: String?

    private var selectedMessage: MessageItem? {
        messages.first { $0.id == selectedMessageID }
    }

    var body: some View {
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
                    Table(messages, selection: $selectedMessageID) {
                        TableColumn("#") { msg in
                            Text("\(msg.sequenceNumber)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .width(55)

                        TableColumn("Message ID") { msg in
                            Text(msg.id.isEmpty ? "—" : msg.id)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                        }
                        .width(min: 120, ideal: 180)

                        TableColumn("Subject") { msg in
                            Text(msg.subject.isEmpty ? "—" : msg.subject)
                                .lineLimit(1)
                        }
                        .width(min: 80, ideal: 120)

                        TableColumn("Content Type") { msg in
                            Text(msg.contentType.isEmpty ? "—" : msg.contentType)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                        .width(min: 80, ideal: 120)

                        TableColumn("Enqueued") { msg in
                            Text(msg.enqueuedTime, style: .relative)
                                .foregroundStyle(.secondary)
                        }
                        .width(min: 90, ideal: 110)

                        TableColumn("Deliveries") { msg in
                            Text("\(msg.deliveryCount)")
                                .monospacedDigit()
                                .foregroundStyle(msg.deliveryCount > 1 ? .orange : .secondary)
                        }
                        .width(65)
                    }
                }
            }
            .frame(minHeight: 140)

            // ── Bottom: body + properties side by side ──────────
            HSplitView {
                MessageBodyPanel(message: selectedMessage)
                    .frame(minWidth: 220)

                MessagePropertiesPanel(message: selectedMessage)
                    .frame(minWidth: 220)
            }
            .frame(minHeight: 160)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await loadMessages() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .task { await loadMessages() }
        .onChange(of: queue.name) { _, _ in Task { await loadMessages() } }
        .onChange(of: trigger)    { _, _ in Task { await loadMessages() } }
    }

    private func loadMessages() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            messages = try await grpc.peekMessages(queueName: queue.name,
                                                   isDLQ: isDLQ,
                                                   maxCount: requestedCount)
        } catch {
            messages = []
            loadError = error.localizedDescription
        }
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

        let nsLen = (json as NSString).length
        for match in regex.matches(in: json, range: NSRange(location: 0, length: nsLen)) {
            if match.range(at: 1).location != NSNotFound {
                result.addAttribute(.foregroundColor, value: NSColor.systemBlue,
                                    range: match.range(at: 1))
            } else if match.range(at: 2).location != NSNotFound {
                result.addAttribute(.foregroundColor, value: NSColor.systemGreen,
                                    range: match.range(at: 2))
            } else if match.range(at: 3).location != NSNotFound {
                result.addAttribute(.foregroundColor, value: NSColor.systemOrange,
                                    range: match.range(at: 3))
            } else {
                result.addAttribute(.foregroundColor, value: NSColor.systemTeal,
                                    range: match.range)
            }
        }

        return result
    }
}

// MARK: - Message Properties Panel

@available(macOS 15.0, *)
private struct MessagePropertiesPanel: View {
    let message: MessageItem?

    private struct PropRow: Identifiable {
        let id = UUID()
        let kind: String
        let key: String
        let value: String
    }

    private var rows: [PropRow] {
        guard let m = message else { return [] }
        var result: [PropRow] = []

        func sys(_ key: String, _ value: String) {
            guard !value.isEmpty else { return }
            result.append(PropRow(kind: "System", key: key, value: value))
        }

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
            result.append(PropRow(kind: "Custom", key: k, value: v))
        }

        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Properties")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)

            Divider()

            if rows.isEmpty {
                Text(message == nil
                     ? "Select a message to view its properties."
                     : "No properties.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
            } else {
                Table(rows) {
                    TableColumn("Kind") { row in
                        Text(row.kind)
                            .font(.caption)
                            .foregroundStyle(row.kind == "System" ? .blue : .purple)
                    }
                    .width(45)

                    TableColumn("Key") { row in
                        Text(row.key)
                            .font(.system(.caption, design: .monospaced))
                    }
                    .width(min: 80, ideal: 140)

                    TableColumn("Value") { row in
                        Text(row.value)
                            .font(.caption)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

// MARK: - Preview

@available(macOS 15.0, *)
#Preview {
    NavigationStack {
        QueueDetailView(queue: QueueItem(name: "preview-queue", messageCount: 5, deadLetterCount: 2))
            .environment(GRPCManager())
            .environment(EntityActionStore())
    }
    .frame(width: 800, height: 600)
}
