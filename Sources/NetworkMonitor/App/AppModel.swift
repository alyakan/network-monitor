import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    private static let portKey = "proxyPort"
    private static let maxTransactions = 5000

    private(set) var transactions: [Transaction] = []
    var selectedTransactionID: Transaction.ID?
    var filterText = ""
    var port: Int {
        didSet { UserDefaults.standard.set(port, forKey: Self.portKey) }
    }
    private(set) var isRunning = false
    private(set) var isStarting = false
    private(set) var errorMessage: String?
    private(set) var setupMessage: String?
    private(set) var isSystemProxyEnabled = false

    let authority: CertificateAuthority?
    let localAddresses: [String]

    private var server: ProxyServer?

    init() {
        let storedPort = UserDefaults.standard.integer(forKey: Self.portKey)
        port = storedPort > 0 ? storedPort : 8888
        localAddresses = NetworkInterfaces.ipv4Addresses()
        do {
            authority = try CertificateAuthority()
        } catch {
            authority = nil
            errorMessage = "Could not create the root certificate: \(error.localizedDescription)"
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.isSystemProxyEnabled == true {
                    SystemProxy.disableSync()
                }
            }
        }
    }

    // MARK: - Derived state

    var filteredTransactions: [Transaction] {
        let needle = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return transactions }
        return transactions.filter { transaction in
            transaction.host.lowercased().contains(needle)
                || transaction.path.lowercased().contains(needle)
                || transaction.method.lowercased() == needle
                || transaction.statusCode.map { String($0).hasPrefix(needle) } == true
        }
    }

    var selectedTransaction: Transaction? {
        guard let id = selectedTransactionID else { return nil }
        return transactions.first { $0.id == id }
    }

    var certificatePath: String { authority?.certificateURL.path ?? "" }

    // MARK: - Proxy lifecycle

    func toggleProxy() {
        if isRunning {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard let authority, !isStarting else { return }
        isStarting = true
        errorMessage = nil
        let server = ProxyServer(authority: authority, recorder: Recorder(model: self))
        let identity = ProxyIdentity(port: port, addresses: Set(localAddresses.map { $0.lowercased() }))
        Task {
            do {
                try await server.start(identity: identity)
                self.server = server
                isRunning = true
            } catch {
                errorMessage = "Could not listen on port \(port): \(error.localizedDescription)"
            }
            isStarting = false
        }
    }

    func stop() {
        let server = server
        self.server = nil
        isRunning = false
        Task {
            await server?.stop()
            if isSystemProxyEnabled {
                await setSystemProxy(enabled: false)
            }
        }
    }

    func clear() {
        transactions.removeAll()
        selectedTransactionID = nil
    }

    // MARK: - Setup helpers

    func installCertificateInBootedSimulator() {
        guard let authority else { return }
        setupMessage = "Installing…"
        Task {
            let result = await ShellCommand.run("/usr/bin/xcrun", ["simctl", "keychain", "booted", "add-root-cert", authority.certificateURL.path])
            setupMessage = result.succeeded
                ? "Root certificate installed and trusted in the booted simulator."
                : "simctl failed: \(result.output)"
        }
    }

    func setSystemProxy(enabled: Bool) async {
        let result = enabled ? await SystemProxy.enable(port: port) : await SystemProxy.disable()
        if result.succeeded {
            isSystemProxyEnabled = enabled
            setupMessage = enabled ? "macOS now routes HTTP/HTTPS through 127.0.0.1:\(port)." : "macOS system proxy disabled."
        } else {
            setupMessage = "networksetup failed: \(result.output)"
        }
    }

    func revealCertificate() {
        guard let authority else { return }
        NSWorkspace.shared.activateFileViewerSelecting([authority.certificateURL])
    }

    // MARK: - Recording

    fileprivate func append(_ transaction: Transaction) {
        transactions.append(transaction)
        if transactions.count > Self.maxTransactions {
            transactions.removeFirst(transactions.count - Self.maxTransactions)
        }
    }

    fileprivate func update(id: UUID, _ change: (inout Transaction) -> Void) {
        guard let index = transactions.firstIndex(where: { $0.id == id }) else { return }
        change(&transactions[index])
    }
}

private final class Recorder: TransactionRecorder {
    private weak let model: AppModel?

    init(model: AppModel) {
        self.model = model
    }

    func transactionDidStart(_ transaction: Transaction) {
        Task { @MainActor [model] in model?.append(transaction) }
    }

    func transactionDidComplete(id: UUID, statusCode: Int, headers: [HTTPHeaderField], body: Data, duration: TimeInterval) {
        Task { @MainActor [model] in
            model?.update(id: id) { transaction in
                transaction.statusCode = statusCode
                transaction.responseHeaders = headers
                transaction.responseBody = body
                transaction.duration = duration
                transaction.outcome = .completed
            }
        }
    }

    func transactionDidFail(id: UUID, message: String, duration: TimeInterval) {
        Task { @MainActor [model] in
            model?.update(id: id) { transaction in
                transaction.duration = duration
                transaction.outcome = .failed(message)
            }
        }
    }
}
