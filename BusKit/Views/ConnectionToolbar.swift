import SwiftUI

@available(macOS 15.0, *)
struct ConnectionToolbar: View {
    @Environment(GRPCManager.self) var grpc
    @Binding var connectionString: String
    @State private var isConnecting = false
    @Binding var isPopoverPresented: Bool

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 8, height: 8)
                Text(statusLabel)
                    .font(.subheadline)
            }
        }
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            ConnectionPopover(connectionString: $connectionString, isConnecting: $isConnecting)
                .environment(grpc)
        }
        // task(id:) fires on first appearance AND on every azureLoginPhase change.
        // Unlike onChange, it never misses the current value when the view first
        // appears or is recreated by NSToolbar.
        .task(id: grpc.azureLoginPhase) {
            switch grpc.azureLoginPhase {
            case .signingIn:
                // Browser is opening — dismiss the popover.
                isPopoverPresented = false
            case .ready where grpc.connectionState != .connected:
                // Auth done — show the namespace picker.
                isPopoverPresented = true
            case .connecting:
                // User clicked Connect — keep popover open for progress feedback.
                isPopoverPresented = true
            default:
                // .idle or .ready-while-connected: no automatic action.
                break
            }
        }
        // Separate handler for connection-state changes that happen while
        // azureLoginPhase stays constant (e.g., connectionState .connected
        // is set inside connectWithAzureAD before the phase defer fires).
        .onChange(of: grpc.connectionState) { _, newState in
            switch newState {
            case .connected:
                // Close before the RBAC check runs so no sheet/popover conflict.
                isPopoverPresented = false
            default:
                // Reconnection opportunity: if still signed in and no longer
                // connected, reopen so the user can switch or retry.
                if grpc.azureLoginPhase == .ready {
                    isPopoverPresented = true
                }
            }
        }
    }

    private var statusLabel: String {
        switch grpc.connectionState {
        case .connected:
            switch grpc.rbacAccessLevel {
            case .checking:          return "Checking permissions…"
            case .dataOnly:          return "Connected (Limited)"
            case .managementOnly:    return "Connected (Limited)"
            case .denied:            return "Connected (No Access)"
            case .checkFailed:       return "Connected (Unverified)"
            default:                 return "Connected"
            }
        case .connecting:   return grpc.isSidecarReady ? "Connecting…" : "Starting…"
        case .disconnected: return grpc.azureLoginPhase == .signingIn ? "Signing in…" : "Connect"
        case .error:        return "Connection Error"
        }
    }

    private var stateColor: Color {
        switch grpc.connectionState {
        case .connected:
            switch grpc.rbacAccessLevel {
            case .checking:       return .orange
            case .dataOnly:       return .yellow
            case .managementOnly: return .yellow
            case .denied:         return .red
            case .checkFailed:    return .orange
            default:              return .green
            }
        case .connecting:   return .orange
        case .error:        return .red
        case .disconnected: return .gray
        }
    }
}

// MARK: - Connection mode

private enum ConnectionMode: String, CaseIterable {
    case connectionString = "Connection String"
    case azureAD          = "Azure Login"
}

// MARK: - Main popover

@available(macOS 15.0, *)
private struct ConnectionPopover: View {
    @Environment(GRPCManager.self) var grpc
    @Binding var connectionString: String
    @Binding var isConnecting: Bool

    @State private var mode: ConnectionMode = .connectionString

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Azure Service Bus Connection")
                .font(.headline)

            Picker("", selection: $mode) {
                ForEach(ConnectionMode.allCases, id: \.self) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .disabled(grpc.connectionState == .connected || isConnecting
                      || grpc.azureLoginPhase == .signingIn
                      || grpc.azureLoginPhase == .connecting)

            switch mode {
            case .connectionString:
                ConnectionStringPanel(
                    connectionString: $connectionString,
                    isConnecting: $isConnecting
                )
                .environment(grpc)
            case .azureAD:
                AzureADPanel(isConnecting: $isConnecting)
                    .environment(grpc)
            }
        }
        .padding()
        .frame(width: 480)
        .onAppear {
            // Restore the Azure tab whenever an Azure login is in progress or
            // the user is already signed in.
            if grpc.azureLoginPhase != .idle {
                mode = .azureAD
            }
        }
    }
}

