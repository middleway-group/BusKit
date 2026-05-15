import SwiftUI

// MARK: - CreateTopicSheet

@available(macOS 15.0, *)
struct CreateTopicSheet: View {
    @Environment(GRPCManager.self) var grpc
    @Environment(ActivityLogStore.self) var activityLog
    @Environment(\.dismiss) private var dismiss

    let onCreated: (String) -> Void

    // Required fields
    @State private var topicName = ""

    // Size
    @State private var maxSizeGbIndex = 0
    private let maxSizeOptions: [(label: String, mb: Int64)] = [
        ("1 GB", 1024), ("2 GB", 2048), ("3 GB", 3072), ("4 GB", 4096), ("5 GB", 5120)
    ]

    // Time to live
    @State private var messageTtl = DurationComponents(days: 14, hours: 0, minutes: 0, seconds: 0)

    // Options
    @State private var autoDeleteOnIdle      = false
    @State private var duplicateDetection    = false
    @State private var enablePartitioning    = false
    @State private var supportOrdering       = false

    // State
    @State private var isCreating   = false
    @State private var errorMessage: String?
    @State private var nameIsEmpty  = false

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
                    messageTtlSection
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
        .frame(minHeight: 540)
        .onAppear { nameFocused = true }
        .confirmationDialog(
            "Discard changes?",
            isPresented: $showCancelConfirm,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Your topic configuration will be lost.")
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Create Topic")
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

    // MARK: - Topic Name

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Name")
                    .font(.system(size: 13))
                Text("*")
                    .foregroundStyle(.red)
                    .font(.system(size: 13))
            }
            TextField("Enter topic name", text: $topicName)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(nameIsEmpty ? Color.red : Color.clear, lineWidth: 1.5)
                )
                .onChange(of: topicName) { _, _ in
                    if nameIsEmpty && !topicName.trimmingCharacters(in: .whitespaces).isEmpty {
                        nameIsEmpty = false
                    }
                }
                .accessibilityLabel("Topic name, required")
            Text("Must be unique within the namespace.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Max Topic Size

    private var maxSizeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HelpLabel(title: "Maximum Topic Size", info: "The maximum size of the topic in gigabytes.")
            Picker("", selection: $maxSizeGbIndex) {
                ForEach(maxSizeOptions.indices, id: \.self) { i in
                    Text(maxSizeOptions[i].label).tag(i)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Maximum topic size")
        }
    }

    // MARK: - Message TTL

    private var messageTtlSection: some View {
        TopicDurationRow(label: "Message Time to Live",
                         info: "The default duration for which a message is retained if not consumed.",
                         components: $messageTtl)
    }

    // MARK: - Options

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("OPTIONS")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                TopicOptionRow(
                    title: "Enable auto-delete on idle topic",
                    info: "Automatically deletes the topic when it has been idle (no subscriptions active) for the specified duration.",
                    isOn: $autoDeleteOnIdle
                )
                TopicOptionRow(
                    title: "Enable duplicate detection",
                    info: "Detects and discards duplicate messages published within the duplicate detection history window.",
                    isOn: $duplicateDetection
                )
                TopicOptionRow(
                    title: "Enable partitioning",
                    info: "Partitions the topic across multiple message brokers and stores to increase throughput and availability.",
                    isOn: $enablePartitioning
                )
                TopicOptionRow(
                    title: "Support ordering",
                    info: "Ensures messages are delivered in the order they were published. Cannot be combined with partitioning.",
                    isOn: $supportOrdering
                )
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
                Text("Creating topic…")
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

            Button("Create Topic") {
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
        isCreating || topicName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var isDirty: Bool {
        !topicName.isEmpty
            || maxSizeGbIndex != 0
            || messageTtl.days != 14 || messageTtl.hours != 0 || messageTtl.minutes != 0 || messageTtl.seconds != 0
            || autoDeleteOnIdle || duplicateDetection || enablePartitioning || supportOrdering
    }

    // MARK: - Submit

    private func submit() async {
        let trimmed = topicName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            nameIsEmpty = true
            nameFocused = true
            return
        }

        isCreating = true
        errorMessage = nil
        defer { isCreating = false }

        do {
            try await grpc.createTopic(
                name: trimmed,
                maxSizeMb: maxSizeOptions[maxSizeGbIndex].mb,
                defaultMessageTtlSeconds: messageTtl.totalSeconds,
                requiresDuplicateDetection: duplicateDetection,
                enablePartitioning: enablePartitioning,
                supportOrdering: supportOrdering,
                autoDeleteOnIdleSeconds: autoDeleteOnIdle ? 300 : 0
            )
            activityLog.log(
                action: .createTopic,
                messageId: trimmed,
                result: .success("Topic \"\(trimmed)\" created successfully")
            )
            onCreated(trimmed)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Helpers

// Reuse the DurationComponents type from CreateQueueSheet via a local private alias.
// (DurationComponents is defined privately in CreateQueueSheet.swift; we re-declare here.)
private struct DurationComponents {
    var days: Int = 0
    var hours: Int = 0
    var minutes: Int = 0
    var seconds: Int = 0

    var totalSeconds: Int64 {
        Int64(days * 86400 + hours * 3600 + minutes * 60 + seconds)
    }
}

@available(macOS 15.0, *)
private struct TopicDurationRow: View {
    let label: String
    let info: String
    @Binding var components: DurationComponents

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HelpLabel(title: label, info: info)

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

@available(macOS 15.0, *)
private struct TopicOptionRow: View {
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

@available(macOS 15.0, *)
private struct HelpLabel: View {
    let title: String
    let info: String
    @State private var showPopover = false

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 13))
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
        }
    }
}
