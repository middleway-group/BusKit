import SwiftUI

// MARK: - Duration components helper

private struct DurationComponents {
    var days: Int = 0
    var hours: Int = 0
    var minutes: Int = 0
    var seconds: Int = 0

    var totalSeconds: Int64 {
        Int64(days * 86400 + hours * 3600 + minutes * 60 + seconds)
    }
}

// MARK: - CreateQueueSheet

@available(macOS 15.0, *)
struct CreateQueueSheet: View {
    @Environment(GRPCManager.self) var grpc
    @Environment(ActivityLogStore.self) var activityLog
    @Environment(\.dismiss) private var dismiss

    let onCreated: (String) -> Void

    // Required fields
    @State private var queueName = ""
    @State private var maxDeliveryCount = 10

    // Size
    @State private var maxSizeGbIndex = 0
    private let maxSizeOptions: [(label: String, mb: Int64)] = [
        ("1 GB", 1024), ("2 GB", 2048), ("3 GB", 3072), ("4 GB", 4096), ("5 GB", 5120)
    ]

    // Time fields
    @State private var messageTtl = DurationComponents(days: 14, hours: 0, minutes: 0, seconds: 0)
    @State private var lockDuration = DurationComponents(days: 0, hours: 0, minutes: 1, seconds: 0)

    // Options
    @State private var autoDeleteOnIdle = false
    @State private var duplicateDetection = false
    @State private var deadLetterOnExpiration = false
    @State private var enablePartitioning = false
    @State private var enableSessions = false
    @State private var forwardMessages = false
    @State private var forwardTo = ""

    // State
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var nameIsEmpty = false

