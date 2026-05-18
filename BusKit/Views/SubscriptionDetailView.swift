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
                Label("Overview",   systemImage: "info.circle").tag(0)
                Label("Rules",      systemImage: "line.3.horizontal.decrease.circle").tag(1)
                Label("Messages",   systemImage: "list.bullet.rectangle").tag(2)
                Label("Deadletter", systemImage: "tray.and.arrow.down").tag(3)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            Group {
                switch selectedTab {
                case 1:
                    SubRulesTab(subscription: subscription)
                case 2:
                    if grpc.rbacAccessLevel.hasDataAccess {
                        SubMessagesTab(subscription: subscription, isDLQ: false,
                                       trigger: messagesTrigger, requestedCount: messagesCount)
                    } else {
                        DataAccessRestrictedView()
                    }
                case 3:
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
                    selectedTab = 3
                } else {
                    messagesCount   = action.count
                    messagesTrigger = UUID()
                    selectedTab     = 2
                }
            }
        }
        .onChange(of: actionStore.pendingFocusRules) { _, action in
            guard let action, action.entityKey == entityKey else { return }
            selectedTab = 1
        }
    }
}

// MARK: - Rules Tab

@available(macOS 15.0, *)
private struct SubRulesTab: View {
    @Environment(GRPCManager.self) var grpc
    @Environment(EntityActionStore.self) var actionStore
    @Environment(ActivityLogStore.self) var activityLog
    let subscription: SubscriptionItem

