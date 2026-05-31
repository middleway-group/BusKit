// BusKit/GRPCManager.swift

@preconcurrency import Dispatch
import Foundation
import Network
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf

@available(macOS 15.0, *)
@MainActor
@Observable
final class GRPCManager {

    var connectionState: ConnectionState = .disconnected
    var isSidecarReady: Bool = false
    var errorMessage: String?
    var namespaceName: String?

    // MARK: - Azure AD Login State

    enum AzureLoginPhase: Equatable {
        /// Not signed in to Azure.
        case idle
        /// Browser is open waiting for the user to authenticate.
        case signingIn
        /// Multiple directories were found; waiting for the user to choose one.
        case selectingTenant
        /// Signed in — subscription + namespace pickers are available.
        case ready
        /// Connecting to the selected namespace.
        case connecting
    }

    var azureLoginPhase: AzureLoginPhase = .idle
    var azureLoginError: String?
    var azureSubscriptions: [Buskit_AzureSubscriptionInfo] = []
    var azureTenants: [Buskit_AzureTenantInfo] = []
    var azureNamespaces: [Buskit_ServiceBusNamespaceInfo] = []
    var selectedAzureSubscriptionId: String = ""
    var selectedAzureTenantId: String = ""
    var selectedAzureNamespaceFQNS: String = ""
    var isLoadingAzureNamespaces: Bool = false

    // MARK: - RBAC State

    var rbacAccessLevel: RbacAccessLevel = .notApplicable
    /// Granular 5-tier classification; populated alongside rbacAccessLevel.
    var accessTier: AccessTier = .noAccess
    /// Per-capability boolean map derived from the server-side tier evaluation.
    var capabilityMap: CapabilityMap = .none
    /// Upgrade recommendation for the current tier (nil when fully accessible).
    var upgradeRecommendation: UpgradeRecommendation? = nil
    /// Whether the current tier is a partial/non-standard access combination.
    var isPartialAccess: Bool = false
    /// When the RBAC evaluation was last performed.
    var rbacEvaluatedAt: Date? = nil
    /// When the server-side cache entry expires.
    var rbacExpiresAt: Date? = nil

    /// Namespace FQNS for which the current rbacAccessLevel was computed (session cache key).
    private var rbacCheckedNamespace: String?

    private var grpcClient: GRPCClient<HTTP2ClientTransport.Posix>?
    private var buskit: Buskit_BusKitService.Client<HTTP2ClientTransport.Posix>?
    private var runTask: Task<Void, Never>?
    private var sidecarProcess: Process?

    init() {}

    // MARK: - Lifecycle

    func startSidecar(host: String = "127.0.0.1", port: Int = 50051) {
        launchSidecarProcess()
        connectionState = .connecting

        Task { @MainActor [weak self] in
            guard let self else { return }
            let ready = await self.pollPort(host: host, port: port, timeout: .seconds(30))
            guard ready else {
                let logPath = FileManager.default.temporaryDirectory
                    .appendingPathComponent("BusKit.Sidecar.log").path
                if let p = self.sidecarProcess, !p.isRunning {
                    self.connectionState = .error("Sidecar exited (status \(p.terminationStatus)). Log: \(logPath)")
                } else {
                    self.connectionState = .error("Sidecar didn't open port in 30s. Log: \(logPath)")
                }
                return
            }
            self.setupGRPCClient(host: host, port: port)
        }
    }

    /// Kill any process (including orphans from previous runs) listening on the given port.
    private func killProcessesOnPort(_ port: Int) {
        // Kill our tracked sidecar first
        if let existing = sidecarProcess, existing.isRunning {
            existing.terminate()
            sidecarProcess = nil
        }

        // Kill any orphaned process still listening on the port
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-ti", "TCP:\(port)"]
        lsof.standardError = Pipe()
        let outPipe = Pipe()
        lsof.standardOutput = outPipe
        try? lsof.run()
        lsof.waitUntilExit()

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8) {
            let pids = output
                .split(separator: "\n")
                .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            for pid in pids {
                NSLog("[BusKit] Killing orphaned process PID %d on port %d", pid, port)
                kill(pid, SIGTERM)
            }
            if !pids.isEmpty {
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }

    private func launchSidecarProcess() {
        killProcessesOnPort(50051)

        guard let executableURL = Bundle.main.resourceURL?
            .appendingPathComponent("SidecarBin/BusKit.Sidecar") else {
            connectionState = .error("Sidecar executable not found in bundle")
            return
        }

        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            connectionState = .error("Sidecar binary missing at: \(executableURL.path)")
            return
        }

        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BusKit.Sidecar.log")

        // Truncate log file for this run
        try? Data().write(to: logURL)

        let process = Process()
        process.executableURL = executableURL
        process.currentDirectoryURL = executableURL.deletingLastPathComponent()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // Stream output to a temp log file and to NSLog so it appears in Console.app
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            NSLog("[Sidecar] %@", text.trimmingCharacters(in: .newlines))
            try? data.append(fileURL: logURL)
        }

