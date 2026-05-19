import SwiftUI

// MARK: - Loading state

private enum LoadState<T> {
    case loading
    case loaded(T)
    case failed(String)
}

extension LoadState: Equatable where T: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading):           return true
        case (.loaded(let a), .loaded(let b)): return a == b
        case (.failed(let a), .failed(let b)): return a == b
        default:                             return false
        }
    }
}

// MARK: - Message count badge

private struct MessageCountBadge: View {
    let active: Int64
    let deadLetter: Int64

    var body: some View {
        HStack(spacing: 4) {
            if active > 0 {
                pill(label: "\(active)", fg: .blue, bg: Color.blue.opacity(0.1))
            }
            if deadLetter > 0 {
                pill(label: "\(deadLetter)", fg: .red, bg: Color.red.opacity(0.1))
            }
        }
    }

    private func pill(label: String, fg: Color, bg: Color) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(bg)
            .foregroundStyle(fg)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Sidebar data model

@available(macOS 15.0, *)
@Observable
private final class SidebarModel {
    // List data
    var queues: [QueueItem] = []
    var topics: [TopicItem] = []
    var subscriptions: [String: LoadState<[SubscriptionItem]>] = [:]
    var rules: [String: LoadState<[RuleItem]>] = [:]
    var isLoading = false

    // Context-menu dialog state (hoisted here so sheet/alert live on the List)
    var contextTarget: SidebarSelection? = nil
    var showReceiveSheet   = false
    var receiveIsDLQ       = false
    var receiveCount       = 10
    var showPurgeAlert     = false
    var purgeIsDLQ         = false
    var showPurgeResult    = false
    var purgeResultTitle   = ""
    var purgeResultMessage = ""

    // Rule operation state
    var ruleOpTarget: (rule: RuleItem, sub: SubscriptionItem)? = nil
    var showEditRuleSheet    = false
    var editRuleFilter       = ""
    var editRuleError: String? = nil
    var isEditingRule        = false
    var showDeleteRuleConfirm = false
    var isDeletingRule       = false

    // Add Rule state
    var showAddRuleSheet  = false
    var addRuleTarget: SubscriptionItem? = nil
    var addRuleName   = ""
    var addRuleFilter = ""
    var addRuleError: String? = nil
    var isAddingRule  = false

    // Create Queue state
    var showCreateQueueSheet = false

    // Delete Queue state
    var deleteQueueTarget: QueueItem? = nil
    var showDeleteQueueConfirm = false
    var isDeletingQueue = false

    // Create Topic state
    var showCreateTopicSheet = false

    // Create Subscription state
    var showCreateSubscriptionSheet = false
    var createSubscriptionTopic: TopicItem? = nil

    // Delete Subscription state
    var deleteSubscriptionTarget: SubscriptionItem? = nil
    var showDeleteSubscriptionConfirm = false
    var isDeletingSubscription = false

    // Delete Topic state
    var deleteTopicTarget: TopicItem? = nil
    var showDeleteTopicConfirm = false
    var isDeletingTopic = false

    // Disable/Enable Topic state
    var disableTopicTarget: TopicItem? = nil
    var showDisableTopicConfirm = false
    var isSettingTopicStatus = false
}

// MARK: - Receive Count Dialog

@available(macOS 15.0, *)
private struct ReceiveCountDialog: View {
    let isDLQ: Bool
    @Binding var count: Int
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isDLQ ? "Receive Deadletter Messages" : "Receive Messages")
                .font(.headline)

            Divider()

            HStack {
                Text("Number of messages:")
                Spacer()
                TextField("", value: $count, format: .number)
                    .frame(width: 64)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                Stepper("", value: $count, in: 1...1000)
                    .labelsHidden()
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Button("Receive") { onConfirm(); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
            }
        }
        .padding()
        .frame(width: 340)
    }
}

// MARK: - SidebarView

@available(macOS 15.0, *)
struct SidebarView: View {
    @Environment(GRPCManager.self) var grpc
    @Environment(EntityActionStore.self) var actionStore
    @Environment(ActivityLogStore.self) var activityLog
    @Binding var selection: SidebarSelection?
    @State private var model = SidebarModel()
    @State private var namespaceExpanded = true
    @State private var queuesExpanded    = true
    @State private var topicsExpanded    = true

    // Queues sorted alphabetically.
    private var sortedQueues: [QueueItem] {
        model.queues.sorted { $0.name < $1.name }
    }

