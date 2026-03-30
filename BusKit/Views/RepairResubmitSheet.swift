import SwiftUI
import AppKit

// MARK: - Main Sheet

@available(macOS 15.0, *)
struct RepairResubmitSheet: View {
    @Environment(GRPCManager.self) var grpc
    @Environment(\.dismiss) var dismiss
    @Environment(EntityActionStore.self) var actionStore

    let message: MessageItem

    @State private var targetDestination: String
    @State private var messageBody: String
    @State private var contentType: String
    @State private var subject: String
    @State private var correlationID: String
    @State private var replyTo: String
    @State private var toAddress: String
    @State private var sessionID: String
    @State private var partitionKey: String
    @State private var properties: [(key: String, value: String)]

    @State private var availableQueues: [Buskit_QueueInfo] = []
    @State private var availableTopics: [Buskit_TopicInfo] = []
    @State private var isLoadingDestinations = false

    @State private var isSending = false
    @State private var sendError: String?
    @State private var didSend = false


    init(message: MessageItem, queueOrTopic: String) {
        self.message = message
        _targetDestination = State(initialValue: queueOrTopic)
        _messageBody = State(initialValue: message.body)
        _contentType = State(initialValue: message.contentType)
        _subject = State(initialValue: message.subject)
        _correlationID = State(initialValue: message.correlationId)
        _replyTo = State(initialValue: message.replyTo)
        _toAddress = State(initialValue: message.toAddress)
        _sessionID = State(initialValue: message.sessionId)
        _partitionKey = State(initialValue: message.partitionKey)
        _properties = State(initialValue: message.properties.sorted(by: { $0.key < $1.key }).map { (key: $0.key, value: $0.value) })
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            HStack(alignment: .top, spacing: 0) {
                leftPanel
                Divider()
                rightPanel
            }
            .frame(maxHeight: .infinity)
            Divider()
            footerView
        }
        .frame(width: 1100, height: 760)
        .task { await loadDestinations() }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Repair and Resubmit Message")
                    .font(.headline)
                Text("Message ID: \(message.id.isEmpty ? "—" : message.id)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Left Panel (Message Body / JSON Editor)

    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Toolbar row: label, editable badge, format button
            HStack(spacing: 8) {
                Label("Message Body", systemImage: "doc.text")
                    .font(.subheadline).fontWeight(.medium)
                    .foregroundStyle(.primary)

                HStack(spacing: 3) {
                    Image(systemName: "pencil")
                        .imageScale(.small)
                    Text("Editable")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
                .clipShape(Capsule())
                .accessibilityHidden(true)

                Spacer()

                Button {
                    formatJSON()
                } label: {
                    Label("Format JSON", systemImage: "wand.and.stars")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Pretty-print and format the JSON body")
            }

            JSONCodeEditor(text: $messageBody)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Right Panel (Properties)

    private var rightPanel: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    destinationSection
                    systemPropertiesSection
                    customPropertiesSection
                    statusSection
                    // Bottom padding keeps last item above the gradient fade
                    Color.clear.frame(height: 32)
                }
                .padding(16)
            }

            // Scroll-fade gradient at the bottom of the panel
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor).opacity(0),
                    Color(nsColor: .windowBackgroundColor)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 36)
            .allowsHitTesting(false)
        }
        .frame(minWidth: 340, maxWidth: 340, maxHeight: .infinity)
    }

    // MARK: - Destination Section

    private var destinationSection: some View {
        PropertiesSection(title: "Destination", systemImage: "arrow.right.circle") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Target Queue or Topic")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    TextField("Queue or topic name", text: $targetDestination)
                        .textFieldStyle(.roundedBorder)
                    Menu {
                        if isLoadingDestinations {
                            Text("Loading…").foregroundStyle(.secondary)
                        } else {
                            if !availableQueues.isEmpty {
                                Section("Queues") {
                                    ForEach(availableQueues, id: \.name) { q in
                                        Button(q.name) { targetDestination = q.name }
                                    }
                                }
                            }
                            if !availableTopics.isEmpty {
                                Section("Topics") {
                                    ForEach(availableTopics, id: \.name) { t in
                                        Button(t.name) { targetDestination = t.name }
                                    }
                                }
                            }
                            if availableQueues.isEmpty && availableTopics.isEmpty {
                                Text("No entities found").foregroundStyle(.secondary)
                            }
                        }
                    } label: {
                        if isLoadingDestinations {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "chevron.up.chevron.down")
                                .imageScale(.small)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 28, height: 22)
                    .disabled(isLoadingDestinations)
                    .help("Choose from available queues and topics")
                    .accessibilityLabel("Select destination")
                }
            }
        }
    }

    // MARK: - System Properties Section

    private var systemPropertiesSection: some View {
        PropertiesSection(title: "System Properties", systemImage: "gearshape") {
            VStack(spacing: 8) {
                PropertyField(label: "Subject", text: $subject)
                PropertyField(label: "Content Type", text: $contentType)
                PropertyField(label: "Reply To", text: $replyTo)
                PropertyField(label: "To", text: $toAddress)
                PropertyField(label: "Session ID", text: $sessionID)
                PropertyField(label: "Partition Key", text: $partitionKey)

                // Correlation ID with helper text
                VStack(alignment: .leading, spacing: 3) {
                    Text("Correlation ID")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Auto-generated if empty", text: $correlationID)
                        .textFieldStyle(.roundedBorder)
                    Text("Optional — leave blank to auto-generate")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Custom Properties Section

    private var customPropertiesSection: some View {
        PropertiesSection(title: "Custom Properties", systemImage: "tag") {
            VStack(spacing: 6) {
                if !properties.isEmpty {
                    HStack(spacing: 6) {
                        Text("Key")
                            .font(.caption2).fontWeight(.medium)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Value")
                            .font(.caption2).fontWeight(.medium)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Spacer().frame(width: 22)
                    }

                    ForEach(properties.indices, id: \.self) { i in
                        HStack(spacing: 6) {
                            TextField("Key", text: Binding(
                                get: { properties[i].key },
                                set: { properties[i].key = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)
                            .help(properties[i].key)

                            TextField("Value", text: Binding(
                                get: { properties[i].value },
                                set: { properties[i].value = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)
                            .help(properties[i].value)

                            let keyName = properties[i].key
                            Button {
                                properties.remove(at: i)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(Color(nsColor: .systemRed))
                            }
                            .buttonStyle(.borderless)
                            .frame(width: 22)
                            .help(keyName.isEmpty ? "Remove this property" : "Remove \"\(keyName)\"")
                            .accessibilityLabel(keyName.isEmpty ? "Remove property" : "Remove \(keyName)")
                        }
                    }
                }

                Button {
                    properties.append((key: "", value: ""))
                } label: {
                    Label("Add Property", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .padding(.top, properties.isEmpty ? 0 : 2)

                if properties.isEmpty {
                    Text("No custom properties")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                }
            }
        }
    }

    // MARK: - Status Section

    @ViewBuilder
    private var statusSection: some View {
        if let err = sendError {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        if didSend {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Message resubmitted successfully.")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack(spacing: 8) {
            Spacer()

            if isSending { ProgressView().controlSize(.small) }

            Button("Cancel") { dismiss() }
                .keyboardShortcut(.escape, modifiers: [])

            // Resubmit — primary action
            Button("Resubmit") { Task { await send() } }
                .buttonStyle(.borderedProminent)
                .help("Repair and resubmit this message to the target destination")
                .disabled(isSubmitDisabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var isSubmitDisabled: Bool {
        isSending
            || messageBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || targetDestination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Helpers

    private func formatJSON() {
        guard
            let data = messageBody.data(using: .utf8),
            let obj  = try? JSONSerialization.jsonObject(with: data),
            let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
            let str  = String(data: pretty, encoding: .utf8)
        else { return }
        messageBody = str
    }

    private func loadDestinations() async {
        isLoadingDestinations = true
        defer { isLoadingDestinations = false }
        do {
            async let queues = grpc.listQueues()
            async let topics = grpc.listTopics()
            availableQueues = try await queues
            availableTopics = try await topics
        } catch {
            // Silently fail — the text field remains fully editable.
        }
    }

    private func send() async {
        isSending = true
        sendError = nil
        didSend = false
        defer {
            isSending = false
        }
        do {
            let propsDict = Dictionary(
                uniqueKeysWithValues: properties
                    .filter { !$0.key.isEmpty }
                    .map { ($0.key, $0.value) }
            )
            _ = try await grpc.sendMessageExtended(
                queueOrTopic: targetDestination.trimmingCharacters(in: .whitespacesAndNewlines),
                body: messageBody,
                contentType: contentType,
                subject: subject,
                correlationID: correlationID,
                replyTo: replyTo,
                toAddress: toAddress,
                sessionID: sessionID,
                partitionKey: partitionKey,
                properties: propsDict
            )
            didSend = true
            let dest = targetDestination.trimmingCharacters(in: .whitespacesAndNewlines)
            if availableQueues.contains(where: { $0.name == dest }) {
                actionStore.requestRefresh(.queue(dest))
            }
        } catch {
            sendError = error.localizedDescription
        }
    }
}

// MARK: - JSON Code Editor (NSViewRepresentable)

/// An editable NSTextView-backed code editor with live JSON syntax highlighting.
struct JSONCodeEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator

        textView.isEditable = true
        textView.isRichText = true
        textView.allowsUndo = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 10, height: 10)

        // Disable smart substitutions that corrupt JSON
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        // Word-boundary wrapping only — no mid-word breaks
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        // Seed the initial content
        let attributed = JSONSyntaxHighlighter.highlight(text)
        textView.textStorage?.setAttributedString(attributed)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // Only re-set from outside (e.g. Format JSON) when the strings diverge.
        guard textView.string != text else { return }

        let selectedRanges = textView.selectedRanges
        // Bypass our delegate while we push the external change in.
        let savedDelegate = textView.textStorage?.delegate
        textView.textStorage?.delegate = nil
        textView.textStorage?.setAttributedString(JSONSyntaxHighlighter.highlight(text))
        textView.textStorage?.delegate = savedDelegate
        textView.selectedRanges = selectedRanges
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: JSONCodeEditor
        private var isHighlighting = false

        init(_ parent: JSONCodeEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }

        /// Re-highlight after every character edit without triggering a second edit cycle.
        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard !isHighlighting, editedMask.contains(.editedCharacters) else { return }
            isHighlighting = true
            let highlighted = JSONSyntaxHighlighter.highlight(textStorage.string)
            textStorage.setAttributedString(highlighted)
            isHighlighting = false
        }
    }
}

// MARK: - JSON Syntax Highlighter

enum JSONSyntaxHighlighter {
    private static let monoFont    = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let keyColor    = NSColor(red: 0.020, green: 0.314, blue: 0.682, alpha: 1) // #0550AE
    private static let stringColor = NSColor(red: 0.639, green: 0.082, blue: 0.082, alpha: 1) // #A31515
    private static let numberColor = NSColor(red: 0.035, green: 0.525, blue: 0.345, alpha: 1) // #098658
    private static let punctColor  = NSColor(red: 0.400, green: 0.400, blue: 0.400, alpha: 1) // #666666

    static func highlight(_ source: String) -> NSAttributedString {
        let ms   = NSMutableAttributedString(string: source)
        let full = NSRange(location: 0, length: ms.length)

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping

        ms.addAttributes([
            .font: monoFont,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: para
        ], range: full)

        // Apply layers in order; keys are re-applied last to win over strings.
        color(ms, pattern: #"[{}\[\],:]"#,                                                  with: punctColor)
        color(ms, pattern: #""(?:[^"\\]|\\.)*"(?!\s*:)"#,                                   with: stringColor)
        color(ms, pattern: #""(?:[^"\\]|\\.)*"(?=\s*:)"#,                                   with: keyColor)
        color(ms, pattern: #"\b(?:true|false|null)\b"#,                                     with: numberColor)
        color(ms, pattern: #"(?<!["\w])-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?(?!["\w\.])"#,      with: numberColor)

        return ms
    }

    private static func color(
        _ ms: NSMutableAttributedString,
        pattern: String,
        with color: NSColor
    ) {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(location: 0, length: ms.length)
        for m in re.matches(in: ms.string, range: range) {
            ms.addAttribute(.foregroundColor, value: color, range: m.range)
        }
    }
}

// MARK: - Helpers

@available(macOS 15.0, *)
private struct PropertiesSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.subheadline).fontWeight(.medium)
                .foregroundStyle(.primary)
            content()
        }
    }
}

@available(macOS 15.0, *)
private struct PropertyField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(label, text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}