    // Dirty-check for cancel confirmation
    @FocusState private var nameFocused: Bool
    @State private var showCancelConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            ScrollView {
                formGrid
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 20)
            }
            if let err = errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(err)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.08))
            }
            Divider()
            footerView
        }
        .frame(width: 560)
        .frame(minHeight: 620)
        .onAppear { nameFocused = true }
        .confirmationDialog(
            "Discard changes?",
            isPresented: $showCancelConfirm,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Your queue configuration will be lost.")
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Create Queue")
                    .font(.headline)
                Text("Service Bus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Form Grid
    //
    // Center-equalized 2-column layout per Apple macOS layout guidelines:
    // - Left column: right-aligned labels
    // - Right column: left-aligned controls
    // - 20 pt outer margins, 14 pt from titlebar to first control
    // - 6 pt between controls, 12 pt padding above/below section separators

    private var formGrid: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 6) {

            // MARK: General

            GridRow {
                HStack(spacing: 2) {
                    Text("Queue name")
                    Text("*").foregroundStyle(.red)
                }
                .font(.system(size: 13))
                .gridColumnAlignment(.trailing)

                VStack(alignment: .leading, spacing: 4) {
                    TextField("Enter queue name", text: $queueName)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .frame(maxWidth: .infinity)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(nameIsEmpty ? Color.red : Color.clear, lineWidth: 1.5)
                        )
                        .onChange(of: queueName) { _, _ in
                            if nameIsEmpty && !queueName.trimmingCharacters(in: .whitespaces).isEmpty {
                                nameIsEmpty = false
                            }
                        }
                        .accessibilityLabel("Queue name, required")
                    if nameIsEmpty {
                        Text("Name is required.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            GridRow {
                Text("Max queue size")
                    .font(.system(size: 13))

                Picker("", selection: $maxSizeGbIndex) {
                    ForEach(maxSizeOptions.indices, id: \.self) { i in
                        Text(maxSizeOptions[i].label).tag(i)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(alignment: .leading)
                .accessibilityLabel("Max queue size")
            }

            GridRow {
                HStack(spacing: 2) {
                    Text("Max delivery count")
                    Text("*").foregroundStyle(.red)
                }
                .font(.system(size: 13))

                HStack(spacing: 4) {
                    TextField("", value: $maxDeliveryCount, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: maxDeliveryCount) { _, v in
                            maxDeliveryCount = max(1, min(2000, v))
                        }
                    Stepper("", value: $maxDeliveryCount, in: 1...2000)
                        .labelsHidden()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Max delivery count, required, 1 to 2000")
            }

            // MARK: Auto-Delete

            formSectionDivider
            formSectionHeader("Auto-Delete")

            GridRow {
                emptyLabel
                HStack(spacing: 8) {
                    Toggle("Enable auto-delete on idle queue", isOn: $autoDeleteOnIdle)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 13))
                        .accessibilityLabel("Enable auto-delete on idle queue")
                    HelpPopover(info: "Automatically delete the queue after it has been idle for a specified duration. Useful for temporary or session-based queues.")
                    Spacer()
                }
            }

            // MARK: Duplicate Detection

            formSectionDivider
            formSectionHeader("Duplicate Detection")

            GridRow {
                emptyLabel
                HStack(spacing: 8) {
                    Toggle("Enable duplicate detection", isOn: $duplicateDetection)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 13))
                        .accessibilityLabel("Enable duplicate detection")
                    HelpPopover(info: "Allows the queue to detect and discard duplicate messages sent within the duplicate detection window.")
                    Spacer()
                }
            }

            // MARK: TTL & Dead-Lettering

            formSectionDivider
            formSectionHeader("TTL & Dead-Lettering")

            GridRow {
                Text("Message time to live:")
                    .font(.system(size: 13))

                durationFields($messageTtl, maxDays: 36500, maxHours: 23, maxMinutes: 59)
            }

            GridRow {
                emptyLabel
                Toggle("Enable dead lettering on message expiration", isOn: $deadLetterOnExpiration)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 13))
                    .accessibilityLabel("Enable dead lettering on message expiration")
            }

            // MARK: Lock Duration

            formSectionDivider
            formSectionHeader("Lock Duration")

            GridRow {
                HStack(spacing: 4) {
                    Text("Lock duration:")
                        .font(.system(size: 13))
                    HelpPopover(info: "Duration a message is locked for processing. Other consumers cannot receive the message while it is locked. Range: 0 seconds to 5 minutes.")
                }

                durationFields($lockDuration, maxDays: 0, maxHours: 0, maxMinutes: 5)
            }

            // MARK: Sessions & Partitioning

            formSectionDivider
            formSectionHeader("Sessions & Partitioning")

            GridRow {
                emptyLabel
                HStack(spacing: 8) {
                    Toggle("Enable sessions", isOn: $enableSessions)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 13))
                        .accessibilityLabel("Enable sessions")
                        .accessibilityHint("Enables session-based FIFO message delivery")
                    HelpPopover(info: "Enables session-based message grouping, allowing related messages to be processed in order by the same consumer.")
                    Spacer()
                }
            }

            GridRow {
                emptyLabel
                HStack(spacing: 8) {
                    Toggle("Enable partitioning", isOn: $enablePartitioning)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 13))
                        .accessibilityLabel("Enable partitioning")
                    HelpPopover(info: "Partitions the queue across multiple message brokers and stores, increasing throughput and availability.")
                    Spacer()
                }
            }

            // MARK: Forwarding

            formSectionDivider
            formSectionHeader("Forwarding")

            GridRow {
                emptyLabel
                HStack(spacing: 8) {
                    Toggle("Forward messages to queue/topic", isOn: $forwardMessages)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 13))
                        .accessibilityLabel("Forward messages to queue or topic")
                    HelpPopover(info: "Automatically forwards messages from this queue to another queue or topic.")
                    Spacer()
                }
            }

            if forwardMessages {
                GridRow {
                    Text("Forward to:")
                        .font(.system(size: 13))

                    TextField("Target queue or topic name", text: $forwardTo)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Forward to queue or topic name")
                }
            }
        }
    }

    // MARK: - Grid Helpers

    /// Invisible spacer that occupies the label column without contributing to its width.
    private var emptyLabel: some View {
        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
    }

    /// Full-width divider row with 12 pt breathing room on each side (per guidelines).
    private var formSectionDivider: some View {
        GridRow {
            Divider()
                .padding(.vertical, 12)
                .gridCellColumns(2)
        }
    }

    /// Section title spanning both columns, left-aligned, bold secondary text.
    private func formSectionHeader(_ title: String) -> some View {
        GridRow {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
                .gridCellColumns(2)
        }
    }

    /// Duration field cluster. Shows Days/Hours when maxDays > 0, Hours when maxHours > 0.
    private func durationFields(
        _ components: Binding<DurationComponents>,
        disabled: Bool = false,
        maxDays: Int = 36500,
        maxHours: Int = 23,
        maxMinutes: Int = 59
    ) -> some View {
        HStack(spacing: 5) {
            if maxDays > 0 {
                durationField("Days", value: components.days, range: 0...maxDays)
            }
            if maxHours > 0 || maxDays > 0 {
                durationField("Hours", value: components.hours, range: 0...maxHours)
            }
            durationField("Minutes", value: components.minutes, range: 0...maxMinutes)
            durationField("Seconds", value: components.seconds, range: 0...59)
        }
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1.0)
    }

    private func durationField(_ label: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        VStack(alignment: .center, spacing: 2) {
            HStack(spacing: 3) {
                TextField("", value: value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 46)
                    .multilineTextAlignment(.trailing)
                    .onChange(of: value.wrappedValue) { _, v in
                        value.wrappedValue = max(range.lowerBound, min(range.upperBound, v))
                    }
                    .accessibilityLabel(label)
                Stepper("", value: value, in: range)
                    .labelsHidden()
            }
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack(spacing: 8) {
            if isCreating {
                ProgressView().controlSize(.small)
                Text("Creating queue…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") {
                if isDirty {
                    showCancelConfirm = true
                } else {
                    dismiss()
                }
            }
            .keyboardShortcut(.escape, modifiers: [])
            .disabled(isCreating)

            Button("Create Queue") {
                Task { await submit() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [])
            .disabled(isSubmitDisabled)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Validation helpers

    private var isSubmitDisabled: Bool {
        isCreating
            || queueName.trimmingCharacters(in: .whitespaces).isEmpty
            || maxDeliveryCount < 1
    }

    private var isDirty: Bool {
        !queueName.isEmpty
            || maxSizeGbIndex != 0
            || maxDeliveryCount != 10
            || messageTtl.days != 14 || messageTtl.hours != 0 || messageTtl.minutes != 0 || messageTtl.seconds != 0
            || lockDuration.days != 0 || lockDuration.hours != 0 || lockDuration.minutes != 1 || lockDuration.seconds != 0
            || autoDeleteOnIdle || duplicateDetection || deadLetterOnExpiration
            || enablePartitioning || enableSessions || forwardMessages
    }

    // MARK: - Submit

    private func submit() async {
        let trimmed = queueName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            nameIsEmpty = true
            nameFocused = true
            return
        }

        isCreating = true
        errorMessage = nil
        defer { isCreating = false }

        do {
            try await grpc.createQueue(
                name: trimmed,
                maxSizeMb: maxSizeOptions[maxSizeGbIndex].mb,
                maxDeliveryCount: Int32(maxDeliveryCount),
                defaultMessageTtlSeconds: messageTtl.totalSeconds,
                lockDurationSeconds: lockDuration.totalSeconds,
                requiresDuplicateDetection: duplicateDetection,
                requiresSession: enableSessions,
                deadLetteringOnExpiration: deadLetterOnExpiration,
                enablePartitioning: enablePartitioning,
                forwardTo: forwardMessages ? forwardTo.trimmingCharacters(in: .whitespaces) : "",
                autoDeleteOnIdleSeconds: autoDeleteOnIdle ? 300 : 0
            )
            activityLog.log(
                action: .createQueue,
                messageId: trimmed,
                result: .success("Queue \"\(trimmed)\" created successfully")
            )
            onCreated(trimmed)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - HelpPopover

@available(macOS 15.0, *)
private struct HelpPopover: View {
    let info: String
    @State private var showPopover = false

    var body: some View {
        Button { showPopover.toggle() } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .imageScale(.small)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More information")
        .accessibilityHint(info)
        .popover(isPresented: $showPopover, arrowEdge: .trailing) {
            Text(info)
                .font(.system(size: 12))
                .padding(12)
                .frame(maxWidth: 280)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
