import SwiftUI

@available(macOS 15.0, *)
struct RepairResubmitSheet: View {
    @Environment(GRPCManager.self) var grpc
    @Environment(\.dismiss) var dismiss

    let message: MessageItem
    let queueOrTopic: String

    @State private var messageBody: String
    @State private var contentType: String
    @State private var subject: String
    @State private var correlationID: String
    @State private var properties: [(key: String, value: String)]

    @State private var isSending = false
    @State private var sendError: String?
    @State private var didSend = false

    init(message: MessageItem, queueOrTopic: String) {
        self.message = message
        self.queueOrTopic = queueOrTopic
        _messageBody = State(initialValue: message.body)
        _contentType = State(initialValue: message.contentType)
        _subject = State(initialValue: message.subject)
        _correlationID = State(initialValue: message.correlationId)
        _properties = State(initialValue: message.properties.sorted(by: { $0.key < $1.key }).map { (key: $0.key, value: $0.value) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Repair or Resubmit Message")
                        .font(.headline)
                    Text("Message ID: \(message.id.isEmpty ? "—" : message.id)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox("System Properties") {
                        Form {
                            LabeledContent("Subject") {
                                TextField("", text: $subject)
                                    .textFieldStyle(.roundedBorder)
                            }
                            LabeledContent("Content Type") {
                                TextField("", text: $contentType)
                                    .textFieldStyle(.roundedBorder)
                            }
                            LabeledContent("Correlation ID") {
                                TextField("", text: $correlationID)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                        .formStyle(.grouped)
                    }

                    GroupBox("Message Body") {
                        TextEditor(text: $messageBody)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 180)
                            .scrollContentBackground(.hidden)
                            .background(Color(nsColor: .textBackgroundColor))
                    }

                    if !properties.isEmpty {
                        GroupBox("Custom Properties") {
                            VStack(spacing: 6) {
                                ForEach(properties.indices, id: \.self) { i in
                                    HStack(spacing: 8) {
                                        TextField("Key", text: Binding(
                                            get: { properties[i].key },
                                            set: { properties[i].key = $0 }
                                        ))
                                        .textFieldStyle(.roundedBorder)
                                        .frame(maxWidth: 160)
                                        TextField("Value", text: Binding(
                                            get: { properties[i].value },
                                            set: { properties[i].value = $0 }
                                        ))
                                        .textFieldStyle(.roundedBorder)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    if let err = sendError {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                    }

                    if didSend {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("Message resubmitted successfully.").font(.caption).foregroundStyle(.green)
                        }
                    }
                }
                .padding()
            }

            Divider()

            HStack {
                Spacer()
                if isSending { ProgressView().controlSize(.small) }
                Button("Resubmit") { Task { await send() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSending || messageBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .frame(width: 560, height: 580)
    }

    private func send() async {
        isSending = true
        sendError = nil
        didSend = false
        defer { isSending = false }
        do {
            let propsDict = Dictionary(uniqueKeysWithValues: properties.filter { !$0.key.isEmpty }.map { ($0.key, $0.value) })
            _ = try await grpc.sendMessageExtended(
                queueOrTopic: queueOrTopic,
                body: messageBody,
                contentType: contentType,
                subject: subject,
                correlationID: correlationID,
                properties: propsDict
            )
            didSend = true
        } catch {
            sendError = error.localizedDescription
        }
    }
}
