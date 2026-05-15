import SwiftUI

// MARK: - CreateSubscriptionSheet

@available(macOS 15.0, *)
struct CreateSubscriptionSheet: View {
    @Environment(GRPCManager.self) var grpc
    @Environment(ActivityLogStore.self) var activityLog
    @Environment(\.dismiss) private var dismiss

    let topicName: String
    let onCreated: (String) -> Void

    // Required fields
    @State private var subscriptionName = ""
    @State private var maxDeliveryCount = 10

    // Auto-Delete
    @State private var autoDelete = SubDurationComponents(days: 14, hours: 0, minutes: 0, seconds: 0)
    @State private var neverAutoDelete = true
    @State private var forwardMessages = false
    @State private var forwardTo = ""

    // Message Sessions
    @State private var enableSessions = false

    // TTL & Dead-Lettering
    @State private var messageTtl = SubDurationComponents(days: 14, hours: 0, minutes: 0, seconds: 0)
    @State private var deadLetterOnExpiration = false
    @State private var deadLetterOnFilterException = false

    // Lock Duration
    @State private var lockDuration = SubDurationComponents(days: 0, hours: 0, minutes: 1, seconds: 0)

    // State
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var nameIsEmpty = false

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
            Text("Your subscription configuration will be lost.")
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Create Subscription")
                    .font(.headline)
                Text("Service Bus · \(topicName)")
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
                    Text("Name")
                    Text("*").foregroundStyle(.red)
                }
                .font(.system(size: 13))
                .gridColumnAlignment(.trailing)

                VStack(alignment: .leading, spacing: 4) {
                    TextField("Enter subscription name", text: $subscriptionName)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .frame(maxWidth: .infinity)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(nameIsEmpty ? Color.red : Color.clear, lineWidth: 1.5)
                        )
                        .onChange(of: subscriptionName) { _, _ in
                            if nameIsEmpty && !subscriptionName.trimmingCharacters(in: .whitespaces).isEmpty {
                                nameIsEmpty = false
                            }
                        }
                        .accessibilityLabel("Subscription name, required")
                    if nameIsEmpty {
                        Text("Name is required.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
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
                Text("Auto-delete after idle:")
                    .font(.system(size: 13))
                    .foregroundStyle(neverAutoDelete ? .secondary : .primary)

                durationFields($autoDelete, disabled: neverAutoDelete, maxDays: 36500, maxHours: 23, maxMinutes: 59)
            }

            GridRow {
                emptyLabel
                Toggle("Never auto-delete", isOn: $neverAutoDelete)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 13))
                    .accessibilityLabel("Never auto-delete")
                    .accessibilityHint("When enabled, disables the auto-delete idle time fields")
            }

            GridRow {
                emptyLabel
                HStack(spacing: 8) {
                    Toggle("Forward messages to queue/topic", isOn: $forwardMessages)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 13))
                        .accessibilityLabel("Forward messages to queue or topic")
                    SubHelpPopover(
                        info: "When enabled, messages from this subscription are automatically forwarded to the specified queue or topic."
                    )
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

            // MARK: Message Sessions

            formSectionDivider
            formSectionHeader("Message Sessions")

            GridRow {
                emptyLabel
                (
                    Text("Sessions enable ordered, lock-based processing of related messages using a session identifier. Only one consumer processes messages per session at a time.  ")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    + Text("[Learn more](https://learn.microsoft.com/azure/service-bus-messaging/message-sessions)")
                        .font(.system(size: 12))
                )
                .fixedSize(horizontal: false, vertical: true)
            }

            GridRow {
                emptyLabel
                Toggle("Enable sessions", isOn: $enableSessions)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 13))
                    .accessibilityLabel("Enable sessions")
                    .accessibilityHint("Enables session-based FIFO message delivery")
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

            GridRow {
                emptyLabel
                Toggle("Move messages that cause filter evaluation exceptions to the dead-letter subqueue", isOn: $deadLetterOnFilterException)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Move messages causing filter evaluation exceptions to dead-letter subqueue")
            }

            // MARK: Lock Duration

            formSectionDivider
            formSectionHeader("Lock Duration")

            GridRow {
                HStack(spacing: 4) {
                    Text("Lock duration:")
                        .font(.system(size: 13))
                    SubHelpPopover(
                        info: "Duration a message is locked for processing. Other consumers cannot receive the message while it is locked. Range: 0 seconds to 5 minutes."
                    )
                }

                durationFields($lockDuration, maxDays: 0, maxHours: 0, maxMinutes: 5)
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
        _ components: Binding<SubDurationComponents>,
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
                Text("Creating subscription…")
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

            Button("Create") {
                Task { await submit() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [])
            .disabled(isSubmitDisabled)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Validation

    private var isSubmitDisabled: Bool {
        isCreating || subscriptionName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var isDirty: Bool {
        !subscriptionName.isEmpty
            || maxDeliveryCount != 10
            || !neverAutoDelete
            || enableSessions
            || deadLetterOnExpiration
            || deadLetterOnFilterException
            || forwardMessages
            || messageTtl.days != 14 || messageTtl.hours != 0 || messageTtl.minutes != 0 || messageTtl.seconds != 0
    }

    // MARK: - Submit

    private func submit() async {
        let trimmed = subscriptionName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            nameIsEmpty = true
            nameFocused = true
            return
        }

        isCreating = true
        errorMessage = nil
        defer { isCreating = false }

        do {
            try await grpc.createSubscription(
                topicName: topicName,
                subscriptionName: trimmed,
                maxDeliveryCount: Int32(maxDeliveryCount),
                defaultMessageTtlSeconds: messageTtl.totalSeconds,
                lockDurationSeconds: lockDuration.totalSeconds,
                autoDeleteOnIdleSeconds: neverAutoDelete ? 0 : autoDelete.totalSeconds,
                neverAutoDelete: neverAutoDelete,
                enableSessions: enableSessions,
                deadLetteringOnExpiration: deadLetterOnExpiration,
                deadLetteringOnFilterEvaluation: deadLetterOnFilterException,
                forwardMessages: forwardMessages,
                forwardTo: forwardMessages ? forwardTo.trimmingCharacters(in: .whitespaces) : ""
            )
            activityLog.log(
                action: .createSubscription,
                messageId: trimmed,
                result: .success("Subscription \"\(trimmed)\" created in topic \"\(topicName)\"")
            )
            onCreated(trimmed)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Helpers

private struct SubDurationComponents {
    var days: Int = 0
    var hours: Int = 0
    var minutes: Int = 0
    var seconds: Int = 0

    var totalSeconds: Int64 {
        Int64(days * 86400 + hours * 3600 + minutes * 60 + seconds)
    }
}

@available(macOS 15.0, *)
private struct SubHelpPopover: View {
    let info: String
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
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
