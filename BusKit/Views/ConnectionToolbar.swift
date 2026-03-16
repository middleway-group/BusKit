import SwiftUI

@available(macOS 15.0, *)
struct ConnectionToolbar: View {
    @Environment(GRPCManager.self) var grpc
    @Binding var connectionString: String
    @State private var isConnecting = false
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 8, height: 8)
                Text(statusLabel)
                    .font(.subheadline)
            }
        }
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            ConnectionPopover(connectionString: $connectionString, isConnecting: $isConnecting)
                .environment(grpc)
        }
    }

    private var statusLabel: String {
        switch grpc.connectionState {
        case .connected:    return "Connected"
        case .connecting:   return grpc.isSidecarReady ? "Connecting…" : "Starting…"
        case .disconnected: return "Connect"
        case .error:        return "Connection Error"
        }
    }

    private var stateColor: Color {
        switch grpc.connectionState {
        case .connected:    return .green
        case .connecting:   return .orange
        case .error:        return .red
        case .disconnected: return .gray
        }
    }
}

@available(macOS 15.0, *)
private struct ConnectionPopover: View {
    @Environment(GRPCManager.self) var grpc
    @Binding var connectionString: String
    @Binding var isConnecting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Azure Service Bus Connection")
                .font(.headline)

            TextEditor(text: $connectionString)
                .font(.system(.body, design: .monospaced))
                .frame(width: 440, height: 100)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .disabled(grpc.connectionState == .connected || isConnecting)

            if case .error(let message) = grpc.connectionState {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .padding(.top, 1)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                if isConnecting || (grpc.connectionState == .connecting && !grpc.isSidecarReady) {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(grpc.connectionState == .connected ? "Disconnect" : "Connect") {
                    Task { await toggleConnection() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!grpc.isSidecarReady || connectionString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isConnecting)
            }
        }
        .padding()
        .frame(width: 480)
    }

    private func toggleConnection() async {
        isConnecting = true
        defer { isConnecting = false }
        do {
            if grpc.connectionState == .connected {
                _ = try await grpc.disconnect()
            } else {
                _ = try await grpc.connect(connectionString: connectionString.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        } catch {
            // connectionState is updated by GRPCManager on error
        }
    }
}
