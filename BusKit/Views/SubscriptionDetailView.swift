import SwiftUI
import UniformTypeIdentifiers

@available(macOS 15.0, *)
struct SubscriptionDetailView: View {
    @Environment(GRPCManager.self) var grpc
    @Environment(EntityActionStore.self) var actionStore
    let subscription: SubscriptionItem

    @State private var selectedTab = 0

    // Trigger state for each messages tab
    @State private var messagesTrigger     = UUID()
    @State private var messagesCount: Int32 = 10
    @State private var dlqTrigger          = UUID()
    @State private var dlqCount: Int32      = 10

    private var entityKey: String {
        EntityActionStore.subscriptionKey(topic: subscription.topicName, sub: subscription.name)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Label("Description",  systemImage: "info.circle").tag(0)
                Label("Messages",     systemImage: "list.bullet.rectangle").tag(1)
                Label("Deadletter",   systemImage: "tray.and.arrow.down").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            Group {
                switch selectedTab {
                case 1:
                    if grpc.rbacAccessLevel.hasDataAccess {
                        SubMessagesTab(subscription: subscription, isDLQ: false,
                                       trigger: messagesTrigger, requestedCount: messagesCount)
                    } else {
                        DataAccessRestrictedView()
                    }
                case 2:
                    if grpc.rbacAccessLevel.hasDataAccess {
                        SubMessagesTab(subscription: subscription, isDLQ: true,
                                       trigger: dlqTrigger, requestedCount: dlqCount)
                    } else {
                        DataAccessRestrictedView()
                    }
                default:
                    SubDescriptionTab(subscription: subscription)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("\(subscription.topicName) / \(subscription.name)")
        .onChange(of: actionStore.pendingAction) { _, action in
            guard let action, action.entityKey == entityKey else { return }
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

// MARK: - Description Tab

@available(macOS 15.0, *)
private struct SubDescriptionTab: View {
    @Environment(GRPCManager.self) var grpc
    let subscription: SubscriptionItem

    @State private var details: SubscriptionDetailsItem?
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
                            LabeledContent("Topic",        value: subscription.topicName)
                            LabeledContent("Subscription", value: d.name)
                            LabeledContent("Status",       value: d.status)
                        }

                        Section("Configuration") {
                            LabeledContent("Default TTL",        value: formatDuration(d.defaultMessageTtlSeconds))
                            LabeledContent("Lock Duration",       value: formatDuration(d.lockDurationSeconds))
                            LabeledContent("Max Delivery Count",  value: "\(d.maxDeliveryCount)")
                            LabeledContent("Auto Delete on Idle", value: formatDuration(d.autoDeleteOnIdleSeconds))
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
                        }
                    }
                    .formStyle(.grouped)
                    .padding(.bottom)
                }
            }
        }
        .task { await loadDetails() }
        .onChange(of: subscription.name) { _, _ in Task { await loadDetails() } }
    }

    private func loadDetails() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            details = try await grpc.getSubscriptionProperties(
                topicName: subscription.topicName, subscriptionName: subscription.name)
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
private struct SubMessagesTab: View {
    @Environment(GRPCManager.self) var grpc
    @Environment(EntityActionStore.self) var actionStore
    let subscription: SubscriptionItem
    let isDLQ: Bool
    let trigger: UUID
    let requestedCount: Int32

    @State private var messages: [MessageItem] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var selectedMessageID: String?
    @State private var showRepairSheet = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var deleteError: String?

