import SwiftUI

// MARK: - Dead-letter property keys offered for stripping

private let dlqStripCandidates: [String] = [
    "DeadLetterErrorDescription",
    "DeadLetterReason",
    "Diagnostic-Id"
]

// MARK: - BulkResubmitSheet

/// Sheet for resubmitting one or more dead-letter messages with optional
/// property stripping and optional deletion after resubmit. Sends each
/// message individually via gRPC and reports per-message success / failure.
@available(macOS 15.0, *)
struct BulkResubmitSheet: View {
    @Environment(GRPCManager.self) var grpc
    @Environment(\.dismiss) var dismiss
    @Environment(ActivityLogStore.self) var activityLog
    @Environment(EntityActionStore.self) var actionStore

    let messages: [MessageItem]
    let entityName: String
    /// Non-nil when the source is a topic subscription (used for delete-after-resubmit).
    let subscriptionName: String?
    /// Set to `true` when the user confirms a resubmit (not on cancel).
    @Binding var didResubmit: Bool

    @State private var targetDestination: String
    @State private var propertiesToStrip: Set<String> = Set(dlqStripCandidates)
    @State private var deleteAfterResubmit = false
    @State private var availableQueues: [Buskit_QueueInfo] = []
    @State private var availableTopics: [Buskit_TopicInfo] = []
    @State private var isLoadingDestinations = false

    @State private var isSending = false
    @State private var sentCount  = 0

    init(messages: [MessageItem], queueOrTopic: String, subscriptionName: String? = nil, didResubmit: Binding<Bool> = .constant(false)) {
        self.messages         = messages
        self.entityName       = queueOrTopic
        self.subscriptionName = subscriptionName
        _didResubmit          = didResubmit
        _targetDestination    = State(initialValue: queueOrTopic)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    destinationSection
                    propertiesSection
                    deleteAfterResubmitSection
                }
                .padding(20)
            }
            Divider()
            footerView
        }
        .frame(width: 500)
        .task { await loadDestinations() }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Resubmit Dead-Letter Messages")
                    .font(.headline)
                Text(messages.count == 1
                     ? "1 message selected"
                     : "\(messages.count) messages selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Destination

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Destination", systemImage: "arrow.right.circle")
                .font(.subheadline).fontWeight(.medium)

            VStack(alignment: .leading, spacing: 4) {
                Text("Target Queue or Topic")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 4) {
                    TextField("Queue or topic name", text: $targetDestination)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isSending)

                    Menu {
                        if isLoadingDestinations {
                            Text("Loading…").foregroundStyle(.secondary)
                        } else {
                            if !availableQueues.isEmpty {
                                Section("Queues") {
                                    ForEach(availableQueues, id: \.name) { q in
                                        Button(q.name) { targetDestination = q.name }
                                    }
                                }
                            }
                            if !availableTopics.isEmpty {
                                Section("Topics") {
                                    ForEach(availableTopics, id: \.name) { t in
                                        Button(t.name) { targetDestination = t.name }
                                    }
                                }
                            }
                            if availableQueues.isEmpty && availableTopics.isEmpty {
                                Text("No entities found").foregroundStyle(.secondary)
                            }
                        }
                    } label: {
                        if isLoadingDestinations {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 28, height: 22)
                    .disabled(isLoadingDestinations || isSending)
                    .help("Choose from available queues and topics")
                    .accessibilityLabel("Select destination")
                }
            }
        }
    }

    // MARK: - Properties to Strip

    private var propertiesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Properties to Remove", systemImage: "tag.slash")
                .font(.subheadline).fontWeight(.medium)

            Text("The checked properties will be stripped from all messages before resubmitting.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(dlqStripCandidates, id: \.self) { key in
                    Toggle(isOn: Binding(
                        get: { propertiesToStrip.contains(key) },
                        set: { on in
                            if on { propertiesToStrip.insert(key) }
                            else  { propertiesToStrip.remove(key) }
                        }
                    )) {
                        Text(key)
                            .font(.system(.body, design: .monospaced))
                    }
                    .disabled(isSending)
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
    }

    // MARK: - Delete After Resubmit

    private var deleteAfterResubmitSection: some View {
        Toggle(isOn: $deleteAfterResubmit) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Delete from dead-letter after resubmit")
                    .font(.body)
                Text("Successfully resubmitted messages will also be removed from the dead-letter queue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(isSending)
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack(spacing: 8) {
            if isSending {
                ProgressView().controlSize(.small)
                Text("Resubmitting \(sentCount) of \(messages.count)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            Button("Cancel") { dismiss() }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(isSending)

            let label = messages.count == 1 ? "Resubmit Message" : "Resubmit \(messages.count) Messages"
            Button(label) { Task { await resubmitAll() } }
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitDisabled)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var isSubmitDisabled: Bool {
        isSending || targetDestination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Logic

    private func loadDestinations() async {
        isLoadingDestinations = true
        defer { isLoadingDestinations = false }
        do {
            async let queues = grpc.listQueues()
            async let topics = grpc.listTopics()
            availableQueues = try await queues
            availableTopics = try await topics
        } catch { }
    }

    private func resubmitAll() async {
        isSending = true
        sentCount = 0
        let dest  = targetDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        var failureCount = 0

        for msg in messages {
            let filteredProps = msg.properties.filter { !propertiesToStrip.contains($0.key) }
            do {
                _ = try await grpc.sendMessageExtended(
                    queueOrTopic:  dest,
                    body:          msg.body,
                    contentType:   msg.contentType,
                    subject:       msg.subject,
                    correlationID: msg.correlationId,
                    replyTo:       msg.replyTo,
                    toAddress:     msg.toAddress,
                    sessionID:     msg.sessionId,
                    partitionKey:  msg.partitionKey,
                    properties:    filteredProps
                )
                sentCount += 1

                if deleteAfterResubmit {
                    try await deleteFromDLQ(msg)
                }
            } catch {
                failureCount += 1
                activityLog.log(action: .resubmit, messageId: msg.messageId,
                                result: .failure(error.localizedDescription),
                                hint: "Verify the target destination exists and you have sender permissions.")
            }
        }

        isSending = false

        // Show one summary toast for successes, then close the sheet.
        if sentCount > 0 {
            let summary = sentCount == messages.count
                ? (sentCount == 1 ? "Resubmitted to \(dest)" : "All \(sentCount) messages resubmitted to \(dest)")
                : "\(sentCount) of \(messages.count) messages resubmitted to \(dest)"
            activityLog.log(action: .resubmit,
                            messageId: sentCount == 1 ? (messages.first?.messageId ?? "") : "",
                            result: .success(summary))
        }

        if availableQueues.contains(where: { $0.name == dest }) {
            actionStore.requestRefresh(.queue(dest))
        }
        if let sub = subscriptionName {
            actionStore.requestRefresh(.subscription(topic: entityName, sub: sub))
        } else {
            actionStore.requestRefresh(.queue(entityName))
        }

        didResubmit = true
        dismiss()
    }

    private func deleteFromDLQ(_ msg: MessageItem) async throws {
        if let sub = subscriptionName {
            try await grpc.deleteMessage(
                topicName:        entityName,
                subscriptionName: sub,
                isDLQ:            true,
                sequenceNumber:   msg.sequenceNumber
            )
        } else {
            try await grpc.deleteMessage(
                queueName:      entityName,
                isDLQ:          true,
                sequenceNumber: msg.sequenceNumber
            )
        }
        activityLog.log(action: .delete, messageId: msg.messageId,
                        result: .success("Deleted from dead-letter after resubmit"))
    }
}
