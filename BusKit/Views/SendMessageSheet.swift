import SwiftUI
import UniformTypeIdentifiers

// MARK: - Content type options

private enum ContentTypeOption: String, CaseIterable {
    case json      = "application/json"
    case xml       = "application/xml"
    case plainText = "text/plain"

    var displayName: String { rawValue }

    var allowedFileTypes: [UTType] {
        switch self {
        case .json:      return [.json]
        case .xml:       return [.xml]
        case .plainText: return [.plainText]
        }
    }
}

// MARK: - Custom property type

private enum CustomPropertyType: String, CaseIterable {
    case string  = "String"
    case number  = "Number"
    case boolean = "Boolean"
    case date    = "Date"
}

// MARK: - Custom property row model

private struct CustomProperty: Identifiable {
    let id          = UUID()
    var key         = ""
    var type        = CustomPropertyType.string
    var stringValue = ""
    var numberValue = ""
    var boolValue   = true
    var dateValue   = Date()

    /// String representation sent to the broker via application properties.
    var serializedValue: String {
        switch type {
        case .string:  return stringValue
        case .number:  return numberValue
        case .boolean: return boolValue ? "true" : "false"
        case .date:    return ISO8601DateFormatter().string(from: dateValue)
        }
    }
}

// MARK: - Duration components helper

private struct MsgDuration {
    var days: Int    = 0
    var hours: Int   = 0
    var minutes: Int = 0
    var seconds: Int = 0

    var totalSeconds: Int64 {
        Int64(days * 86_400 + hours * 3_600 + minutes * 60 + seconds)
    }
    var isZero: Bool { totalSeconds == 0 }
}

// MARK: - SendMessageSheet

@available(macOS 15.0, *)
struct SendMessageSheet: View {
    @Environment(GRPCManager.self) var grpc
    @Environment(ActivityLogStore.self) var activityLog
    @Environment(\.dismiss) private var dismiss

    /// Queue name or topic name to send to.
    let queueOrTopic: String
    /// "Queue" or "Topic" — used in the header subtitle.
    let entityLabel: String

    // ── Content ────────────────────────────────────────────────
    @State private var contentType       = ContentTypeOption.json
    @State private var messageBody       = ""
    @State private var showFileImporter  = false

    // ── Broker properties ───────────────────────────────────────
    @State private var correlationId = ""
    @State private var messageId     = ""
    @State private var replyTo       = ""
    @State private var subject       = ""
    @State private var toAddress     = ""
    @State private var sessionId     = ""

    // ── Time settings ───────────────────────────────────────────
    @State private var setTTL          = false
    @State private var ttl             = MsgDuration()
    @State private var setScheduled    = false
    @State private var scheduledDate   = Date()

    // ── Custom properties ───────────────────────────────────────
    @State private var customProperties: [CustomProperty] = []

    // ── Repeat send ─────────────────────────────────────────────
    @State private var repeatSend        = false
    @State private var repeatCount       = 1
    @State private var repeatIntervalMs  = 0

    // ── State ────────────────────────────────────────────────────
    @State private var isSending        = false
    @State private var sentCount        = 0
    @State private var errorMessage: String?
    @State private var showCancelConfirm = false

    @FocusState private var bodyFocused: Bool

