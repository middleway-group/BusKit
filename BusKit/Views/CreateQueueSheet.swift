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

// MARK: - Duration row

@available(macOS 15.0, *)
private struct DurationRow: View {
    let label: String
    @Binding var components: DurationComponents

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                durationField(label: "Days",    value: $components.days,    range: 0...36500)
                durationField(label: "Hours",   value: $components.hours,   range: 0...23)
                durationField(label: "Minutes", value: $components.minutes, range: 0...59)
                durationField(label: "Seconds", value: $components.seconds, range: 0...59)
            }
        }
    }

    private func durationField(label: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 2) {
                TextField("", value: value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 58)
                    .multilineTextAlignment(.trailing)
                    .onChange(of: value.wrappedValue) { _, v in
                        value.wrappedValue = max(range.lowerBound, min(range.upperBound, v))
                    }
                Stepper("", value: value, in: range)
                    .labelsHidden()
                    .frame(width: 18)
            }
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Option row with info popover

@available(macOS 15.0, *)
private struct OptionRow: View {
    let title: String
    let info: String
    @Binding var isOn: Bool

    @State private var showPopover = false

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $isOn) {
                Text(title)
                    .font(.system(size: 13))
            }
            .toggleStyle(.checkbox)

            Button {
                showPopover.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Info for \(title)")
            .popover(isPresented: $showPopover, arrowEdge: .trailing) {
                Text(info)
                    .font(.system(size: 12))
                    .padding(12)
                    .frame(maxWidth: 280)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .accessibilityElement(children: .contain)
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
                VStack(alignment: .leading, spacing: 20) {
                    nameSection
                    maxSizeSection
                    maxDeliveryCountSection
                    messageTtlSection
                    lockDurationSection
                    optionsSection
                }
                .padding(20)
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
        .frame(width: 480)
        .frame(minHeight: 600)
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

    // MARK: - Queue Name

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Queue Name")
                    .font(.system(size: 13))
                Text("*")
                    .foregroundStyle(.red)
                    .font(.system(size: 13))
            }
            TextField("Enter queue name", text: $queueName)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
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
            Text("Must be unique within the namespace.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Max Queue Size

    private var maxSizeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Max Queue Size")
                .font(.system(size: 13))
            Picker("", selection: $maxSizeGbIndex) {
                ForEach(maxSizeOptions.indices, id: \.self) { i in
                    Text(maxSizeOptions[i].label).tag(i)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Max queue size")
        }
    }

    // MARK: - Max Delivery Count

    private var maxDeliveryCountSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Max Delivery Count")
                    .font(.system(size: 13))
                Text("*")
                    .foregroundStyle(.red)
                    .font(.system(size: 13))
            }
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
    }

    // MARK: - Message TTL

    private var messageTtlSection: some View {
        DurationRow(label: "Message Time to Live", components: $messageTtl)
    }

    // MARK: - Lock Duration

    private var lockDurationSection: some View {
        DurationRow(label: "Lock Duration", components: $lockDuration)
    }

    // MARK: - Options

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("OPTIONS")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                OptionRow(
                    title: "Enable auto-delete on idle queue",
                    info: "Automatically delete the queue after it has been idle for a specified duration. Useful for temporary or session-based queues.",
                    isOn: $autoDeleteOnIdle
                )
                OptionRow(
                    title: "Enable duplicate detection",
                    info: "Allows the queue to detect and discard duplicate messages sent within the duplicate detection window.",
                    isOn: $duplicateDetection
                )
                OptionRow(
                    title: "Enable dead lettering on message expiration",
                    info: "When enabled, expired messages are moved to the dead-letter sub-queue instead of being discarded.",
                    isOn: $deadLetterOnExpiration
                )
                OptionRow(
                    title: "Enable partitioning",
                    info: "Partitions the queue across multiple message brokers and stores, increasing throughput and availability.",
                    isOn: $enablePartitioning
                )
                OptionRow(
                    title: "Enable sessions",
                    info: "Enables session-based message grouping, allowing related messages to be processed in order by the same consumer.",
                    isOn: $enableSessions
                )

                OptionRow(
                    title: "Forward messages to queue/topic",
                    info: "Automatically forwards messages from this queue to another queue or topic.",
                    isOn: $forwardMessages
                )
                if forwardMessages {
                    TextField("Target queue or topic name", text: $forwardTo)
                        .textFieldStyle(.roundedBorder)
                        .padding(.leading, 22)
                        .accessibilityLabel("Forward to queue or topic name")
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
