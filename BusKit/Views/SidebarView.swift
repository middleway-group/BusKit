import SwiftUI

// MARK: - Loading state

private enum LoadState<T> {
    case loading
    case loaded(T)
    case failed(String)
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
    @Binding var selection: SidebarSelection?
    @State private var model = SidebarModel()
    @State private var namespaceExpanded = true
    @State private var queuesExpanded    = true
    @State private var topicsExpanded    = true

    // Queues sorted: active (any messages) first, then zero-count — each group alpha-sorted.
    private var sortedQueues: [QueueItem] {
        model.queues.sorted { a, b in
            let aHas = a.messageCount > 0 || a.deadLetterCount > 0
            let bHas = b.messageCount > 0 || b.deadLetterCount > 0
            if aHas != bHas { return aHas }
            return a.name < b.name
        }
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
                                let isInactive = queue.messageCount == 0 && queue.deadLetterCount == 0
                                HStack {
                                    Label(queue.name, systemImage: "tray")
                                    Spacer()
                                    MessageCountBadge(
                                        active: queue.messageCount,
                                        deadLetter: queue.deadLetterCount)
                                }
                                .opacity(isInactive ? 0.4 : 1.0)
                                .tag(SidebarSelection.queue(queue))
                                .contextMenu {
                                    queueContextMenu(for: queue)
                                }
                            }
                        }
                    } label: {
                        Label("Queues", systemImage: "tray.full")
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
    }

    // MARK: - Context menu builder for queues

    @ViewBuilder
    private func queueContextMenu(for queue: QueueItem) -> some View {
        let hasData = grpc.rbacAccessLevel.hasDataAccess
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
    }

    // MARK: - Dialog helpers

    private var purgeAlertMessage: String {
        guard let target = model.contextTarget else { return "" }
        let name: String
        switch target {
        case .queue(let q):            name = q.name
        case .subscription(let s):    name = "\(s.topicName)/\(s.name)"
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
                                      deadLetterCount: info.deadLetterCount)
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
                          deadLetterCount: $0.deadLetterCount)
            }
            model.topics = topicInfos.map { TopicItem(name: $0.name) }
        } catch { }
    }
}

// MARK: - TopicRow

@available(macOS 15.0, *)
private struct TopicRow: View {
    let topic: TopicItem
    let model: SidebarModel
    let grpc: GRPCManager

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
            Label(topic.name, systemImage: "bubble.left.and.bubble.right")
        }
        .onChange(of: isExpanded) { _, expanded in
            if expanded, model.subscriptions[topic.name] == nil {
                Task { await loadSubscriptions() }
            }
        }
    }

    private func loadSubscriptions() async {
        model.subscriptions[topic.name] = .loading
        do {
            let infos = try await grpc.listSubscriptions(topicName: topic.name)
            model.subscriptions[topic.name] = .loaded(infos.map {
                SubscriptionItem(topicName: topic.name, name: $0.name,
                                 activeMessageCount: $0.activeMessageCount,
                                 deadLetterCount: $0.deadLetterCount)
            })
        } catch {
            model.subscriptions[topic.name] = .failed(error.localizedDescription)
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
    private var key: String { "\(sub.topicName)/\(sub.name)" }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            switch model.rules[key] {
            case .none, .loading:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading rules…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.leading, 8)

            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red).padding(.leading, 8)

            case .loaded(let ruleList):
                if ruleList.isEmpty {
                    Text("No rules").font(.caption).foregroundStyle(.secondary).padding(.leading, 8)
                } else {
                    ForEach(ruleList) { rule in
                        RuleRow(rule: rule).padding(.leading, 8)
                    }
                }
            }
        } label: {
            HStack {
                Label(sub.name, systemImage: "tray.2")
                Spacer()
                MessageCountBadge(
                    active: sub.activeMessageCount,
                    deadLetter: sub.deadLetterCount)
            }
            .contentShape(Rectangle())
        }
        .opacity(sub.activeMessageCount == 0 && sub.deadLetterCount == 0 ? 0.4 : 1.0)
        .tag(SidebarSelection.subscription(sub))
        .contextMenu {
            let hasData = grpc.rbacAccessLevel.hasDataAccess
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
            if !hasData {
                Divider()
                Text("Message operations require the Azure Service Bus Data Owner role.")
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: isExpanded) { _, expanded in
            if expanded, model.rules[key] == nil {
                Task { await loadRules() }
            }
        }
    }

    private func loadRules() async {
        model.rules[key] = .loading
        do {
            let infos = try await grpc.listRules(topicName: sub.topicName,
                                                 subscriptionName: sub.name)
            model.rules[key] = .loaded(infos.map { RuleItem(name: $0.name, filter: $0.filter) })
        } catch {
            model.rules[key] = .failed(error.localizedDescription)
        }
    }
}

// MARK: - RuleRow

@available(macOS 15.0, *)
private struct RuleRow: View {
    let rule: RuleItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(rule.name, systemImage: "line.3.horizontal.decrease.circle").font(.body)
            Text(rule.filter)
                .font(.caption2).foregroundStyle(.secondary).padding(.leading, 20)
        }
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