        do {
            try process.run()
            sidecarProcess = process
            NSLog("[BusKit] Sidecar launched (PID %d), log: %@", process.processIdentifier, logURL.path)
        } catch {
            connectionState = .error("Failed to launch sidecar: \(error.localizedDescription)")
        }
    }

    private func setupGRPCClient(host: String, port: Int) {
        do {
            let transport = try HTTP2ClientTransport.Posix(
                target: .ipv4(address: host, port: port),
                transportSecurity: .plaintext
            )
            let client = GRPCClient(transport: transport)
            grpcClient = client
            buskit = Buskit_BusKitService.Client(wrapping: client)

            runTask = Task.detached { [weak self] in
                do {
                    try await client.runConnections()
                } catch {
                    await MainActor.run {
                        self?.connectionState = .error(error.localizedDescription)
                    }
                }
            }

            isSidecarReady = true
            connectionState = .disconnected
        } catch {
            connectionState = .error(error.localizedDescription)
        }
    }

    // Polls TCP until the port is open, the process dies, or the timeout expires.
    private func pollPort(host: String, port: Int, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            // Bail early if the sidecar process has already exited.
            if let p = sidecarProcess, !p.isRunning {
                NSLog("[BusKit] Sidecar exited early (status %d)", p.terminationStatus)
                return false
            }
            if await Self.isPortOpen(host: host, port: port) { return true }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return false
    }

    private static func isPortOpen(host: String, port: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(integerLiteral: UInt16(port))
            )
            let conn = NWConnection(to: endpoint, using: .tcp)
            let queue = DispatchQueue(label: "portProbe")
            var resumed = false

            // Cancel after 300ms so we don't hang in .waiting when port is refused.
            let timer = DispatchWorkItem {
                guard !resumed else { return }
                resumed = true
                conn.cancel()
                continuation.resume(returning: false)
            }
            queue.asyncAfter(deadline: .now() + 0.3, execute: timer)

            conn.stateUpdateHandler = { state in
                queue.async {
                    guard !resumed else { return }
                    switch state {
                    case .ready:
                        resumed = true
                        timer.cancel()
                        conn.cancel()
                        continuation.resume(returning: true)
                    case .failed:
                        resumed = true
                        timer.cancel()
                        conn.cancel()
                        continuation.resume(returning: false)
                    default:
                        break
                    }
                }
            }
            conn.start(queue: queue)
        }
    }

    func shutdown() {
        isSidecarReady = false
        killProcessesOnPort(50051)
        runTask?.cancel()
        runTask = nil
        grpcClient = nil
        buskit = nil
        connectionState = .disconnected
    }

    // MARK: - Connect (connection string)

    func connect(connectionString: String) async throws -> Buskit_ConnectReply {
        guard let buskit else { throw GRPCManagerError.notConnected }
        var req = Buskit_ConnectRequest()
        req.connectionString = connectionString
        connectionState = .connecting
        do {
            let reply = try await buskit.connect(req)
            if reply.success {
                connectionState = .connected
                namespaceName = Self.extractNamespace(from: connectionString)
            } else {
                connectionState = .error(reply.error)
            }
            return reply
        } catch {
            connectionState = .error(error.localizedDescription)
            throw error
        }
    }

    // MARK: - Connect (Azure AD / RBAC)

    func listAzureSubscriptions() async throws -> Buskit_ListAzureSubscriptionsReply {
        guard let buskit else { throw GRPCManagerError.notConnected }
        let req = Buskit_ListAzureSubscriptionsRequest()
        let reply: Buskit_ListAzureSubscriptionsReply = try await buskit.listAzureSubscriptions(req)
        if !reply.error.isEmpty { throw GRPCManagerError.azureError(reply.error) }
        return reply
    }

    func selectAzureTenant(tenantId: String) async throws -> [Buskit_AzureSubscriptionInfo] {
        guard let buskit else { throw GRPCManagerError.notConnected }
        var req = Buskit_SelectAzureTenantRequest()
        req.tenantID = tenantId
        let reply: Buskit_SelectAzureTenantReply = try await buskit.selectAzureTenant(req)
        if !reply.error.isEmpty { throw GRPCManagerError.azureError(reply.error) }
        return Array(reply.subscriptions).sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
    }

    func listServiceBusNamespaces(subscriptionId: String) async throws -> [Buskit_ServiceBusNamespaceInfo] {
        guard let buskit else { throw GRPCManagerError.notConnected }
        var req = Buskit_ListServiceBusNamespacesRequest()
        req.subscriptionID = subscriptionId
        let reply: Buskit_ListServiceBusNamespacesReply = try await buskit.listServiceBusNamespaces(req)
        if !reply.error.isEmpty { throw GRPCManagerError.azureError(reply.error) }
        return Array(reply.namespaces).sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    func connectWithAzureAD(fullyQualifiedNamespace: String) async throws -> Buskit_ConnectReply {
        guard let buskit else { throw GRPCManagerError.notConnected }
        var req = Buskit_ConnectWithAzureADRequest()
        req.fullyQualifiedNamespace = fullyQualifiedNamespace
        connectionState = .connecting
        do {
            let reply = try await buskit.connectWithAzureAD(req)
            if reply.success {
                connectionState = .connected
                namespaceName = fullyQualifiedNamespace
                    .components(separatedBy: ".").first
            } else {
                connectionState = .error(reply.error)
            }
            return reply
        } catch {
            connectionState = .error(error.localizedDescription)
            throw error
        }
    }

    // MARK: - RBAC Permission Check

    /// Looks up the resource group for the currently selected namespace FQNS.
    var selectedNamespaceInfo: Buskit_ServiceBusNamespaceInfo? {
        azureNamespaces.first { $0.fullyQualifiedNamespace == selectedAzureNamespaceFQNS }
    }

    /// Evaluates effective RBAC permissions for the selected namespace and updates all RBAC state.
    /// Results are cached server-side; pass `force: true` to bypass the local namespace cache.
    func checkRbacPermissions(force: Bool = false) async {
        guard let nsInfo = selectedNamespaceInfo,
              !selectedAzureSubscriptionId.isEmpty else {
            rbacAccessLevel = .checkFailed("Namespace or subscription information is unavailable.")
            return
        }

        // Return cached result unless a refresh is requested.
        if !force, rbacCheckedNamespace == selectedAzureNamespaceFQNS,
           rbacAccessLevel != .checking {
            return
        }

        rbacAccessLevel = .checking
        rbacCheckedNamespace = selectedAzureNamespaceFQNS

        guard let buskit else {
            rbacAccessLevel = .checkFailed("gRPC client is not ready.")
            return
        }

        do {
            var req = Buskit_CheckRbacPermissionsRequest()
            req.subscriptionID = selectedAzureSubscriptionId
            req.resourceGroup  = nsInfo.resourceGroup
            req.namespaceName  = nsInfo.name
            let reply: Buskit_CheckRbacPermissionsReply = try await buskit.checkRbacPermissions(req)

            if reply.checkFailed {
                let msg = reply.error.isEmpty ? "Permission check failed." : reply.error
                rbacAccessLevel = .checkFailed(msg)
                accessTier = .noAccess
                capabilityMap = .none
                upgradeRecommendation = nil
                isPartialAccess = false
            } else {
                // ── Tier-based state (new) ────────────────────────────
                accessTier            = AccessTier(from: reply.accessTier)
                capabilityMap         = CapabilityMap(from: reply)
                upgradeRecommendation = UpgradeRecommendation(from: reply)
                isPartialAccess       = reply.isPartialAccess

                if reply.evaluatedAtUnixMs > 0 {
                    rbacEvaluatedAt = Date(timeIntervalSince1970: Double(reply.evaluatedAtUnixMs) / 1000)
                }
                if reply.expiresAtUnixMs > 0 {
                    rbacExpiresAt = Date(timeIntervalSince1970: Double(reply.expiresAtUnixMs) / 1000)
                }

                // ── Legacy access level (backward compat with existing dialog) ──
                switch (reply.hasDataOwnerRole_p, reply.hasContributorRole_p) {
                case (true,  true):  rbacAccessLevel = .full
                case (true,  false): rbacAccessLevel = .dataOnly
                case (false, true):  rbacAccessLevel = .managementOnly
                case (false, false): rbacAccessLevel = .denied
                }
            }
        } catch {
            rbacAccessLevel = .checkFailed(error.localizedDescription)
            accessTier = .noAccess
            capabilityMap = .none
        }
    }

    /// Forces a re-check of RBAC permissions (e.g. from a "Re-evaluate my access" button).
    func refreshRbacPermissions() {
        Task { await checkRbacPermissions(force: true) }
    }

    // MARK: - Disconnect

    func disconnect() async throws -> Buskit_DisconnectReply {
        guard let buskit else { throw GRPCManagerError.notConnected }
        let req = Buskit_DisconnectRequest()
        let reply = try await buskit.disconnect(req)
        connectionState = .disconnected
        namespaceName = nil
        rbacAccessLevel = .notApplicable
        accessTier = .noAccess
        capabilityMap = .none
        upgradeRecommendation = nil
        isPartialAccess = false
        rbacEvaluatedAt = nil
        rbacExpiresAt = nil
        rbacCheckedNamespace = nil
        // Do NOT reset Azure login state here — the user stays signed in so
        // they can immediately switch to another namespace. Call
        // resetAzureLoginState() explicitly when the user clicks "Sign out".
        return reply
    }

    func resetAzureLoginState() {
        connectionState = .disconnected
        namespaceName = nil
        azureLoginPhase = .idle
        azureLoginError = nil
        azureSubscriptions = []
        azureTenants = []
        azureNamespaces = []
        selectedAzureSubscriptionId = ""
        selectedAzureTenantId = ""
        selectedAzureNamespaceFQNS = ""
        isLoadingAzureNamespaces = false
        rbacAccessLevel = .notApplicable
        accessTier = .noAccess
        capabilityMap = .none
        upgradeRecommendation = nil
        isPartialAccess = false
        rbacEvaluatedAt = nil
        rbacExpiresAt = nil
        rbacCheckedNamespace = nil
    }

    private static func extractNamespace(from connectionString: String) -> String? {
        for part in connectionString.components(separatedBy: ";") {
            let kv = part.trimmingCharacters(in: .whitespaces)
            guard kv.lowercased().hasPrefix("endpoint=") else { continue }
            let value = String(kv.dropFirst("Endpoint=".count))
            let host = value
                .replacingOccurrences(of: "sb://", with: "", options: [.caseInsensitive])
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return host.components(separatedBy: ".").first
        }
        return nil
    }

    // MARK: - Get Queue Properties

    func getQueueProperties(name: String) async throws -> QueueDetailsItem {
        guard let buskit else { throw GRPCManagerError.notConnected }
        var req = Buskit_GetQueuePropertiesRequest()
        req.name = name
        let reply: Buskit_GetQueuePropertiesReply = try await buskit.getQueueProperties(req)
        let p = reply.properties
        return QueueDetailsItem(
            name: p.name,
            maxSizeMb: p.maxSizeMb,
            defaultMessageTtlSeconds: p.defaultMessageTtlSeconds,
            lockDurationSeconds: p.lockDurationSeconds,
            requiresDuplicateDetection: p.requiresDuplicateDetection,
            requiresSession: p.requiresSession,
            maxDeliveryCount: p.maxDeliveryCount,
            deadLetteringOnExpiration: p.deadLetteringOnExpiration,
            status: p.status,
            createdAt: Date(timeIntervalSince1970: TimeInterval(p.createdAtUnix)),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(p.updatedAtUnix)),
            activeMessageCount: p.activeMessageCount,
            deadLetterCount: p.deadLetterCount,
            sizeBytes: p.sizeBytes,
            forwardTo: p.forwardTo,
            autoDeleteOnIdleSeconds: p.autoDeleteOnIdleSeconds,
            scheduledMessageCount: p.scheduledMessageCount,
            transferMessageCount: p.transferMessageCount,
            transferDeadLetterCount: p.transferDeadLetterCount,
            maxMessageSizeBytes: p.maxMessageSizeBytes,
            duplicateDetectionWindowSeconds: p.duplicateDetectionWindowSeconds,
            userMetadata: p.userMetadata,
            enablePartitioning: p.enablePartitioning
        )
    }

    // MARK: - Get Topic Properties

    func getTopicProperties(name: String) async throws -> TopicDetailsItem {
        guard let buskit else { throw GRPCManagerError.notConnected }
        var req = Buskit_GetTopicPropertiesRequest()
        req.name = name
        let reply: Buskit_GetTopicPropertiesReply = try await buskit.getTopicProperties(req)
        let p = reply.properties
        return TopicDetailsItem(
            name: p.name,
            maxSizeMb: p.maxSizeMb,
            defaultMessageTtlSeconds: p.defaultMessageTtlSeconds,
            requiresDuplicateDetection: p.requiresDuplicateDetection,
            supportOrdering: p.supportOrdering,
            enablePartitioning: p.enablePartitioning,
            status: p.status,
            createdAt: Date(timeIntervalSince1970: TimeInterval(p.createdAtUnix)),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(p.updatedAtUnix)),
            scheduledMessageCount: p.scheduledMessageCount,
            sizeBytes: p.sizeBytes,
            maxMessageSizeBytes: p.maxMessageSizeBytes,
            autoDeleteOnIdleSeconds: p.autoDeleteOnIdleSeconds,
            userMetadata: p.userMetadata
        )
    }

    // MARK: - Get Topic Metrics

    func getTopicMetrics(topicName: String, hours: Int) async throws -> [Buskit_MetricSeries] {
        guard let buskit else { throw GRPCManagerError.notConnected }
        var req = Buskit_GetTopicMetricsRequest()
        req.topicName = topicName
        req.hours = Int32(hours)
        let reply: Buskit_GetTopicMetricsReply = try await buskit.getTopicMetrics(req)
        if !reply.error.isEmpty {
            throw NSError(domain: "BusKit", code: 0, userInfo: [NSLocalizedDescriptionKey: reply.error])
        }
        return reply.series
    }

    func getQueueMetrics(queueName: String, hours: Int) async throws -> [Buskit_MetricSeries] {
        guard let buskit else { throw GRPCManagerError.notConnected }
        var req = Buskit_GetQueueMetricsRequest()
        req.queueName = queueName
        req.hours = Int32(hours)
        let reply: Buskit_GetQueueMetricsReply = try await buskit.getQueueMetrics(req)
        if !reply.error.isEmpty {
            throw NSError(domain: "BusKit", code: 0, userInfo: [NSLocalizedDescriptionKey: reply.error])
        }
        return reply.series
    }

    // MARK: - Get Subscription Properties

    func getSubscriptionProperties(topicName: String, subscriptionName: String) async throws -> SubscriptionDetailsItem {
        guard let buskit else { throw GRPCManagerError.notConnected }
        var req = Buskit_GetSubscriptionPropertiesRequest()
        req.topicName = topicName
        req.subscriptionName = subscriptionName
        let reply: Buskit_GetSubscriptionPropertiesReply = try await buskit.getSubscriptionProperties(req)
        let p = reply.properties
        return SubscriptionDetailsItem(
            topicName: p.topicName,
            name: p.name,
            defaultMessageTtlSeconds: p.defaultMessageTtlSeconds,
            lockDurationSeconds: p.lockDurationSeconds,
            maxDeliveryCount: p.maxDeliveryCount,
            deadLetteringOnExpiration: p.deadLetteringOnExpiration,
            deadLetteringOnFilterEvaluation: p.deadLetteringOnFilterEvaluation,
            status: p.status,
            createdAt: Date(timeIntervalSince1970: TimeInterval(p.createdAtUnix)),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(p.updatedAtUnix)),
            activeMessageCount: p.activeMessageCount,
            deadLetterCount: p.deadLetterCount,
            forwardTo: p.forwardTo,
            autoDeleteOnIdleSeconds: p.autoDeleteOnIdleSeconds
        )
    }

    // MARK: - Update Subscription TTL

    func updateSubscriptionTtl(topicName: String, subscriptionName: String, ttlSeconds: Int64) async throws {
        guard let buskit else { throw GRPCManagerError.notConnected }
        var req = Buskit_UpdateSubscriptionTtlRequest()
        req.topicName = topicName
        req.subscriptionName = subscriptionName
        req.defaultMessageTtlSeconds = ttlSeconds
        let reply: Buskit_UpdateSubscriptionTtlReply = try await buskit.updateSubscriptionTtl(req)
        if !reply.error.isEmpty { throw GRPCManagerError.operationFailed(reply.error) }
    }

    // MARK: - List Queues

    func listQueues() async throws -> [Buskit_QueueInfo] {
        guard let buskit else { throw GRPCManagerError.notConnected }
        let req = Buskit_ListQueuesRequest()
        let reply: Buskit_ListQueuesReply = try await buskit.listQueues(req)
        return Array(reply.queues)
    }

    // MARK: - List Topics

    func listTopics() async throws -> [Buskit_TopicInfo] {
        guard let buskit else { throw GRPCManagerError.notConnected }
        let req = Buskit_ListTopicsRequest()
        let reply: Buskit_ListTopicsReply = try await buskit.listTopics(req)
        return Array(reply.topics)
    }

    // MARK: - List Subscriptions

    func listSubscriptions(topicName: String) async throws -> [Buskit_SubscriptionInfo] {
        guard let buskit else { throw GRPCManagerError.notConnected }
        var req = Buskit_ListSubscriptionsRequest()
        req.topicName = topicName
        let reply: Buskit_ListSubscriptionsReply = try await buskit.listSubscriptions(req)
        return Array(reply.subscriptions)
    }

    // MARK: - List Rules

    func listRules(topicName: String, subscriptionName: String) async throws -> [Buskit_RuleInfo] {
        guard let buskit else { throw GRPCManagerError.notConnected }
        var req = Buskit_ListRulesRequest()
        req.topicName = topicName
        req.subscriptionName = subscriptionName
        let reply: Buskit_ListRulesReply = try await buskit.listRules(req)
        return Array(reply.rules)
    }

    // MARK: - Create Queue

    func createQueue(
        name: String,
        maxSizeMb: Int64,
        maxDeliveryCount: Int32,
        defaultMessageTtlSeconds: Int64,
        lockDurationSeconds: Int64,
        requiresDuplicateDetection: Bool,
        requiresSession: Bool,
        deadLetteringOnExpiration: Bool,
        enablePartitioning: Bool,
        forwardTo: String,
        autoDeleteOnIdleSeconds: Int64
    ) async throws {
        guard let buskit else { throw GRPCManagerError.notConnected }
        var req = Buskit_CreateQueueRequest()
        req.queueName = name
        req.maxSizeMb = maxSizeMb
        req.maxDeliveryCount = maxDeliveryCount
        req.defaultMessageTtlSeconds = defaultMessageTtlSeconds
        req.lockDurationSeconds = lockDurationSeconds
        req.requiresDuplicateDetection = requiresDuplicateDetection
        req.requiresSession = requiresSession
        req.deadLetteringOnExpiration = deadLetteringOnExpiration
        req.enablePartitioning = enablePartitioning
        req.forwardTo = forwardTo
        req.autoDeleteOnIdleSeconds = autoDeleteOnIdleSeconds
        let reply: Buskit_CreateQueueReply = try await buskit.createQueue(req)
        if !reply.error.isEmpty { throw GRPCManagerError.operationFailed(reply.error) }
    }

    // MARK: - Delete Queue

    func deleteQueue(name: String) async throws {
        guard let buskit else { throw GRPCManagerError.notConnected }
        var req = Buskit_DeleteQueueRequest()
        req.queueName = name
        let reply: Buskit_DeleteQueueReply = try await buskit.deleteQueue(req)
        if !reply.error.isEmpty { throw GRPCManagerError.operationFailed(reply.error) }
    }

    // MARK: - Set Queue Status

    func setQueueStatus(name: String, status: String) async throws {
        guard let buskit else { throw GRPCManagerError.notConnected }
        var req = Buskit_SetQueueStatusRequest()
        req.queueName = name
        req.status = status
        let reply: Buskit_SetQueueStatusReply = try await buskit.setQueueStatus(req)
        if !reply.error.isEmpty { throw GRPCManagerError.operationFailed(reply.error) }
    }

    // MARK: - Set Topic Status

    func setTopicStatus(name: String, status: String) async throws {
        guard let buskit else { throw GRPCManagerError.notConnected }
        var req = Buskit_SetTopicStatusRequest()
        req.topicName = name
        req.status = status
        let reply: Buskit_SetTopicStatusReply = try await buskit.setTopicStatus(req)
        if !reply.error.isEmpty { throw GRPCManagerError.operationFailed(reply.error) }
    }

    // MARK: - Create Topic

    func createTopic(
        name: String,
        maxSizeMb: Int64,
        defaultMessageTtlSeconds: Int64,
        requiresDuplicateDetection: Bool,
        enablePartitioning: Bool,
        supportOrdering: Bool,
        autoDeleteOnIdleSeconds: Int64
    ) async throws {
        guard let buskit else { throw GRPCManagerError.notConnected }
        var req = Buskit_CreateTopicRequest()
        req.topicName = name
        req.maxSizeMb = maxSizeMb
        req.defaultMessageTtlSeconds = defaultMessageTtlSeconds
        req.requiresDuplicateDetection = requiresDuplicateDetection
        req.enablePartitioning = enablePartitioning
        req.supportOrdering = supportOrdering
        req.autoDeleteOnIdleSeconds = autoDeleteOnIdleSeconds
        let reply: Buskit_CreateTopicReply = try await buskit.createTopic(req)
        if !reply.error.isEmpty { throw GRPCManagerError.operationFailed(reply.error) }
    }

    // MARK: - Delete Topic

    func deleteTopic(name: String) async throws {
        guard let buskit else { throw GRPCManagerError.notConnected }
        var req = Buskit_DeleteTopicRequest()
        req.topicName = name
        let reply: Buskit_DeleteTopicReply = try await buskit.deleteTopic(req)
        if !reply.error.isEmpty { throw GRPCManagerError.operationFailed(reply.error) }
    }

    // MARK: - Create Subscription

    func createSubscription(
        topicName: String,
        subscriptionName: String,
        maxDeliveryCount: Int32,
        defaultMessageTtlSeconds: Int64,
        lockDurationSeconds: Int64,
        autoDeleteOnIdleSeconds: Int64,
        neverAutoDelete: Bool,
        enableSessions: Bool,
        deadLetteringOnExpiration: Bool,
        deadLetteringOnFilterEvaluation: Bool,
        forwardMessages: Bool,
        forwardTo: String
    ) async throws {
        guard let buskit else { throw GRPCManagerError.notConnected }
        var req = Buskit_CreateSubscriptionRequest()
        req.topicName = topicName
        req.subscriptionName = subscriptionName
        req.maxDeliveryCount = maxDeliveryCount
        req.defaultMessageTtlSeconds = defaultMessageTtlSeconds
        req.lockDurationSeconds = lockDurationSeconds
        req.autoDeleteOnIdleSeconds = autoDeleteOnIdleSeconds
        req.neverAutoDelete = neverAutoDelete
        req.enableSessions = enableSessions
        req.deadLetteringOnExpiration = deadLetteringOnExpiration
        req.deadLetteringOnFilterEvaluation = deadLetteringOnFilterEvaluation
        req.forwardMessages = forwardMessages
        req.forwardTo = forwardTo
        let reply: Buskit_CreateSubscriptionReply = try await buskit.createSubscription(req)
        if !reply.error.isEmpty { throw GRPCManagerError.operationFailed(reply.error) }
    }

    // MARK: - Delete Subscription

    func deleteSubscription(topicName: String, subscriptionName: String) async throws {
        guard let buskit else { throw GRPCManagerError.notConnected }
        var req = Buskit_DeleteSubscriptionRequest()
        req.topicName = topicName
        req.subscriptionName = subscriptionName
        let reply: Buskit_DeleteSubscriptionReply = try await buskit.deleteSubscription(req)
        if !reply.error.isEmpty { throw GRPCManagerError.operationFailed(reply.error) }
    }



    func addRule(topicName: String, subscriptionName: String, ruleName: String, sqlFilter: String) async throws {
        guard let buskit else { throw GRPCManagerError.notConnected }
        var req = Buskit_AddRuleRequest()
        req.topicName = topicName
        req.subscriptionName = subscriptionName
        req.ruleName = ruleName
        req.sqlFilter = sqlFilter
        let reply: Buskit_AddRuleReply = try await buskit.addRule(req)
        if !reply.error.isEmpty { throw GRPCManagerError.operationFailed(reply.error) }
    }

    // MARK: - Update Rule

    func updateRule(topicName: String, subscriptionName: String, ruleName: String, sqlFilter: String) async throws {
        guard let buskit else { throw GRPCManagerError.notConnected }
        var req = Buskit_UpdateRuleRequest()
        req.topicName = topicName
        req.subscriptionName = subscriptionName
        req.ruleName = ruleName
        req.sqlFilter = sqlFilter
        let reply: Buskit_UpdateRuleReply = try await buskit.updateRule(req)
        if !reply.error.isEmpty { throw GRPCManagerError.operationFailed(reply.error) }
    }

    // MARK: - Delete Rule

    func deleteRule(topicName: String, subscriptionName: String, ruleName: String) async throws {
        guard let buskit else { throw GRPCManagerError.notConnected }
        var req = Buskit_DeleteRuleRequest()
        req.topicName = topicName
        req.subscriptionName = subscriptionName
        req.ruleName = ruleName
        let reply: Buskit_DeleteRuleReply = try await buskit.deleteRule(req)
        if !reply.error.isEmpty { throw GRPCManagerError.operationFailed(reply.error) }
    }

    // MARK: - Peek Messages

    func peekMessages(queueName: String? = nil,
                      topicName: String? = nil,
                      subscriptionName: String? = nil,
                      isDLQ: Bool = false,
                      maxCount: Int32 = 10) async throws -> [MessageItem] {
        guard let buskit else { throw GRPCManagerError.notConnected }
        var req = Buskit_PeekMessagesRequest()
        req.maxMessages = maxCount
        req.deadLetter  = isDLQ
        if let q = queueName        { req.queueName        = q }
        if let t = topicName        { req.topicName        = t }
        if let s = subscriptionName { req.subscriptionName = s }
        let reply: Buskit_PeekMessagesReply = try await buskit.peekMessages(req)
        return reply.messages.map { m in
            MessageItem(
                messageId: m.messageID,
                body: m.body,
                contentType: m.contentType,
                enqueuedTime: Date(timeIntervalSince1970: TimeInterval(m.enqueuedTimeUnix)),
                properties: Dictionary(uniqueKeysWithValues: m.properties.map { ($0.key, $0.value) }),
                sequenceNumber: m.sequenceNumber,
                deliveryCount: m.deliveryCount,
                expiresAt: Date(timeIntervalSince1970: TimeInterval(m.expiresAtUnix)),
                subject: m.subject,
                correlationId: m.correlationID,
                replyTo: m.replyTo,
                toAddress: m.toAddress,
                sessionId: m.sessionID,
                partitionKey: m.partitionKey
            )
        }
    }

    // MARK: - Purge Messages

    func purgeMessages(queueName: String? = nil,
                       topicName: String? = nil,
                       subscriptionName: String? = nil,
                       isDLQ: Bool = false) async throws -> Int32 {
        guard let buskit else { throw GRPCManagerError.notConnected }
        var req = Buskit_PurgeMessagesRequest()
        req.deadLetter = isDLQ
        if let q = queueName        { req.queueName        = q }
        if let t = topicName        { req.topicName        = t }
        if let s = subscriptionName { req.subscriptionName = s }
        let reply: Buskit_PurgeMessagesReply = try await buskit.purgeMessages(req)
        return reply.purgedCount
    }

    // MARK: - Send Message

    func sendMessage(queueOrTopic: String, body: String) async throws -> Buskit_SendMessageReply {
        guard let buskit else { throw GRPCManagerError.notConnected }
        var req = Buskit_SendMessageRequest()
        req.queueName = queueOrTopic
        req.body = body
        return try await buskit.sendMessage(req)
    }

    // MARK: - Delete Message
    func deleteMessage(queueName: String? = nil,
                       topicName: String? = nil,
                       subscriptionName: String? = nil,
                       isDLQ: Bool = false,
                       sequenceNumber: Int64) async throws {
        guard let buskit else { throw GRPCManagerError.notConnected }
        var req = Buskit_DeleteMessageRequest()
        req.queueName = queueName ?? ""
        req.topicName = topicName ?? ""
        req.subscriptionName = subscriptionName ?? ""
        req.deadLetter = isDLQ
        req.sequenceNumber = sequenceNumber
        let reply = try await buskit.deleteMessage(req)
        if !reply.success {
            throw GRPCManagerError.operationFailed(reply.error)
        }
    }

    // MARK: - Send Message Extended (preserves system properties)
    func sendMessageExtended(queueOrTopic: String,
                             body: String,
                             contentType: String = "",
                             subject: String = "",
                             correlationID: String = "",
                             replyTo: String = "",
                             toAddress: String = "",
                             sessionID: String = "",
                             partitionKey: String = "",
                             properties: [String: String] = [:]) async throws -> Buskit_SendMessageReply {
        guard let buskit else { throw GRPCManagerError.notConnected }
        var req = Buskit_SendMessageExtendedRequest()
        req.queueOrTopic = queueOrTopic
        req.body = body
        req.contentType = contentType
        req.subject = subject
        req.correlationID = correlationID
        req.replyTo = replyTo
        req.toAddress = toAddress
        req.sessionID = sessionID
        req.partitionKey = partitionKey
        req.properties = properties
        do {
            let reply = try await buskit.sendMessageExtended(req)
            if !reply.success {
                throw GRPCManagerError.operationFailed(reply.error.isEmpty ? "Send failed" : reply.error)
            }
            return reply
        } catch let rpcError as RPCError {
            throw GRPCManagerError.operationFailed(
                rpcError.message.isEmpty ? "gRPC error (\(rpcError.code))" : rpcError.message
            )
        }
    }

    // MARK: - Subscribe (server streaming)

    func subscribe(topicName: String, subscriptionName: String) async throws -> AsyncStream<Buskit_BusMessage> {
        guard let buskit else { throw GRPCManagerError.notConnected }
        var req = Buskit_SubscribeRequest()
        req.queueName = topicName

        return AsyncStream { continuation in
            Task {
                do {
                    try await buskit.subscribeMessages(req) { response in
                        for try await message in response.messages {
                            continuation.yield(message)
                        }
                        continuation.finish()
                    }
                } catch {
                    continuation.finish()
                }
            }
        }
    }
}

@available(macOS 15.0, *)
enum GRPCManagerError: LocalizedError {
    case notConnected
    case azureError(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "gRPC client is not connected. Call startSidecar() first."
        case .azureError(let msg): return msg
        case .operationFailed(let msg): return msg
        }
    }
}

private extension Data {
    func append(fileURL: URL) throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            handle.seekToEndOfFile()
            handle.write(self)
            handle.closeFile()
        } else {
            try write(to: fileURL, options: .atomic)
        }
    }
}