    var body: some View {
        List(selection: $selection) {
            if model.isLoading && model.queues.isEmpty && model.topics.isEmpty {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading…").foregroundStyle(.secondary)
                }
            }

            if grpc.connectionState == .connected || !model.queues.isEmpty || !model.topics.isEmpty {
                DisclosureGroup(isExpanded: $namespaceExpanded) {

                    // ── Queues ──────────────────────────────────────
                    DisclosureGroup(isExpanded: $queuesExpanded) {
                        if model.queues.isEmpty && !model.isLoading {
                            Text("No queues found.")
                                .foregroundStyle(.secondary).font(.caption)
                        } else {
                            ForEach(sortedQueues) { queue in
                                HStack {
                                    Label(queue.name, systemImage: "tray")
                                    Spacer()
                                    MessageCountBadge(
                                        active: queue.messageCount,
                                        deadLetter: queue.deadLetterCount)
                                }
                                .opacity(queue.status == "Active" || queue.status.isEmpty ? 1.0 : 0.4)
                                .tag(SidebarSelection.queue(queue))
                                .contextMenu {
                                    queueContextMenu(for: queue)
                                }
                            }
                        }
                    } label: {
                        Label("Queues", systemImage: "tray.full")
                            .contextMenu {
                                Button("Create Queue") {
                                    model.showCreateQueueSheet = true
                                }
                                .disabled(!grpc.capabilityMap.createResources)
                            }
                    }

                    // ── Topics ──────────────────────────────────────
                    DisclosureGroup(isExpanded: $topicsExpanded) {
                        if model.topics.isEmpty && !model.isLoading {
                            Text("No topics found.")
                                .foregroundStyle(.secondary).font(.caption)
                        } else {
                            ForEach(model.topics) { topic in
                                TopicRow(topic: topic, model: model, grpc: grpc)
                            }
                        }
                    } label: {
                        Label("Topics", systemImage: "bubble.left.and.bubble.right")
                            .contextMenu {
                                Button("Create Topic") {
                                    model.showCreateTopicSheet = true
                                }
                                .disabled(!grpc.capabilityMap.createResources)
                            }
                    }

                } label: {
                    Label(grpc.namespaceName ?? "Service Bus", systemImage: "server.rack")
                        .fontWeight(.semibold)
                }
            }

            if !model.isLoading && model.queues.isEmpty && model.topics.isEmpty
                && grpc.connectionState != .connected {
                Text("Not connected.")
                    .foregroundStyle(.secondary).font(.caption)
            }
        }
        // ── Receive sheet ────────────────────────────────────────
        .sheet(isPresented: $model.showReceiveSheet) {
            ReceiveCountDialog(isDLQ: model.receiveIsDLQ, count: $model.receiveCount) {
                postReceiveAction()
            }
        }
        // ── Purge confirmation alert ─────────────────────────────
        .alert(
            model.purgeIsDLQ ? "Purge Deadletter Messages" : "Purge Messages",
            isPresented: $model.showPurgeAlert
        ) {
            Button("Purge All", role: .destructive) { Task { await performPurge() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(purgeAlertMessage)
        }
        // ── Purge result ─────────────────────────────────────────
        .alert(model.purgeResultTitle, isPresented: $model.showPurgeResult) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.purgeResultMessage)
        }
        // ── Edit Rule sheet ───────────────────────────────────────
        .sheet(isPresented: $model.showEditRuleSheet) {
            if let target = model.ruleOpTarget {
                EditRuleSidebarSheet(
                    ruleName: target.rule.name,
                    filter: $model.editRuleFilter,
                    errorMessage: $model.editRuleError,
                    isSaving: $model.isEditingRule
                ) {
                    Task { await performEditRule() }
                }
            }
        }
        // ── Add Rule sheet ────────────────────────────────────────
        .sheet(isPresented: $model.showAddRuleSheet) {
            if let target = model.addRuleTarget {
                AddRuleSidebarSheet(
                    subscriptionPath: "\(target.topicName)/\(target.name)",
                    ruleName: $model.addRuleName,
                    filter: $model.addRuleFilter,
                    errorMessage: $model.addRuleError,
                    isSaving: $model.isAddingRule
                ) {
                    Task { await performAddRule() }
                }
            }
        }
        // ── Create Queue sheet ────────────────────────────────
        .sheet(isPresented: $model.showCreateQueueSheet) {
            CreateQueueSheet { _ in
                Task { await load() }
            }
            .environment(grpc)
            .environment(activityLog)
        }
        // ── Create Topic sheet ────────────────────────────────
        .sheet(isPresented: $model.showCreateTopicSheet) {
            CreateTopicSheet { _ in
                Task { await load() }
            }
            .environment(grpc)
            .environment(activityLog)
        }
        // ── Create Subscription sheet ─────────────────────────
        .sheet(isPresented: $model.showCreateSubscriptionSheet) {
            if let topic = model.createSubscriptionTopic {
                CreateSubscriptionSheet(topicName: topic.name) { _ in
                    model.subscriptions[topic.name] = nil
                }
                .environment(grpc)
                .environment(activityLog)
            }
        }
        // ── Delete Rule confirm ───────────────────────────────────
        .confirmationDialog(
            "Delete Rule?",
            isPresented: $model.showDeleteRuleConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await performDeleteRule() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let target = model.ruleOpTarget {
                Text("Rule \"\(target.rule.name)\" will be permanently deleted from \(target.sub.topicName)/\(target.sub.name).")
            }
        }
        // ── Delete Queue confirm ──────────────────────────────────
        .confirmationDialog(
            "Delete Queue?",
            isPresented: $model.showDeleteQueueConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await performDeleteQueue() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let q = model.deleteQueueTarget {
                Text("Queue \"\(q.name)\" and all its messages will be permanently deleted. This cannot be undone.")
            }
        }
        // ── Delete Topic confirm ──────────────────────────────────
        .confirmationDialog(
            "Delete Topic?",
            isPresented: $model.showDeleteTopicConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await performDeleteTopic() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let t = model.deleteTopicTarget {
                Text("Topic \"\(t.name)\" and all its subscriptions will be permanently deleted. This cannot be undone.")
            }
        }
        // ── Disable Topic confirm ─────────────────────────────────
        .confirmationDialog(
            "Disable Topic?",
            isPresented: $model.showDisableTopicConfirm,
            titleVisibility: .visible
        ) {
            Button("Disable Topic", role: .destructive) {
                Task { await performSetTopicStatus(status: "Disabled") }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let t = model.disableTopicTarget {
                Text("Topic \"\(t.name)\" will be disabled. Publishers will no longer be able to send messages to this topic. You can re-enable it at any time.")
            }
        }
        // ── Delete Subscription confirm ───────────────────────────
        .confirmationDialog(
            "Delete Subscription?",
            isPresented: $model.showDeleteSubscriptionConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await performDeleteSubscription() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let sub = model.deleteSubscriptionTarget {
                Text("Subscription \"\(sub.name)\" and all its messages will be permanently deleted. This cannot be undone.")
            }
        }
        .navigationTitle("BusKit")
        .toolbar {
            ToolbarItem {
                Button { Task { await load() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(grpc.connectionState != .connected || model.isLoading)
            }
        }
        .task {
            if grpc.connectionState == .connected { await load() }
        }
        .onChange(of: grpc.connectionState) { _, newState in
            if newState == .connected {
                namespaceExpanded = true
                queuesExpanded    = true
                topicsExpanded    = true
                Task { await load() }
            } else {
                model.queues         = []
                model.topics         = []
                model.subscriptions  = [:]
                model.rules          = [:]
            }
        }
        .onChange(of: actionStore.pendingRefresh) { _, req in
            guard let req else { return }
            Task {
                switch req.target {
                case .queue(let name):
                    await refreshQueueCounts(name: name)
                case .subscription(let topic, let sub):
                    await refreshSubscriptionCounts(topicName: topic, subName: sub)
                }
            }
        }
        .onChange(of: actionStore.pendingRulesRefresh) { _, req in
            guard let req else { return }
            invalidateRules(topicName: req.topicName, subName: req.subscriptionName)
        }
    }

    // MARK: - Context menu builder for queues

    @ViewBuilder
    private func queueContextMenu(for queue: QueueItem) -> some View {
        let hasData    = grpc.rbacAccessLevel.hasDataAccess
        let canManage  = grpc.capabilityMap.createResources
        Button("Receive Messages") {
            model.contextTarget  = .queue(queue)
            model.receiveIsDLQ   = false
            model.showReceiveSheet = true
        }
        .disabled(!hasData)
        Button("Receive Deadletter Messages") {
            model.contextTarget  = .queue(queue)
            model.receiveIsDLQ   = true
            model.showReceiveSheet = true
        }
        .disabled(!hasData)
        Divider()
        Button("Purge Messages", role: .destructive) {
            model.contextTarget = .queue(queue)
            model.purgeIsDLQ    = false
            model.showPurgeAlert = true
        }
        .disabled(!hasData)
        Button("Purge Deadletter Messages", role: .destructive) {
            model.contextTarget = .queue(queue)
            model.purgeIsDLQ    = true
            model.showPurgeAlert = true
        }
        .disabled(!hasData)
        if !hasData {
            Divider()
            Text("Message operations require the Azure Service Bus Data Owner role.")
                .foregroundStyle(.secondary)
        }
        Divider()
        Menu("Set Status") {
            Button("Active") {
                Task { await performSetQueueStatus(queue: queue, status: "Active") }
            }
            .disabled(queue.status == "Active")
            Divider()
            Button("Disabled") {
                Task { await performSetQueueStatus(queue: queue, status: "Disabled") }
            }
            .disabled(queue.status == "Disabled")
            Button("Send Disabled") {
                Task { await performSetQueueStatus(queue: queue, status: "SendDisabled") }
            }
            .disabled(queue.status == "SendDisabled")
            Button("Receive Disabled") {
                Task { await performSetQueueStatus(queue: queue, status: "ReceiveDisabled") }
            }
            .disabled(queue.status == "ReceiveDisabled")
        }
        .disabled(!canManage)
        Divider()
        Button("Delete Queue", role: .destructive) {
            model.deleteQueueTarget = queue
            model.showDeleteQueueConfirm = true
        }
        .disabled(!canManage)
    }

    // MARK: - Dialog helpers

    private var purgeAlertMessage: String {
        guard let target = model.contextTarget else { return "" }
        let name: String
        switch target {
        case .queue(let q):         name = q.name
        case .subscription(let s):  name = "\(s.topicName)/\(s.name)"
        case .rulesGroup, .rule:    return ""
        }
        let kind = model.purgeIsDLQ ? "dead-letter messages" : "messages"
        return "All \(kind) in \"\(name)\" will be permanently deleted. This cannot be undone."
    }

    private func postReceiveAction() {
        guard let target = model.contextTarget else { return }
        let key: String
        switch target {
        case .queue(let q):
            key = EntityActionStore.queueKey(q.name)
            selection = .queue(q)
        case .subscription(let s):
            key = EntityActionStore.subscriptionKey(topic: s.topicName, sub: s.name)
            selection = .subscription(s)
        case .rulesGroup, .rule:
            return
        }
        actionStore.receive(entityKey: key, isDLQ: model.receiveIsDLQ, count: Int32(model.receiveCount))
    }

    private func performPurge() async {
        guard let target = model.contextTarget else { return }
        let isDLQ = model.purgeIsDLQ
        do {
            let count: Int32
            switch target {
            case .queue(let q):
                count = try await grpc.purgeMessages(queueName: q.name, isDLQ: isDLQ)
                await refreshQueueCounts(name: q.name)
            case .subscription(let s):
                count = try await grpc.purgeMessages(
                    topicName: s.topicName, subscriptionName: s.name, isDLQ: isDLQ)
                await refreshSubscriptionCounts(topicName: s.topicName, subName: s.name)
            case .rule:
                return
            case .rulesGroup:
                return
            }
            model.purgeResultTitle   = "Purge Complete"
            model.purgeResultMessage = "Purged \(count) message\(count == 1 ? "" : "s")."
        } catch {
            model.purgeResultTitle   = "Purge Failed"
            model.purgeResultMessage = error.localizedDescription
        }
        model.showPurgeResult = true
    }

    private func refreshQueueCounts(name: String) async {
        guard let infos = try? await grpc.listQueues(),
              let info  = infos.first(where: { $0.name == name }),
              let idx   = model.queues.firstIndex(where: { $0.name == name })
        else { return }
        model.queues[idx] = QueueItem(name: info.name,
                                      messageCount: info.messageCount,
                                      deadLetterCount: info.deadLetterCount,
                                      status: info.status)
    }

    private func refreshSubscriptionCounts(topicName: String, subName: String) async {
        guard let infos = try? await grpc.listSubscriptions(topicName: topicName),
              let info  = infos.first(where: { $0.name == subName }),
              case .loaded(var subs) = model.subscriptions[topicName],
              let idx = subs.firstIndex(where: { $0.name == subName })
        else { return }
        subs[idx] = SubscriptionItem(topicName: topicName, name: info.name,
                                     activeMessageCount: info.activeMessageCount,
                                     deadLetterCount: info.deadLetterCount)
        model.subscriptions[topicName] = .loaded(subs)
    }

    /// Invalidates the cached rules for a subscription so the next expansion re-fetches.
    private func invalidateRules(topicName: String, subName: String) {
        model.rules["\(topicName)/\(subName)"] = nil
    }

    // MARK: - Rule operations (from sidebar context menu)

    private func performEditRule() async {
        guard let target = model.ruleOpTarget else { return }
        model.isEditingRule = true
        model.editRuleError = nil
        do {
            try await grpc.updateRule(
                topicName: target.sub.topicName,
                subscriptionName: target.sub.name,
                ruleName: target.rule.name,
                sqlFilter: model.editRuleFilter)
            model.showEditRuleSheet = false
            model.isEditingRule = false
            invalidateRules(topicName: target.sub.topicName, subName: target.sub.name)
            actionStore.requestRulesRefresh(topicName: target.sub.topicName,
                                            subscriptionName: target.sub.name)
            activityLog.log(action: .editRule, messageId: target.rule.name,
                            result: .success("Filter updated on \(target.sub.topicName)/\(target.sub.name)"))
        } catch {
            model.editRuleError = error.localizedDescription
            model.isEditingRule = false
            activityLog.log(action: .editRule, messageId: target.rule.name,
                            result: .failure(error.localizedDescription),
                            hint: "Check your SQL filter syntax and permissions.")
        }
    }

    private func performDeleteRule() async {
        guard let target = model.ruleOpTarget else { return }
        model.isDeletingRule = true
        defer { model.isDeletingRule = false }
        do {
            try await grpc.deleteRule(
                topicName: target.sub.topicName,
                subscriptionName: target.sub.name,
                ruleName: target.rule.name)
            if case .rule(let r, _) = selection, r.id == target.rule.id {
                selection = .subscription(target.sub)
            }
            invalidateRules(topicName: target.sub.topicName, subName: target.sub.name)
            actionStore.requestRulesRefresh(topicName: target.sub.topicName,
                                            subscriptionName: target.sub.name)
            activityLog.log(action: .deleteRule, messageId: target.rule.name,
                            result: .success("Deleted from \(target.sub.topicName)/\(target.sub.name)"))
        } catch {
            activityLog.log(action: .deleteRule, messageId: target.rule.name,
                            result: .failure(error.localizedDescription),
                            hint: "The rule may already have been deleted.")
        }
    }

    private func performAddRule() async {
        guard let target = model.addRuleTarget else { return }
        model.isAddingRule = true
        model.addRuleError = nil
        do {
            try await grpc.addRule(
                topicName: target.topicName,
                subscriptionName: target.name,
                ruleName: model.addRuleName,
                sqlFilter: model.addRuleFilter)
            model.showAddRuleSheet = false
            model.isAddingRule = false
            invalidateRules(topicName: target.topicName, subName: target.name)
            actionStore.requestRulesRefresh(topicName: target.topicName,
                                            subscriptionName: target.name)
            activityLog.log(action: .editRule, messageId: model.addRuleName,
                            result: .success("Rule created in \(target.topicName)/\(target.name)"))
        } catch {
            model.addRuleError = error.localizedDescription
            model.isAddingRule = false
            activityLog.log(action: .editRule, messageId: model.addRuleName,
                            result: .failure(error.localizedDescription),
                            hint: "Check the rule name and SQL filter syntax.")
        }
    }

    // MARK: - Data loading

    private func performDeleteQueue() async {
        guard let queue = model.deleteQueueTarget else { return }
        model.isDeletingQueue = true
        defer { model.isDeletingQueue = false }
        do {
            try await grpc.deleteQueue(name: queue.name)
            if case .queue(let q) = selection, q.id == queue.id {
                selection = nil
            }
            model.queues.removeAll { $0.id == queue.id }
            activityLog.log(action: .deleteQueue, messageId: queue.name,
                            result: .success("Queue \"\(queue.name)\" deleted"))
        } catch {
            activityLog.log(action: .deleteQueue, messageId: queue.name,
                            result: .failure(error.localizedDescription),
                            hint: "The queue may still have active messages or sessions.")
        }
    }

    private func performSetQueueStatus(queue: QueueItem, status: String) async {
        do {
            try await grpc.setQueueStatus(name: queue.name, status: status)
            if let idx = model.queues.firstIndex(where: { $0.id == queue.id }) {
                model.queues[idx] = QueueItem(name: queue.name,
                                              messageCount: queue.messageCount,
                                              deadLetterCount: queue.deadLetterCount,
                                              status: status)
            }
            activityLog.log(action: .setQueueStatus, messageId: queue.name,
                            result: .success("Queue \"\(queue.name)\" status set to \(status)"))
        } catch {
            activityLog.log(action: .setQueueStatus, messageId: queue.name,
                            result: .failure(error.localizedDescription),
                            hint: "Check that you have Contributor role on the namespace.")
        }
    }

    private func performDeleteTopic() async {
        guard let topic = model.deleteTopicTarget else { return }
        model.isDeletingTopic = true
        defer { model.isDeletingTopic = false }
        do {
            try await grpc.deleteTopic(name: topic.name)
            model.topics.removeAll { $0.id == topic.id }
            model.subscriptions.removeValue(forKey: topic.name)
            activityLog.log(action: .deleteTopic, messageId: topic.name,
                            result: .success("Topic \"\(topic.name)\" deleted"))
        } catch {
            activityLog.log(action: .deleteTopic, messageId: topic.name,
                            result: .failure(error.localizedDescription),
                            hint: "The topic may still have active subscriptions.")
        }
    }

    private func performSetTopicStatus(status: String) async {
        guard let topic = model.disableTopicTarget else { return }
        model.isSettingTopicStatus = true
        defer { model.isSettingTopicStatus = false }
        do {
            try await grpc.setTopicStatus(name: topic.name, status: status)
            if let idx = model.topics.firstIndex(where: { $0.id == topic.id }) {
                model.topics[idx] = TopicItem(name: topic.name, status: status)
            }
            activityLog.log(action: .setTopicStatus, messageId: topic.name,
                            result: .success("Topic \"\(topic.name)\" status set to \(status)"))
        } catch {
            activityLog.log(action: .setTopicStatus, messageId: topic.name,
                            result: .failure(error.localizedDescription),
                            hint: "Check that you have Contributor role on the namespace.")
        }
    }

    private func performDeleteSubscription() async {
        guard let sub = model.deleteSubscriptionTarget else { return }
        model.isDeletingSubscription = true
        defer { model.isDeletingSubscription = false }
        do {
            try await grpc.deleteSubscription(topicName: sub.topicName, subscriptionName: sub.name)
            if case .loaded(let subs) = model.subscriptions[sub.topicName] {
                model.subscriptions[sub.topicName] = .loaded(subs.filter { $0.id != sub.id })
            }
            activityLog.log(action: .deleteSubscription, messageId: sub.name,
                            result: .success("Subscription \"\(sub.name)\" deleted from topic \"\(sub.topicName)\""))
        } catch {
            activityLog.log(action: .deleteSubscription, messageId: sub.name,
                            result: .failure(error.localizedDescription),
                            hint: "The subscription may still have active messages or sessions.")
        }
    }

    // MARK: - Data loading

    private func load() async {
        guard grpc.connectionState == .connected else { return }
        model.isLoading     = true
        model.subscriptions = [:]
        model.rules         = [:]
        defer { model.isLoading = false }
        async let q = grpc.listQueues()
        async let t = grpc.listTopics()
        do {
            let (queueInfos, topicInfos) = try await (q, t)
            model.queues  = queueInfos.map {
                QueueItem(name: $0.name, messageCount: $0.messageCount,
                          deadLetterCount: $0.deadLetterCount, status: $0.status)
            }
            model.topics = topicInfos.map { TopicItem(name: $0.name, status: $0.status) }
        } catch { }
    }
}

// MARK: - TopicRow

@available(macOS 15.0, *)
private struct TopicRow: View {
    let topic: TopicItem
    let model: SidebarModel
    let grpc: GRPCManager

    @Environment(ActivityLogStore.self) var activityLog
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            switch model.subscriptions[topic.name] {
            case .none, .loading:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading subscriptions…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.leading, 8)

            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red).padding(.leading, 8)

            case .loaded(let subs):
                if subs.isEmpty {
                    Text("No subscriptions").font(.caption).foregroundStyle(.secondary)
                        .padding(.leading, 8)
                } else {
                    ForEach(subs) { sub in
                        SubscriptionRow(sub: sub, model: model, grpc: grpc)
                            .padding(.leading, 8)
                    }
                }
            }
        } label: {
            HStack {
                Label(topic.name, systemImage: "bubble.left.and.bubble.right")
                    .foregroundStyle(topic.status == "Disabled" ? .secondary : .primary)
                if topic.status == "Disabled" {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }
            .contentShape(Rectangle())
            .contextMenu {
                    Button("Create Subscription") {
                        model.createSubscriptionTopic = topic
                        model.showCreateSubscriptionSheet = true
                    }
                    .disabled(!grpc.capabilityMap.createResources)
                    Divider()
                    if topic.status == "Disabled" {
                        Button("Enable Topic") {
                            model.disableTopicTarget = topic
                            Task { await performEnableTopic() }
                        }
                        .disabled(!grpc.capabilityMap.createResources)
                    } else {
                        Button("Disable Topic") {
                            model.disableTopicTarget = topic
                            model.showDisableTopicConfirm = true
                        }
                        .disabled(!grpc.capabilityMap.createResources)
                    }
                    Divider()
                    Button("Delete Topic", role: .destructive) {
                        model.deleteTopicTarget = topic
                        model.showDeleteTopicConfirm = true
                    }
                    .disabled(!grpc.capabilityMap.createResources)
                }
        }
        .onChange(of: isExpanded) { _, expanded in
            if expanded, model.subscriptions[topic.name] == nil {
                Task { await loadSubscriptions() }
            }
        }
        .onChange(of: model.subscriptions[topic.name]) { _, newValue in
            if newValue == nil, isExpanded {
                Task { await loadSubscriptions() }
            }
        }
    }

    private func loadSubscriptions() async {
        model.subscriptions[topic.name] = .loading
        do {
            let infos = try await grpc.listSubscriptions(topicName: topic.name)
            let subs = infos.map {
                SubscriptionItem(topicName: topic.name, name: $0.name,
                                 activeMessageCount: $0.activeMessageCount,
                                 deadLetterCount: $0.deadLetterCount)
            }
            model.subscriptions[topic.name] = .loaded(subs)
        } catch {
            model.subscriptions[topic.name] = .failed(error.localizedDescription)
        }
    }

    private func performEnableTopic() async {
        model.isSettingTopicStatus = true
        defer { model.isSettingTopicStatus = false }
        do {
            try await grpc.setTopicStatus(name: topic.name, status: "Active")
            if let idx = model.topics.firstIndex(where: { $0.id == topic.id }) {
                model.topics[idx] = TopicItem(name: topic.name, status: "Active")
            }
            activityLog.log(action: .setTopicStatus, messageId: topic.name,
                            result: .success("Topic \"\(topic.name)\" enabled"))
        } catch {
            activityLog.log(action: .setTopicStatus, messageId: topic.name,
                            result: .failure(error.localizedDescription),
                            hint: "Check that you have Contributor role on the namespace.")
        }
    }
}

