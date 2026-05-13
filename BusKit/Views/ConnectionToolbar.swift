import SwiftUI

@available(macOS 15.0, *)
struct ConnectionToolbar: View {
    @Environment(GRPCManager.self) var grpc
    @Binding var connectionString: String
    @State private var isConnecting = false
    @State private var manualShowPopover = false

    /// The popover is shown whenever the user manually opens it OR whenever
    /// Azure auth has completed and a namespace hasn't been chosen yet.
    /// Because azureLoginPhase and connectionState are both read here, SwiftUI
    /// re-evaluates this binding on every state change — no onChange/notification
    /// needed. Dismissing the popover writes false to manualShowPopover; the
    /// auto-open condition continues to hold until the user connects or signs out.
    private var popoverBinding: Binding<Bool> {
        Binding(
            get: {
                manualShowPopover
                || (grpc.azureLoginPhase == .ready && grpc.connectionState != .connected)
                || (grpc.azureLoginPhase == .selectingTenant)
                || (grpc.azureLoginPhase == .connecting)
            },
            set: { manualShowPopover = $0 }
        )
    }

    var body: some View {
        Button {
            manualShowPopover.toggle()
        } label: {
            Label(toolbarLabel, systemImage: toolbarSystemImage)
                .font(.subheadline)
        }
        .help("Azure Service Bus connection settings")
        .popover(isPresented: popoverBinding, arrowEdge: .bottom) {
            ConnectionPopover(connectionString: $connectionString, isConnecting: $isConnecting)
                .environment(grpc)
        }
    }

    private var toolbarLabel: String {
        switch grpc.connectionState {
        case .connected:    return grpc.namespaceName ?? "Connected"
        case .connecting:   return grpc.isSidecarReady ? "Connecting…" : "Starting…"
        case .disconnected: return grpc.azureLoginPhase == .signingIn ? "Signing in…" : "Connect"
        case .error:        return "Error"
        }
    }

    private var toolbarSystemImage: String {
        switch grpc.connectionState {
        case .connected:    return "server.rack"
        case .connecting:   return "arrow.triangle.2.circlepath"
        case .disconnected: return "server.rack"
        case .error:        return "exclamationmark.triangle"
        }
    }
}

// MARK: - Connection mode

private enum ConnectionMode: String, CaseIterable {
    case azureAD          = "Azure Login"
    case connectionString = "Connection String"
}

// MARK: - Main popover

@available(macOS 15.0, *)
private struct ConnectionPopover: View {
    @Environment(GRPCManager.self) var grpc
    @Binding var connectionString: String
    @Binding var isConnecting: Bool

    @State private var mode: ConnectionMode = .azureAD

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
        case .selectingTenant:
            AzureTenantPickerView(isConnecting: $isConnecting)
                .environment(grpc)
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
        grpc.azureSubscriptions = []
        grpc.azureTenants = []
        grpc.azureNamespaces = []
        grpc.selectedAzureSubscriptionId = ""
        grpc.selectedAzureTenantId = ""
        grpc.selectedAzureNamespaceFQNS = ""
        isConnecting = true
        defer { isConnecting = false }
        do {
            let reply = try await grpc.listAzureSubscriptions()
            let tenants = Array(reply.tenants).sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
            grpc.azureTenants = tenants

            if tenants.count == 1 {
                let tenant = tenants[0]
                grpc.selectedAzureTenantId = tenant.tenantID
                let subs = try await grpc.selectAzureTenant(tenantId: tenant.tenantID)
                grpc.azureSubscriptions = subs
                grpc.selectedAzureSubscriptionId = subs.first?.subscriptionID ?? ""
                grpc.azureLoginPhase = .ready
            } else if tenants.isEmpty {
                let subs = Array(reply.subscriptions).sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
                grpc.azureSubscriptions = subs
                grpc.selectedAzureSubscriptionId = subs.first?.subscriptionID ?? ""
                grpc.azureLoginPhase = .ready
            } else {
                grpc.azureLoginPhase = .selectingTenant
            }
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

@available(macOS 15.0, *)
private struct AzureTenantPickerView: View {
    @Environment(GRPCManager.self) var grpc
    @Binding var isConnecting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your account has access to multiple directories. Choose the directory you want to use.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let err = grpc.azureLoginError {
                ErrorBanner(message: err)
            }

            VStack(spacing: 0) {
                ForEach(grpc.azureTenants, id: \.tenantID) { tenant in
                    Button {
                        Task { await selectTenant(tenant.tenantID) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tenant.displayName.isEmpty ? tenant.tenantID : tenant.displayName)
                                    .font(.body)
                                Text(tenant.tenantID)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            if isConnecting && grpc.selectedAzureTenantId == tenant.tenantID {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isConnecting)

                    if tenant.tenantID != grpc.azureTenants.last?.tenantID {
                        Divider()
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            HStack {
                Button("Sign out") {
                    grpc.resetAzureLoginState()
                }
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
                .disabled(isConnecting)
                Spacer()
            }
        }
    }

    private func selectTenant(_ tenantId: String) async {
        grpc.azureLoginError = nil
        grpc.selectedAzureTenantId = tenantId
        grpc.azureSubscriptions = []
        grpc.azureNamespaces = []
        grpc.selectedAzureSubscriptionId = ""
        grpc.selectedAzureNamespaceFQNS = ""
        isConnecting = true
        defer { isConnecting = false }
        do {
            let subs = try await grpc.selectAzureTenant(tenantId: tenantId)
            grpc.azureSubscriptions = subs
            grpc.selectedAzureSubscriptionId = subs.first?.subscriptionID ?? ""
            grpc.azureLoginPhase = .ready
        } catch {
            grpc.azureLoginError = error.localizedDescription
            grpc.selectedAzureTenantId = ""
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

            if grpc.azureTenants.count > 1 {
                let activeTenant = grpc.azureTenants.first { $0.tenantID == grpc.selectedAzureTenantId }
                LabeledContent("Directory") {
                    HStack(spacing: 6) {
                        Text(activeTenant?.displayName ?? grpc.selectedAzureTenantId)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Switch…") {
                            grpc.azureLoginPhase = .selectingTenant
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .font(.callout)
                        .disabled(isConnecting || grpc.azureLoginPhase == .connecting)
                    }
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