// MARK: - Connection string panel (existing behaviour)

@available(macOS 15.0, *)
private struct ConnectionStringPanel: View {
    @Environment(GRPCManager.self) var grpc
    @Binding var connectionString: String
    @Binding var isConnecting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextEditor(text: $connectionString)
                .font(.system(.body, design: .monospaced))
                .frame(width: 440, height: 100)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .disabled(grpc.connectionState == .connected || isConnecting)

            if case .error(let message) = grpc.connectionState {
                ErrorBanner(message: message)
            }

            HStack {
                Spacer()
                if isConnecting || (grpc.connectionState == .connecting && !grpc.isSidecarReady) {
                    ProgressView().controlSize(.small)
                }
                Button(grpc.connectionState == .connected ? "Disconnect" : "Connect") {
                    Task { await toggleConnection() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!grpc.isSidecarReady
                          || connectionString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || isConnecting)
            }
        }
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
        } catch {}
    }
}

// MARK: - Azure AD / RBAC panel

@available(macOS 15.0, *)
private struct AzureADPanel: View {
    @Environment(GRPCManager.self) var grpc
    @Binding var isConnecting: Bool

    var body: some View {
        switch grpc.azureLoginPhase {
        case .idle:
            AzureSignInPrompt(isConnecting: $isConnecting)
                .environment(grpc)
        case .signingIn:
            AzureSigningInView()
        case .ready, .connecting:
            AzureNamespaceForm(isConnecting: $isConnecting)
                .environment(grpc)
        }
    }
}

// ── Not yet signed in ──────────────────────────────────

@available(macOS 15.0, *)
private struct AzureSignInPrompt: View {
    @Environment(GRPCManager.self) var grpc
    @Binding var isConnecting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in with your Azure account to browse and connect to Service Bus namespaces.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let err = grpc.azureLoginError {
                ErrorBanner(message: err)
            }

            HStack {
                Spacer()
                Button("Sign in with Azure…") {
                    Task { await signIn() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!grpc.isSidecarReady || isConnecting)
            }
        }
    }

    private func signIn() async {
        grpc.azureLoginError = nil
        grpc.azureLoginPhase = .signingIn
        isConnecting = true
        defer { isConnecting = false }
        do {
            let subs = try await grpc.listAzureSubscriptions()
            grpc.azureSubscriptions = subs
            grpc.selectedAzureSubscriptionId = subs.first?.subscriptionID ?? ""
            grpc.azureLoginPhase = .ready
        } catch {
            grpc.azureLoginError = error.localizedDescription
            grpc.azureLoginPhase = .idle
        }
    }
}

// ── Browser open, waiting for auth ────────────────────