// MARK: - SubscriptionRow

@available(macOS 15.0, *)
private struct SubscriptionRow: View {
    let sub: SubscriptionItem
    let model: SidebarModel
    let grpc: GRPCManager

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            RulesGroupRow(sub: sub, model: model, grpc: grpc)
        } label: {
            subLabel
        }
    }

    @ViewBuilder private var subLabel: some View {
        let hasData = grpc.rbacAccessLevel.hasDataAccess
        HStack {
            Label(sub.name, systemImage: "tray.2")
            Spacer()
            MessageCountBadge(
                active: sub.activeMessageCount,
                deadLetter: sub.deadLetterCount)
        }
        .contentShape(Rectangle())
        .tag(SidebarSelection.subscription(sub))
        .contextMenu {
            Button("Receive Messages") {
                model.contextTarget    = .subscription(sub)
                model.receiveIsDLQ     = false
                model.showReceiveSheet = true
            }
            .disabled(!hasData)
            Button("Receive Deadletter Messages") {
                model.contextTarget    = .subscription(sub)
                model.receiveIsDLQ     = true
                model.showReceiveSheet = true
            }
            .disabled(!hasData)
            Divider()
            Button("Purge Messages", role: .destructive) {
                model.contextTarget  = .subscription(sub)
                model.purgeIsDLQ     = false
                model.showPurgeAlert = true
            }
            .disabled(!hasData)
            Button("Purge Deadletter Messages", role: .destructive) {
                model.contextTarget  = .subscription(sub)
                model.purgeIsDLQ     = true
                model.showPurgeAlert = true
            }
            .disabled(!hasData)
            Divider()
            Button("Delete Subscription", role: .destructive) {
                model.deleteSubscriptionTarget  = sub
                model.showDeleteSubscriptionConfirm = true
            }
            .disabled(!grpc.capabilityMap.createResources)
            if !hasData {
                Divider()
                Text("Message operations require the Azure Service Bus Data Owner role.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - RulesGroupRow

@available(macOS 15.0, *)
private struct RulesGroupRow: View {
    let sub: SubscriptionItem
    let model: SidebarModel
    let grpc: GRPCManager

    @State private var isExpanded = false
    @State private var fetchTask: Task<Void, Never>? = nil

    private var ruleKey: String { "\(sub.topicName)/\(sub.name)" }

    private var canManage: Bool { grpc.capabilityMap.manageFilters }
    private var isLoading: Bool {
        if case .loading = model.rules[ruleKey] { return true }
        return false
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            rulesContent
        } label: {
            Label("Rules", systemImage: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
                .tag(SidebarSelection.rulesGroup(sub))
                .accessibilityLabel(accessibilityLabel)
                .contextMenu {
                    Button("Add New Rule") {
                        model.addRuleTarget  = sub
                        model.addRuleName    = ""
                        model.addRuleFilter  = ""
                        model.addRuleError   = nil
                        model.showAddRuleSheet = true
                    }
                    .disabled(isLoading || !canManage)
                    Button("Refresh Rules") { refresh() }
                        .disabled(isLoading)
                }
        }
        .onChange(of: isExpanded) { _, expanded in
            if expanded {
                if model.rules[ruleKey] == nil { startFetch() }
            } else {
                fetchTask?.cancel()
                fetchTask = nil
            }
        }
        // Re-fetch when cache is externally invalidated while expanded
        .onChange(of: model.rules[ruleKey]) { _, newState in
            if isExpanded, newState == nil { startFetch() }
        }
    }

    @ViewBuilder private var rulesContent: some View {
        switch model.rules[ruleKey] {
        case .none, .loading:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading rules")
                Text("Loading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)

        case .failed(let msg):
            HStack {
                Label(msg, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                Spacer()
                Button("Retry") { startFetch() }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Failed to load rules. \(msg)")
            .accessibilityHint("Activate Retry button to try again")

        case .loaded(let rules):
            if rules.isEmpty {
                Text("No rules")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rules) { rule in
                    SidebarRuleRow(rule: rule, subscription: sub, model: model, grpc: grpc)
                }
            }
        }
    }

    private var accessibilityLabel: String {
        switch model.rules[ruleKey] {
        case .none:              return "Rules"
        case .loading:           return "Rules, loading"
        case .failed:            return "Rules, failed to load"
        case .loaded(let list):  return "Rules, \(list.count) \(list.count == 1 ? "item" : "items")"
        }
    }

    private func startFetch() {
        fetchTask?.cancel()
        model.rules[ruleKey] = .loading
        fetchTask = Task {
            do {
                let infos = try await grpc.listRules(topicName: sub.topicName,
                                                     subscriptionName: sub.name)
                guard !Task.isCancelled else { return }
                model.rules[ruleKey] = .loaded(infos.map {
                    RuleItem(name: $0.name, filter: $0.filter)
                })
            } catch {
                guard !Task.isCancelled else { return }
                model.rules[ruleKey] = .failed(error.localizedDescription)
            }
        }
    }

    private func refresh() {
        fetchTask?.cancel()
        fetchTask = nil
        if isExpanded {
            startFetch()
        } else {
            model.rules[ruleKey] = nil
        }
    }
}

// MARK: - SidebarRuleRow

@available(macOS 15.0, *)
private struct SidebarRuleRow: View {
    let rule: RuleItem
    let subscription: SubscriptionItem
    let model: SidebarModel
    let grpc: GRPCManager

    private var canManage: Bool { grpc.capabilityMap.manageFilters }

    /// Strip "SQL: " prefix to expose raw expression for editing.
    private var rawFilter: String {
        rule.filter.hasPrefix("SQL: ") ? String(rule.filter.dropFirst(5)) : rule.filter
    }

    var body: some View {
        Label(rule.name, systemImage: "line.3.horizontal.decrease.circle")
            .font(.subheadline)
            .tag(SidebarSelection.rule(rule, subscription))
            .contextMenu {
                Button("Edit Filter") {
                    model.ruleOpTarget    = (rule, subscription)
                    model.editRuleFilter  = rawFilter
                    model.editRuleError   = nil
                    model.showEditRuleSheet = true
                }
                .disabled(!canManage)
                Divider()
                Button("Delete Rule", role: .destructive) {
                    model.ruleOpTarget          = (rule, subscription)
                    model.showDeleteRuleConfirm = true
                }
                .disabled(!canManage)
            }
    }
}

// MARK: - Edit Rule Sheet (sidebar)

@available(macOS 15.0, *)
private struct EditRuleSidebarSheet: View {
    let ruleName: String
    @Binding var filter: String
    @Binding var errorMessage: String?
    @Binding var isSaving: Bool
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var isValid: Bool {
        !filter.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Filter: \(ruleName)")
                .font(.headline)

            Divider()

            Form {
                LabeledContent("SQL Filter") {
                    TextField("e.g. Priority = 'High'", text: $filter)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
            }
            .formStyle(.grouped)

            if let error = errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Button("Save") { onSave() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                    .disabled(!isValid || isSaving)
            }
        }
        .padding()
        .frame(width: 380)
    }
}

// MARK: - Add Rule Sheet (sidebar)

@available(macOS 15.0, *)
private struct AddRuleSidebarSheet: View {
    let subscriptionPath: String
    @Binding var ruleName: String
    @Binding var filter: String
    @Binding var errorMessage: String?
    @Binding var isSaving: Bool
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var isValid: Bool {
        !ruleName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !filter.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Rule — \(subscriptionPath)")
                .font(.headline)

            Divider()

            Form {
                LabeledContent("Rule Name") {
                    TextField("e.g. HighPriority", text: $ruleName)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("SQL Filter") {
                    TextField("e.g. Priority = 'High'", text: $filter)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
            }
            .formStyle(.grouped)

            if let error = errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Button("Add Rule") { onSave() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                    .disabled(!isValid || isSaving)
            }
        }
        .padding()
        .frame(width: 420)
    }
}

// MARK: - Preview

@available(macOS 15.0, *)
#Preview("Sidebar – Empty") {
    @Previewable @State var selection: SidebarSelection? = nil

    NavigationSplitView {
        SidebarView(selection: $selection)
            .environment(GRPCManager())
            .environment(EntityActionStore())
    } detail: {
        Text("No selection").foregroundStyle(.secondary)
    }
    .frame(width: 700, height: 500)
}
