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
                Label("Overview",  systemImage: "info.circle").tag(0)
                Label("Messages",     systemImage: "list.bullet.rectangle").tag(1)
                Label("Deadletter",   systemImage: "tray.and.arrow.down").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

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
    @Environment(AppStatusModel.self) var appStatus
    @Environment(ActivityLogStore.self) var activityLog
    let subscription: SubscriptionItem
    let isDLQ: Bool
    let trigger: UUID
    let requestedCount: Int32

    @State private var messages: [MessageItem] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var selectedMessageID: UUID?
    @State private var showRepairSheet = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false

    private var selectedMessage: MessageItem? {
        messages.first { $0.id == selectedMessageID }
    }

    private var actionToolbar: some View {
        HStack(spacing: 0) {
            Button {
                showRepairSheet = true
            } label: {
                Label("Repair & Resubmit", systemImage: "wrench.and.screwdriver")
                    .padding(.horizontal, 8).padding(.vertical, 4)
            }
            .buttonStyle(.borderless)
            .disabled(selectedMessage == nil)
            .help("Repair and resubmit the selected message")

            subToolbarDivider

            Button {
                if let msg = selectedMessage { saveMessage(msg) }
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
                    .padding(.horizontal, 8).padding(.vertical, 4)
            }
            .buttonStyle(.borderless)
            .disabled(selectedMessage == nil)
            .help("Save message to disk as JSON")

            Button {
                if selectedMessage != nil { showDeleteConfirm = true }
            } label: {
                Label("Delete", systemImage: "trash")
                    .padding(.horizontal, 8).padding(.vertical, 4)
            }
            .buttonStyle(.borderless)
            .disabled(selectedMessage == nil)
            .help("Permanently delete the selected message")

            Spacer()

            subToolbarDivider

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
                        Text("No \(isDLQ ? "dead-letter " : "")messages in \(subscription.name)")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Table(messages, selection: $selectedMessageID) {
                            TableColumn("Message ID") { msg in
                                Text(msg.messageId.isEmpty ? "—" : msg.messageId)
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

                    MessagePropertiesPanel(message: selectedMessage)
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
                Text("Message \(msg.messageId) will be permanently removed.")
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
            appStatus.lastRefreshTime    = Date()
            appStatus.visibleMessageCount = messages.count
        } catch {
            messages = []
            loadError = error.localizedDescription
        }
    }

    private func saveMessage(_ msg: MessageItem) {
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

    private func deleteSelectedMessage() async {
        guard let msg = selectedMessage else { return }
        isDeleting = true
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
            activityLog.log(action: .delete, messageId: msg.messageId,
                            result: .success("Deleted successfully"))
        } catch {
            activityLog.log(action: .delete, messageId: msg.messageId,
                            result: .failure(error.localizedDescription),
                            hint: "The message may have already been consumed or the subscription lock expired.")
        }
    }
}

// MARK: - Toolbar divider helper (local to this file)

private var subToolbarDivider: some View {
    Divider()
        .frame(height: 16)
        .padding(.horizontal, 2)
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