private struct AzureSigningInView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("A browser window has opened — sign in with your Azure credentials.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("A second window may open on first use for Azure Service Bus access.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// ── Signed-in form: subscription + namespace pickers ──

@available(macOS 15.0, *)
private struct AzureNamespaceForm: View {
    @Environment(GRPCManager.self) var grpc
    @Binding var isConnecting: Bool

    var body: some View {
        @Bindable var grpcBindable = grpc

        VStack(alignment: .leading, spacing: 10) {
            // ── Connected status badge ──
            if grpc.connectionState == .connected, let ns = grpc.namespaceName {
                HStack(spacing: 6) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text("Connected to \(ns)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            // ── Subscription picker ──
            LabeledContent("Subscription") {
                Picker("", selection: $grpcBindable.selectedAzureSubscriptionId) {
                    ForEach(grpc.azureSubscriptions, id: \.subscriptionID) { sub in
                        Text(sub.displayName).tag(sub.subscriptionID)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .disabled(isConnecting || grpc.azureLoginPhase == .connecting)
            }

            // ── Namespace picker ──
            LabeledContent("Namespace") {
                if grpc.isLoadingAzureNamespaces {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Loading…").font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if grpc.azureNamespaces.isEmpty {
                    Text("No Service Bus namespaces found")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Picker("", selection: $grpcBindable.selectedAzureNamespaceFQNS) {
                        ForEach(grpc.azureNamespaces, id: \.fullyQualifiedNamespace) { ns in
                            Text(ns.name).tag(ns.fullyQualifiedNamespace)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .disabled(isConnecting || grpc.azureLoginPhase == .connecting)
                }
            }

            if let err = grpc.azureLoginError {
                ErrorBanner(message: err)
            }
            if case .error(let message) = grpc.connectionState {
                ErrorBanner(message: message)
            }

            // ── Action buttons ──
            HStack {
                Button("Sign out") {
                    grpc.resetAzureLoginState()
                }
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
                .disabled(isConnecting || grpc.azureLoginPhase == .connecting)

                if grpc.connectionState == .connected {
                    Button("Refresh Permissions") {
                        grpc.refreshRbacPermissions()
                    }
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                    .disabled(grpc.rbacAccessLevel == .checking)
                }

                Spacer()

                if isConnecting || grpc.azureLoginPhase == .connecting {
                    ProgressView().controlSize(.small)
                }

                if grpc.connectionState == .connected {
                    Button("Disconnect") {
                        Task { await disconnect() }
                    }
                    .disabled(isConnecting)

                    Button("Switch") {
                        Task { await connect() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isConnecting
                              || grpc.selectedAzureNamespaceFQNS.isEmpty
                              || grpc.azureLoginPhase == .connecting)
                } else {
                    Button("Connect") {
                        Task { await connect() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isConnecting
                              || grpc.selectedAzureNamespaceFQNS.isEmpty
                              || grpc.isLoadingAzureNamespaces
                              || grpc.azureLoginPhase == .connecting)
                }
            }
        }
        .onAppear { loadNamespacesIfNeeded() }
        .onChange(of: grpc.selectedAzureSubscriptionId) { _, _ in
            Task { await loadNamespaces() }
        }
    }

    // MARK: - Actions

    private func loadNamespacesIfNeeded() {
        guard grpc.azureNamespaces.isEmpty,
              !grpc.selectedAzureSubscriptionId.isEmpty,
              !grpc.isLoadingAzureNamespaces else { return }
        Task { await loadNamespaces() }
    }

    private func loadNamespaces() async {
        guard !grpc.selectedAzureSubscriptionId.isEmpty else { return }
        grpc.azureLoginError = nil
        grpc.isLoadingAzureNamespaces = true
        grpc.azureNamespaces = []
        grpc.selectedAzureNamespaceFQNS = ""
        defer { grpc.isLoadingAzureNamespaces = false }
        do {
            let nsList = try await grpc.listServiceBusNamespaces(subscriptionId: grpc.selectedAzureSubscriptionId)
            grpc.azureNamespaces = nsList
            grpc.selectedAzureNamespaceFQNS = nsList.first?.fullyQualifiedNamespace ?? ""
        } catch {
            grpc.azureLoginError = error.localizedDescription
        }
    }

    private func connect() async {
        grpc.azureLoginError = nil
        grpc.azureLoginPhase = .connecting
        isConnecting = true
        defer {
            isConnecting = false
            grpc.azureLoginPhase = .ready
        }
        do {
            _ = try await grpc.connectWithAzureAD(fullyQualifiedNamespace: grpc.selectedAzureNamespaceFQNS)
            // Run RBAC check after a successful Azure AD connection.
            if grpc.connectionState == .connected {
                await grpc.checkRbacPermissions()
            }
        } catch {
            grpc.azureLoginError = error.localizedDescription
        }
    }

    private func disconnect() async {
        do { _ = try await grpc.disconnect() } catch {}
        // Stay in .ready phase so the pickers remain accessible for switching.
        grpc.azureLoginPhase = .ready
    }
}

// MARK: - Shared error banner

private struct ErrorBanner: View {
    let message: String
    var body: some View {
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
}
