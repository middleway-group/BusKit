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
                VStack(alignment: .leading, spacing: 20) {
                    generalSection
                    autoDeleteSection
                    sessionsSection
                    ttlDeadLetterSection
                    lockDurationSection
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
        .frame(width: 560)
        .frame(minHeight: 640)
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

    // MARK: - Section 1: General

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Name
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text("Name")
                        .font(.system(size: 13))
                    Text("*")
                        .foregroundStyle(.red)
                        .font(.system(size: 13))
                }
                TextField("Enter subscription name", text: $subscriptionName)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
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

            // Max Delivery Count
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text("Max delivery count")
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
    }

    // MARK: - Section 2: Auto-Delete

    private var autoDeleteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SubSectionHeader(title: "AUTO-DELETE")

            SubDurationRow(
                label: "Auto-delete after idle for",
                components: $autoDelete,
                disabled: neverAutoDelete
            )

            Toggle(isOn: $neverAutoDelete) {
                Text("Never auto-delete")
                    .font(.system(size: 13))
            }
            .toggleStyle(.checkbox)
            .accessibilityLabel("Never auto-delete")
            .accessibilityHint("When enabled, disables the auto-delete idle time fields")

            HStack(spacing: 8) {
                Toggle(isOn: $forwardMessages) {
                    Text("Forward messages to queue/topic")
                        .font(.system(size: 13))
                }
                .toggleStyle(.checkbox)
                .accessibilityLabel("Forward messages to queue or topic")

                SubHelpPopover(
                    info: "When enabled, messages from this subscription are automatically forwarded to the specified queue or topic."
                )
                Spacer()
            }

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
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }

    // MARK: - Section 3: Message Sessions

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SubSectionHeader(title: "MESSAGE SESSIONS")

            Text("Sessions enable ordered, lock-based processing of related messages using a session identifier. Only one consumer processes messages per session at a time. ")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            + Text("[Learn more](https://learn.microsoft.com/azure/service-bus-messaging/message-sessions)")
                .font(.system(size: 12))

            Toggle(isOn: $enableSessions) {
                Text("Enable sessions")
                    .font(.system(size: 13))
            }
            .toggleStyle(.checkbox)
            .accessibilityLabel("Enable sessions")
            .accessibilityHint("Enables session-based FIFO message delivery")
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }

    // MARK: - Section 4: TTL & Dead-Lettering

    private var ttlDeadLetterSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SubSectionHeader(title: "MESSAGE TIME TO LIVE AND DEAD-LETTERING")

            SubDurationRow(label: "Message time to live (default)", components: $messageTtl)

            Toggle(isOn: $deadLetterOnExpiration) {
                Text("Enable dead lettering on message expiration")
                    .font(.system(size: 13))
            }
            .toggleStyle(.checkbox)
            .accessibilityLabel("Enable dead lettering on message expiration")

            Toggle(isOn: $deadLetterOnFilterException) {
                Text("Move messages that cause filter evaluation exceptions to the dead-letter subqueue")
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
            .accessibilityLabel("Move messages causing filter evaluation exceptions to dead-letter subqueue")
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }

    // MARK: - Section 5: Lock Duration

    private var lockDurationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SubSectionHeader(title: "MESSAGE LOCK DURATION")

            HStack(spacing: 6) {
                Text("Lock duration")
                    .font(.system(size: 13))
                SubHelpPopover(
                    info: "Duration a message is locked for processing. Other consumers cannot receive the message while it is locked. Range: 0 seconds to 5 minutes."
                )
            }

            SubDurationRow(label: nil, components: $lockDuration, maxDays: 0, maxHours: 0, maxMinutes: 5)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
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
private struct SubSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
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

@available(macOS 15.0, *)
private struct SubDurationRow: View {
    let label: String?
    @Binding var components: SubDurationComponents
    var disabled: Bool = false
    var maxDays: Int = 36500
    var maxHours: Int = 23
    var maxMinutes: Int = 59

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(disabled ? .secondary : .primary)
            }

            HStack(spacing: 12) {
                if maxDays > 0 {
                    durationField(label: "Days", value: $components.days, range: 0...maxDays)
                }
                if maxHours > 0 || maxDays > 0 {
                    durationField(label: "Hours", value: $components.hours, range: 0...maxHours)
                }
                durationField(label: "Minutes", value: $components.minutes, range: 0...maxMinutes)
                durationField(label: "Seconds", value: $components.seconds, range: 0...59)
            }
            .disabled(disabled)
            .opacity(disabled ? 0.4 : 1.0)
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
                    .accessibilityLabel("\(label)")
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
