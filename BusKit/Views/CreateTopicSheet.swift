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
    @State private var autoDeleteOnIdle   = false
    @State private var duplicateDetection = false
    @State private var enablePartitioning = false
    @State private var supportOrdering    = false

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
        .frame(minHeight: 520)
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
                    TextField("Enter topic name", text: $topicName)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .frame(maxWidth: .infinity)
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
                    if nameIsEmpty {
                        Text("Name is required.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            GridRow {
                emptyLabel
                Text("Must be unique within the namespace.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // MARK: Size & Retention

            formSectionDivider
            formSectionHeader("Size & Retention")

            GridRow {
                HStack(spacing: 4) {
                    Text("Maximum size:")
                        .font(.system(size: 13))
                    HelpPopover(info: "The maximum size of the topic in gigabytes.")
                }

                Picker("", selection: $maxSizeGbIndex) {
                    ForEach(maxSizeOptions.indices, id: \.self) { i in
                        Text(maxSizeOptions[i].label).tag(i)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel("Maximum topic size")
            }

            GridRow {
                HStack(spacing: 4) {
                    Text("Message time to live:")
                        .font(.system(size: 13))
                    HelpPopover(info: "The default duration for which a message is retained if not consumed.")
                }

                durationFields($messageTtl, maxDays: 36500, maxHours: 23, maxMinutes: 59)
            }

            // MARK: Options

            formSectionDivider
            formSectionHeader("Options")

            GridRow {
                emptyLabel
                HStack(spacing: 8) {
                    Toggle("Enable auto-delete on idle topic", isOn: $autoDeleteOnIdle)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 13))
                        .accessibilityLabel("Enable auto-delete on idle topic")
                    HelpPopover(info: "Automatically deletes the topic when it has been idle (no subscriptions active) for the specified duration.")
                    Spacer()
                }
            }

            GridRow {
                emptyLabel
                HStack(spacing: 8) {
                    Toggle("Enable duplicate detection", isOn: $duplicateDetection)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 13))
                        .accessibilityLabel("Enable duplicate detection")
                    HelpPopover(info: "Detects and discards duplicate messages published within the duplicate detection history window.")
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
                    HelpPopover(info: "Partitions the topic across multiple message brokers and stores to increase throughput and availability.")
                    Spacer()
                }
            }

            GridRow {
                emptyLabel
                HStack(spacing: 8) {
                    Toggle("Support ordering", isOn: $supportOrdering)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 13))
                        .accessibilityLabel("Support ordering")
                    HelpPopover(info: "Ensures messages are delivered in the order they were published. Cannot be combined with partitioning.")
                    Spacer()
                }
            }
        }
    }

    // MARK: - Grid Helpers

    private var emptyLabel: some View {
        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
    }

    private var formSectionDivider: some View {
        GridRow {
            Divider()
                .padding(.vertical, 12)
                .gridCellColumns(2)
        }
    }

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
