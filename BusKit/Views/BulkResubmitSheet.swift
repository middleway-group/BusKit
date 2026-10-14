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
    /// `true` when the messages come from the dead-letter sub-queue.
    let isDeadLetter: Bool
    /// Set to `true` when the user confirms a resubmit (not on cancel).
    @Binding var didResubmit: Bool

    @State private var targetDestination: String
    @State private var propertiesToStrip: Set<String> = Set(dlqStripCandidates.filter { $0 != "Diagnostic-Id" })
    @State private var deleteAfterResubmit = false
    @State private var generateNewMessageID = false
    @State private var availableQueues: [Buskit_QueueInfo] = []
    @State private var availableTopics: [Buskit_TopicInfo] = []
    @State private var isLoadingDestinations = false

    @State private var isSending = false
    @State private var sentCount  = 0
    @State private var isCancelling = false
    @State private var isRemoving = false
    @State private var sendTask: Task<Void, Never>?

    init(messages: [MessageItem], queueOrTopic: String, subscriptionName: String? = nil, isDeadLetter: Bool = true, didResubmit: Binding<Bool> = .constant(false)) {
        self.messages         = messages
        self.entityName       = queueOrTopic
        self.subscriptionName = subscriptionName
        self.isDeadLetter     = isDeadLetter
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
                    if isDeadLetter { propertiesSection }
                    generateNewMessageIDSection
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
                Text(isDeadLetter ? "Resubmit Dead-Letter Messages" : "Resubmit Messages")
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

    // MARK: - Generate New Message ID

    private var generateNewMessageIDSection: some View {
        Toggle(isOn: $generateNewMessageID) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Generate new Message ID")
                    .font(.body)
                Text("Each resubmitted message will receive a freshly generated Message ID instead of keeping the original.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(isSending)
    }

    // MARK: - Delete After Resubmit

    private var deleteAfterResubmitSection: some View {
        Toggle(isOn: $deleteAfterResubmit) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isDeadLetter ? "Delete from dead-letter after resubmit" : "Remove original after resubmit")
                    .font(.body)
                Text(isDeadLetter
                     ? "Successfully resubmitted messages will also be removed from the dead-letter queue."
                     : "Successfully resubmitted messages will also be removed (completed) from the source. Resubmitting to a topic delivers to all of its subscriptions.")
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
                Text(isCancelling ? "Stopping…" : isRemoving ? "Removing originals from the source…" : "Resubmitting \(sentCount) of \(messages.count)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            Button(isSending ? "Stop" : "Cancel") {
                if isSending { isCancelling = true; sendTask?.cancel() } else { dismiss() }
            }
            .keyboardShortcut(.escape, modifiers: [])
            .disabled(isCancelling)

            let label = messages.count == 1 ? "Resubmit Message" : "Resubmit \(messages.count) Messages"
            Button(label) { sendTask = Task { await resubmitAll() } }
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
        isCancelling = false
        let dest  = targetDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        var failureCount = 0
        var firstError: String?
        var pendingDeletes: [MessageItem] = []

        for msg in messages {
            if isCancelling || Task.isCancelled { break }
            let filteredProps = isDeadLetter
                ? msg.properties.filter { !propertiesToStrip.contains($0.key) }
                : msg.properties
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
                    messageID:     generateNewMessageID ? "" : msg.messageId,
                    properties:    filteredProps
                )
                sentCount += 1

                if deleteAfterResubmit {
                    pendingDeletes.append(msg)
                    if pendingDeletes.count >= 500 { await flushDeletes(&pendingDeletes) }
                }
            } catch {
                if isCancelling || Task.isCancelled { break }
                failureCount += 1
                if firstError == nil { firstError = error.localizedDescription }
            }
        }

        if isCancelling || Task.isCancelled {
            // Clean up already-sent originals without keeping the sheet waiting.
            let leftover = pendingDeletes
            Task { var rest = leftover; await flushDeletes(&rest) }
        } else {
            await flushDeletes(&pendingDeletes)
        }

        isSending = false
        let wasCancelled = isCancelling
        isCancelling = false

        if failureCount > 0 {
            activityLog.log(action: .resubmit, messageId: "",
                            result: .failure("\(failureCount) message\(failureCount == 1 ? "" : "s") failed to resubmit: \(firstError ?? "unknown error")"),
                            hint: "Verify the target destination exists and you have sender permissions.")
        }

        // Show one summary toast for successes, then close the sheet.
        if sentCount > 0 {
            let summary = wasCancelled
                ? "Stopped: \(sentCount) of \(messages.count) messages resubmitted to \(dest)"
                : sentCount == messages.count
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

    /// Removes already-resubmitted originals. Session messages are deleted one by one
    /// (they need a session receiver); everything else goes through one bulk pass.
    private func flushDeletes(_ pending: inout [MessageItem]) async {
        let batch = pending
        pending.removeAll()
        guard !batch.isEmpty else { return }
        isRemoving = true
        defer { isRemoving = false }

        let sessionMessages = batch.filter { !$0.sessionId.isEmpty }
        let plain = batch.filter { $0.sessionId.isEmpty }
        var notFound = Set<Int64>()

        for msg in sessionMessages {
            do {
                try await grpc.deleteMessage(
                    queueName:        subscriptionName == nil ? entityName : nil,
                    topicName:        subscriptionName == nil ? nil : entityName,
                    subscriptionName: subscriptionName,
                    isDLQ:            isDeadLetter,
                    sequenceNumber:   msg.sequenceNumber,
                    sessionId:        msg.sessionId)
            } catch { notFound.insert(msg.sequenceNumber) }
        }

        if !plain.isEmpty {
            do {
                let missing = try await grpc.deleteMessages(
                    queueName:        subscriptionName == nil ? entityName : nil,
                    topicName:        subscriptionName == nil ? nil : entityName,
                    subscriptionName: subscriptionName,
                    isDLQ:            isDeadLetter,
                    sequenceNumbers:  plain.map(\.sequenceNumber))
                notFound.formUnion(missing)
            } catch {
                notFound.formUnion(plain.map(\.sequenceNumber))
            }
        }

        if !notFound.isEmpty {
            activityLog.log(action: .delete, messageId: "",
                            result: .failure("\(notFound.count) resubmitted original\(notFound.count == 1 ? "" : "s") could not be removed"),
                            hint: "The messages were already sent to the destination; remove the originals manually to avoid duplicates.")
        }
        let removed = batch.count - notFound.count
        if removed > 0 {
            activityLog.log(action: .delete, messageId: "",
                            result: .success(isDeadLetter
                                ? "Deleted \(removed) from dead-letter after resubmit"
                                : "Deleted \(removed) originals after resubmit"))
        }
    }
}