    // MARK: - Body

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
        .frame(width: 600)
        .frame(minHeight: 700)
        .onAppear { bodyFocused = true }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: contentType.allowedFileTypes
        ) { result in
            guard case .success(let url) = result,
                  url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                messageBody = text
            }
        }
        .confirmationDialog(
            "Discard changes?",
            isPresented: $showCancelConfirm,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Your message configuration will be lost.")
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Send Message")
                    .font(.headline)
                Text("\(entityLabel) · \(queueOrTopic)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Form Grid

    private var formGrid: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 6) {

            // ── Message Content ──────────────────────────────────────
            formSectionHeader("Message Content")

            GridRow {
                Text("Content type:")
                    .font(.system(size: 13))
                    .gridColumnAlignment(.trailing)   // anchors trailing alignment for whole label column

                Picker("", selection: $contentType) {
                    ForEach(ContentTypeOption.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 220, alignment: .leading)
                .onChange(of: contentType) { _, _ in
                    // Clear body when content type changes so stale content doesn't mislead.
                }
            }

            GridRow {
                emptyLabel
                Button {
                    showFileImporter = true
                } label: {
                    Label("Upload File…", systemImage: "document.badge.arrow.up")
                }
                .controlSize(.small)
                .help("Load message body from a file. Accepted: \(contentType.allowedFileTypes.compactMap { $0.preferredFilenameExtension }.map { ".\($0)" }.joined(separator: ", "))")
            }

            GridRow {
                HStack(spacing: 2) {
                    Text("Message body:")
                    Text("*").foregroundStyle(.red)
                }
                .font(.system(size: 13))

                TextEditor(text: $messageBody)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 120, maxHeight: 200)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                    .focused($bodyFocused)
                    .accessibilityLabel("Message body, required")
            }

            formSectionDivider

            // ── Broker Properties ────────────────────────────────────
            formSectionHeader("Broker Properties")

            brokerRow(label: "Correlation ID:", binding: $correlationId,
                      placeholder: "Optional")
            brokerRow(label: "Message ID:", binding: $messageId,
                      placeholder: "Auto-generated if empty")
            brokerRow(label: "Reply To:", binding: $replyTo,
                      placeholder: "Optional")
            brokerRow(label: "Label / Subject:", binding: $subject,
                      placeholder: "Optional")
            brokerRow(label: "To:", binding: $toAddress,
                      placeholder: "Optional")
            brokerRow(label: "Session ID:", binding: $sessionId,
                      placeholder: "Optional")

            formSectionDivider

            // ── Time Settings ────────────────────────────────────────
            formSectionHeader("Time Settings")

            GridRow {
                emptyLabel
                Toggle("Set time to live", isOn: $setTTL)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 13))
            }

            if setTTL {
                GridRow {
                    Text("Time to live:")
                        .font(.system(size: 13))
                    durationFields($ttl)
                }
            }

            GridRow {
                emptyLabel
                Toggle("Set scheduled enqueue time", isOn: $setScheduled)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 13))
            }

            if setScheduled {
                GridRow {
                    Text("Enqueue at:")
                        .font(.system(size: 13))
                    DatePicker(
                        "",
                        selection: $scheduledDate,
                        in: Date()...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .labelsHidden()
                    .frame(alignment: .leading)
                }
            }

            formSectionDivider

            // ── Custom Properties ────────────────────────────────────
            formSectionHeader("Custom Properties")

            if customProperties.isEmpty {
                GridRow {
                    emptyLabel
                    Text("No custom properties. Click \u{201C}Add Property\u{201D} to add one.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else {
                customPropertiesHeader
                ForEach($customProperties) { $prop in
                    customPropertyRow($prop)
                }
            }

            GridRow {
                emptyLabel
                Button {
                    customProperties.append(CustomProperty())
                } label: {
                    Label("Add Property", systemImage: "plus")
                }
                .controlSize(.small)
            }

            formSectionDivider

            // ── Repeat Send ──────────────────────────────────────────
            formSectionHeader("Repeat Send")

            GridRow {
                emptyLabel
                Toggle("Repeat send", isOn: $repeatSend)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 13))
            }

            if repeatSend {
                GridRow {
                    Text("Number of messages:")
                        .font(.system(size: 13))
                    HStack(spacing: 4) {
                        TextField("", value: $repeatCount, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: repeatCount) { _, v in repeatCount = max(1, v) }
                        Stepper("", value: $repeatCount, in: 1...10_000)
                            .labelsHidden()
                    }
                }

                GridRow {
                    Text("Interval (ms):")
                        .font(.system(size: 13))
                    HStack(spacing: 4) {
                        TextField("", value: $repeatIntervalMs, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: repeatIntervalMs) { _, v in repeatIntervalMs = max(0, v) }
                        Stepper("", value: $repeatIntervalMs, in: 0...600_000)
                            .labelsHidden()
                    }
                }
            }
        }
    }

    // MARK: - Custom property subviews

    private var customPropertiesHeader: some View {
        GridRow {
            emptyLabel
            HStack(spacing: 0) {
                Text("Key")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 110, alignment: .leading)
                Text("Type")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
                Text("Value")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 100, alignment: .leading)
            }
            .padding(.bottom, 2)
        }
    }

    @ViewBuilder
    private func customPropertyRow(_ prop: Binding<CustomProperty>) -> some View {
        GridRow {
            emptyLabel
            HStack(spacing: 6) {
                TextField("Key", text: prop.key)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 100)

                Picker("", selection: prop.type) {
                    ForEach(CustomPropertyType.allCases, id: \.self) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .labelsHidden()
                .frame(width: 90)

                customPropertyValueField(prop)

                Button(role: .destructive) {
                    customProperties.removeAll { $0.id == prop.id }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove property")
            }
        }
    }

    @ViewBuilder
    private func customPropertyValueField(_ prop: Binding<CustomProperty>) -> some View {
        switch prop.wrappedValue.type {
        case .string:
            TextField("Value", text: prop.stringValue)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 100)
        case .number:
            TextField("Value", text: prop.numberValue)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 100)
        case .boolean:
            Picker("", selection: prop.boolValue) {
                Text("true").tag(true)
                Text("false").tag(false)
            }
            .labelsHidden()
            .frame(width: 90)
        case .date:
            DatePicker("", selection: prop.dateValue, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .frame(minWidth: 200)
        }
    }

    // MARK: - Grid helpers

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

    @ViewBuilder
    private func brokerRow(label: String, binding: Binding<String>, placeholder: String) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 13))
            TextField(placeholder, text: binding)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Duration picker helpers

    private func durationFields(_ components: Binding<MsgDuration>) -> some View {
        HStack(spacing: 5) {
            durationField("Days",    value: components.days,    range: 0...36_500)
            durationField("Hours",   value: components.hours,   range: 0...23)
            durationField("Minutes", value: components.minutes, range: 0...59)
            durationField("Seconds", value: components.seconds, range: 0...59)
        }
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
            if isSending {
                ProgressView().controlSize(.small)
                Text(repeatSend ? "Sending \(sentCount) / \(repeatCount)…" : "Sending…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") {
                if isDirty { showCancelConfirm = true } else { dismiss() }
            }
            .keyboardShortcut(.escape, modifiers: [])
            .disabled(isSending)

            Button("Send") {
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
        messageBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending
    }

    private var isDirty: Bool {
        !messageBody.isEmpty   || !correlationId.isEmpty || !messageId.isEmpty  ||
        !replyTo.isEmpty       || !subject.isEmpty        || !toAddress.isEmpty ||
        !sessionId.isEmpty     || !customProperties.isEmpty
    }

    // MARK: - Build properties dict

    private func buildProperties() -> [String: String] {
        var props: [String: String] = [:]

        if setTTL && !ttl.isZero {
            // Reserved key: sidecar converts this to ServiceBusMessage.TimeToLive
            props["x-buskit-ttl-seconds"] = "\(ttl.totalSeconds)"
        }

        if setScheduled {
            // Reserved key: sidecar converts this to ServiceBusMessage.ScheduledEnqueueTime
            props["x-buskit-scheduled-enqueue-time-unix"] = "\(Int64(scheduledDate.timeIntervalSince1970))"
        }

        for cp in customProperties where !cp.key.isEmpty {
            props[cp.key] = cp.serializedValue
        }

        return props
    }

    // MARK: - Submit

    private func submit() async {
        let body = messageBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }

        isSending    = true
        sentCount    = 0
        errorMessage = nil

        let count      = repeatSend ? repeatCount : 1
        let intervalNs = UInt64(max(0, repeatIntervalMs)) * 1_000_000

        do {
            for i in 0..<count {
                sentCount = i + 1
                _ = try await grpc.sendMessageExtended(
                    queueOrTopic: queueOrTopic,
                    body: body,
                    contentType: contentType.rawValue,
                    subject: subject,
                    correlationID: correlationId,
                    replyTo: replyTo,
                    toAddress: toAddress,
                    sessionID: sessionId,
                    messageID: messageId,
                    properties: buildProperties()
                )
                if intervalNs > 0 && i < count - 1 {
                    try await Task.sleep(nanoseconds: intervalNs)
                }
            }
            let summary = count == 1
                ? "Message sent to \"\(queueOrTopic)\""
                : "\(count) messages sent to \"\(queueOrTopic)\""
            activityLog.log(action: .sendMessage, messageId: queueOrTopic, result: .success(summary))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            activityLog.log(
                action: .sendMessage, messageId: queueOrTopic,
                result: .failure(error.localizedDescription),
                hint: "Check that you have the Azure Service Bus Data Sender role."
            )
            isSending = false
        }
    }
}