    @State private var rules: [RuleItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedRuleID: UUID?

    // Add-rule sheet state
    @State private var showAddSheet    = false
    @State private var newRuleName     = ""
    @State private var newSQLFilter    = ""
    @State private var addError: String?
    @State private var isAdding        = false

    // Edit state (inline in a sheet)
    @State private var editingRule: RuleItem?
    @State private var editFilter      = ""
    @State private var editError: String?
    @State private var isSavingEdit    = false

    // Delete confirm
    @State private var showDeleteConfirm = false
    @State private var isDeleting        = false

    private var canManage: Bool { grpc.capabilityMap.manageFilters }
    private var selectedRule: RuleItem? { rules.first { $0.id == selectedRuleID } }

    var body: some View {
        VStack(spacing: 0) {
            // ── Toolbar ────────────────────────────────────────────
            HStack(spacing: 0) {
                Button {
                    newRuleName = ""
                    newSQLFilter = ""
                    addError = nil
                    showAddSheet = true
                } label: {
                    Label("Add Rule", systemImage: "plus")
                        .padding(.horizontal, 8).padding(.vertical, 4)
                }
                .buttonStyle(.borderless)
                .disabled(!canManage)
                .help(canManage ? "Add a new filter rule" : "Requires Contributor role to manage filters")

                rulesToolbarDivider

                Button {
                    guard let rule = selectedRule else { return }
                    editFilter = rule.filter.hasPrefix("SQL: ")
                        ? String(rule.filter.dropFirst(5))
                        : rule.filter
                    editError = nil
                    editingRule = rule
                } label: {
                    Label("Edit Filter", systemImage: "pencil")
                        .padding(.horizontal, 8).padding(.vertical, 4)
                }
                .buttonStyle(.borderless)
                .disabled(selectedRule == nil || !canManage)
                .help("Edit the SQL filter expression")

                rulesToolbarDivider

                Button {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete", systemImage: "trash")
                        .padding(.horizontal, 8).padding(.vertical, 4)
                }
                .buttonStyle(.borderless)
                .disabled(selectedRule == nil || !canManage)
                .help("Delete the selected rule")

                Spacer()

                rulesToolbarDivider

                Button { Task { await loadRules() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .padding(.horizontal, 8).padding(.vertical, 4)
                }
                .buttonStyle(.borderless)
                .disabled(isLoading)
                .help("Refresh rules")
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(.bar)

            Divider()

            // ── Rule list ──────────────────────────────────────────
            Group {
                if isLoading {
                    ProgressView("Loading rules…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = errorMessage {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle).foregroundStyle(.red)
                        Text(error).foregroundStyle(.secondary).font(.caption)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if rules.isEmpty {
                    Text("No rules for \(subscription.name)")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Table(rules, selection: $selectedRuleID) {
                        TableColumn("Rule Name") { rule in
                            Label(rule.name, systemImage: "line.3.horizontal.decrease.circle")
                                .lineLimit(1)
                        }
                        .width(min: 120, ideal: 180)

                        TableColumn("Filter") { rule in
                            Text(rule.filter.isEmpty ? "—" : rule.filter)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .contextMenu(forSelectionType: UUID.self) { ids in
                        if let id = ids.first, let rule = rules.first(where: { $0.id == id }) {
                            Button("Edit Filter") {
                                selectedRuleID = id
                                editFilter = rule.filter.hasPrefix("SQL: ")
                                    ? String(rule.filter.dropFirst(5))
                                    : rule.filter
                                editError = nil
                                editingRule = rule
                            }
                            .disabled(!canManage)
                            Divider()
                            Button("Delete Rule", role: .destructive) {
                                selectedRuleID = id
                                showDeleteConfirm = true
                            }
                            .disabled(!canManage)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await loadRules() }
        .onChange(of: subscription.name) { _, _ in Task { await loadRules() } }
        // ── Add Rule sheet ─────────────────────────────────────────
        .sheet(isPresented: $showAddSheet) {
            AddRuleSheet(
                topicName: subscription.topicName,
                subscriptionName: subscription.name,
                ruleName: $newRuleName,
                sqlFilter: $newSQLFilter,
                errorMessage: $addError,
                isAdding: $isAdding
            ) {
                Task { await addRule() }
            }
        }
        // ── Edit Rule sheet ────────────────────────────────────────
        .sheet(item: $editingRule) { rule in
            EditRuleSheet(
                ruleName: rule.name,
                sqlFilter: $editFilter,
                errorMessage: $editError,
                isSaving: $isSavingEdit
            ) {
                Task { await updateRule(rule: rule) }
            }
        }
        // ── Delete confirm ─────────────────────────────────────────
        .confirmationDialog("Delete Rule?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { await deleteRule() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let rule = selectedRule {
                Text("Rule \"\(rule.name)\" will be permanently deleted.")
            }
        }
    }

    private func loadRules() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let infos = try await grpc.listRules(
                topicName: subscription.topicName,
                subscriptionName: subscription.name)
            rules = infos.map { RuleItem(name: $0.name, filter: $0.filter) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addRule() async {
        isAdding = true
        addError = nil
        do {
            try await grpc.addRule(
                topicName: subscription.topicName,
                subscriptionName: subscription.name,
                ruleName: newRuleName,
                sqlFilter: newSQLFilter)
            showAddSheet = false
            await loadRules()
            actionStore.requestRulesRefresh(topicName: subscription.topicName,
                                            subscriptionName: subscription.name)
            activityLog.log(action: .editRule, messageId: newRuleName,
                            result: .success("Rule added to \(subscription.topicName)/\(subscription.name)"))
        } catch {
            addError = error.localizedDescription
            activityLog.log(action: .editRule, messageId: newRuleName,
                            result: .failure(error.localizedDescription),
                            hint: "Check rule name uniqueness and SQL filter syntax.")
        }
        isAdding = false
    }

    private func updateRule(rule: RuleItem) async {
        isSavingEdit = true
        editError = nil
        do {
            try await grpc.updateRule(
                topicName: subscription.topicName,
                subscriptionName: subscription.name,
                ruleName: rule.name,
                sqlFilter: editFilter)
            editingRule = nil
            await loadRules()
            actionStore.requestRulesRefresh(topicName: subscription.topicName,
                                            subscriptionName: subscription.name)
            activityLog.log(action: .editRule, messageId: rule.name,
                            result: .success("Filter updated on \(subscription.topicName)/\(subscription.name)"))
        } catch {
            editError = error.localizedDescription
            activityLog.log(action: .editRule, messageId: rule.name,
                            result: .failure(error.localizedDescription),
                            hint: "Check your SQL filter syntax and permissions.")
        }
        isSavingEdit = false
    }

    private func deleteRule() async {
        guard let rule = selectedRule else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await grpc.deleteRule(
                topicName: subscription.topicName,
                subscriptionName: subscription.name,
                ruleName: rule.name)
            rules.removeAll { $0.id == rule.id }
            selectedRuleID = nil
            actionStore.requestRulesRefresh(topicName: subscription.topicName,
                                            subscriptionName: subscription.name)
            activityLog.log(action: .deleteRule, messageId: rule.name,
                            result: .success("Deleted from \(subscription.topicName)/\(subscription.name)"))
        } catch {
            errorMessage = error.localizedDescription
            activityLog.log(action: .deleteRule, messageId: rule.name,
                            result: .failure(error.localizedDescription),
                            hint: "The rule may already have been deleted.")
        }
    }
}

// MARK: - Add Rule Sheet

@available(macOS 15.0, *)
private struct AddRuleSheet: View {
    let topicName: String
    let subscriptionName: String
    @Binding var ruleName: String
    @Binding var sqlFilter: String
    @Binding var errorMessage: String?
    @Binding var isAdding: Bool
    let onAdd: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var isValid: Bool {
        !ruleName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !sqlFilter.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Rule")
                .font(.headline)

            Divider()

            Form {
                LabeledContent("Topic") { Text(topicName) }
                LabeledContent("Subscription") { Text(subscriptionName) }

                LabeledContent("Rule Name") {
                    TextField("e.g. HighPriority", text: $ruleName)
                        .textFieldStyle(.roundedBorder)
                }

                LabeledContent("SQL Filter") {
                    TextField("e.g. Priority = 'High'", text: $sqlFilter)
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
                Button("Add Rule") { onAdd() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                    .disabled(!isValid || isAdding)
            }
        }
        .padding()
        .frame(width: 420)
    }
}

// MARK: - Edit Rule Sheet

@available(macOS 15.0, *)
private struct EditRuleSheet: View {
    let ruleName: String
    @Binding var sqlFilter: String
    @Binding var errorMessage: String?
    @Binding var isSaving: Bool
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var isValid: Bool {
        !sqlFilter.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Rule: \(ruleName)")
                .font(.headline)

            Divider()

            Form {
                LabeledContent("SQL Filter") {
                    TextField("e.g. Priority = 'High'", text: $sqlFilter)
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

// MARK: - Toolbar divider (Rules tab)

private var rulesToolbarDivider: some View {
    Divider()
        .frame(height: 16)
        .padding(.horizontal, 2)
}

// MARK: - Description Tab

@available(macOS 15.0, *)
private struct SubDescriptionTab: View {
    @Environment(GRPCManager.self) var grpc
    @Environment(ActivityLogStore.self) var activityLog
    let subscription: SubscriptionItem

    @State private var details: SubscriptionDetailsItem?
    @State private var isLoading = true
    @State private var errorMessage: String?

    // TTL editing
    @State private var isEditingTTL = false
    @State private var editDays    = 0
    @State private var editHours   = 0
    @State private var editMinutes = 0
    @State private var editSeconds = 0
    @State private var isSavingTTL = false

    private var canUpdateProperties: Bool { grpc.capabilityMap.createResources }

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
                            LabeledContent("Default TTL") {
                                if isEditingTTL {
                                    HStack(spacing: 4) {
                                        TTLField("d", value: $editDays)
                                        TTLField("h", value: $editHours)
                                        TTLField("m", value: $editMinutes)
                                        TTLField("s", value: $editSeconds)
                                        Button("Cancel") {
                                            isEditingTTL = false
                                        }
                                        .buttonStyle(.borderless)
                                        .foregroundStyle(.secondary)
                                        Button("Update") {
                                            Task { await saveTTL() }
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(isSavingTTL || editTtlSeconds <= 0)
                                    }
                                } else {
                                    HStack(spacing: 6) {
                                        Text(formatDuration(d.defaultMessageTtlSeconds))
                                        if canUpdateProperties {
                                            Button {
                                                beginEditing(d.defaultMessageTtlSeconds)
                                            } label: {
                                                Image(systemName: "pencil")
                                                    .imageScale(.small)
                                            }
                                            .buttonStyle(.borderless)
                                            .help("Edit default message TTL")
                                        }
                                    }
                                }
                            }
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

    private var editTtlSeconds: Int64 {
        Int64(editDays) * 86_400 + Int64(editHours) * 3_600 + Int64(editMinutes) * 60 + Int64(editSeconds)
    }

    private func beginEditing(_ seconds: Int64) {
        editDays    = Int(seconds / 86_400)
        editHours   = Int((seconds % 86_400) / 3_600)
        editMinutes = Int((seconds % 3_600) / 60)
        editSeconds = Int(seconds % 60)
        isEditingTTL = true
    }

    private func saveTTL() async {
        isSavingTTL = true
        defer { isSavingTTL = false }
        let target = "\(subscription.topicName)/\(subscription.name)"
        do {
            try await grpc.updateSubscriptionTtl(
                topicName: subscription.topicName,
                subscriptionName: subscription.name,
                ttlSeconds: editTtlSeconds
            )
            isEditingTTL = false
            await activityLog.log(action: .updateTtl, messageId: target,
                                  result: .success("TTL updated to \(formatDuration(editTtlSeconds))"))
            await loadDetails()
        } catch {
            await activityLog.log(action: .updateTtl, messageId: target,
                                  result: .failure("TTL update failed"),
                                  hint: error.localizedDescription)
        }
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

// MARK: - TTL Component Field

@available(macOS 15.0, *)
private struct TTLField: View {
    let suffix: String
    @Binding var value: Int

    init(_ suffix: String, value: Binding<Int>) {
        self.suffix = suffix
        self._value = value
    }

    var body: some View {
        HStack(spacing: 1) {
            TextField("0", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 42)
                .multilineTextAlignment(.trailing)
            Text(suffix)
                .foregroundStyle(.secondary)
                .font(.callout)
        }
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
    @State private var selectedMessageIDs: Set<UUID> = []
    @State private var showRepairSheet = false
    @State private var showBulkResubmitSheet = false
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

                subToolbarDivider
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

                subToolbarDivider
            }

            subToolbarDivider

            Button {
                saveMessages(selectedMessages)
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
                    .padding(.horizontal, 8).padding(.vertical, 4)
            }
            .buttonStyle(.borderless)
            .disabled(selectedMessageIDs.isEmpty)
            .help("Save selected message(s) to disk")

            Button {
                if !selectedMessageIDs.isEmpty { showDeleteConfirm = true }
            } label: {
                Label("Delete", systemImage: "trash")
                    .padding(.horizontal, 8).padding(.vertical, 4)
            }
            .buttonStyle(.borderless)
            .disabled(selectedMessageIDs.isEmpty)
            .help("Permanently delete selected message(s)")

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
                        Table(messages, selection: $selectedMessageIDs) {
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
                            if isDLQ && !ids.isEmpty {
                                Button(ids.count == 1
                                       ? "Resubmit Selected Message"
                                       : "Resubmit \(ids.count) Messages") {
                                    selectedMessageIDs = ids
                                    showBulkResubmitSheet = true
                                }
                                Divider()
                            }
                            if ids.count == 1, let id = ids.first {
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
                            if !ids.isEmpty {
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
        .task { await loadMessages() }
        .onChange(of: subscription.name) { _, _ in Task { await loadMessages() } }
        .onChange(of: trigger)           { _, _ in Task { await loadMessages() } }
        .sheet(isPresented: $showRepairSheet) {
            if let msg = selectedMessage {
                RepairResubmitSheet(message: msg, queueOrTopic: subscription.topicName, subscriptionName: subscription.name)
            }
        }
        .sheet(isPresented: $showBulkResubmitSheet, onDismiss: { Task { await loadMessages() } }) {
            BulkResubmitSheet(messages: selectedMessages,
                              queueOrTopic: subscription.topicName,
                              subscriptionName: subscription.name)
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
                    topicName: subscription.topicName,
                    subscriptionName: subscription.name,
                    isDLQ: isDLQ,
                    sequenceNumber: msg.sequenceNumber
                )
                messages.removeAll { $0.id == msg.id }
                selectedMessageIDs.remove(msg.id)
                activityLog.log(action: .delete, messageId: msg.messageId,
                                result: .success("Deleted successfully"))
            } catch {
                activityLog.log(action: .delete, messageId: msg.messageId,
                                result: .failure(error.localizedDescription),
                                hint: "The message may have already been consumed or the subscription lock expired.")
            }
        }
        actionStore.requestRefresh(.subscription(topic: subscription.topicName, sub: subscription.name))
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