    private var selectedMessage: MessageItem? {
        messages.first { $0.id == selectedMessageID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    showRepairSheet = true
                } label: {
                    Label("Repair and Resubmit", systemImage: "wrench.and.screwdriver")
                }
                .buttonStyle(.borderless)
                .disabled(selectedMessage == nil)
                .help("Repair and resubmit the selected message")

                Spacer()

                Button {
                    Task { await loadMessages() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
                .buttonStyle(.borderless)
                .padding(.horizontal, 8)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.bar)

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
                        Text("No \(isDLQ ? "dead-letter " : "")messages in \(subscription.name)")
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
                        .contextMenu(forSelectionType: String.self) { ids in
                            if let id = ids.first, let msg = messages.first(where: { $0.id == id }) {
                                Button("Repair and Resubmit Selected Message") {
                                    selectedMessageID = id
                                    showRepairSheet = true
                                }
                                Divider()
                                Button("Save Selected Message") {
                                    saveMessage(msg)
                                }
                                Button("Delete Selected Message", role: .destructive) {
                                    selectedMessageID = id
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

                    SubMessagePropertiesPanel(message: selectedMessage)
                        .frame(minWidth: 220)
                }
                .frame(minHeight: 160)
            }
        }
        .task { await loadMessages() }
        .onChange(of: subscription.name) { _, _ in Task { await loadMessages() } }
        .onChange(of: trigger)           { _, _ in Task { await loadMessages() } }
        .sheet(isPresented: $showRepairSheet) {
            if let msg = selectedMessage {
                RepairResubmitSheet(message: msg, queueOrTopic: subscription.topicName)
            }
        }
        .confirmationDialog(
            "Delete Message?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await deleteSelectedMessage() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let msg = selectedMessage {
                Text("Sequence #\(msg.sequenceNumber) will be permanently removed.")
            }
        }
        .overlay(alignment: .bottom) {
            if let err = deleteError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(err).font(.caption).foregroundStyle(.red)
                    Spacer()
                    Button("Dismiss") { deleteError = nil }.font(.caption)
                }
                .padding(8)
                .background(.bar)
            }
        }
    }

    private func loadMessages() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            messages = try await grpc.peekMessages(
                topicName: subscription.topicName,
                subscriptionName: subscription.name,
                isDLQ: isDLQ,
                maxCount: requestedCount)
        } catch {
            messages = []
            loadError = error.localizedDescription
        }
    }

    private func saveMessage(_ msg: MessageItem) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "message-\(msg.sequenceNumber).json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let data: [String: Any] = [
                "id": msg.id,
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
            if let json = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) {
                try? json.write(to: url)
            }
        }
    }

    private func deleteSelectedMessage() async {
        guard let msg = selectedMessage else { return }
        isDeleting = true
        deleteError = nil
        defer { isDeleting = false }
        do {
            try await grpc.deleteMessage(
                topicName: subscription.topicName,
                subscriptionName: subscription.name,
                isDLQ: isDLQ,
                sequenceNumber: msg.sequenceNumber
            )
            messages.removeAll { $0.id == msg.id }
            selectedMessageID = nil
            actionStore.requestRefresh(.subscription(topic: subscription.topicName, sub: subscription.name))
        } catch {
            deleteError = error.localizedDescription
        }
    }
}

// MARK: - Properties Panel

@available(macOS 15.0, *)
private struct SubMessagePropertiesPanel: View {
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
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading).background(.bar)

            Divider()

            if rows.isEmpty {
                Text(message == nil ? "Select a message to view its properties." : "No properties.")
                    .foregroundStyle(.secondary).font(.caption)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).padding(12)
            } else {
                Table(rows) {
                    TableColumn("Kind") { row in
                        Text(row.kind).font(.caption)
                            .foregroundStyle(row.kind == "System" ? .blue : .purple)
                    }
                    .width(45)

                    TableColumn("Key") { row in
                        Text(row.key).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .width(min: 80, ideal: 140)

                    TableColumn("Value") { row in
                        Text(row.value).font(.caption).lineLimit(1)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

// MARK: - Data Access Restricted View

@available(macOS 15.0, *)
private struct DataAccessRestrictedView: View {
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
        SubscriptionDetailView(subscription: SubscriptionItem(
            topicName: "orders",
            name: "fulfillment",
            activeMessageCount: 3,
            deadLetterCount: 1))
            .environment(GRPCManager())
            .environment(EntityActionStore())
    }
    .frame(width: 800, height: 600)
}
