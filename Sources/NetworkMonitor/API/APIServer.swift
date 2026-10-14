import AppKit
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// A read-only HTTP API on 127.0.0.1 that other local apps (Lantern) read captured traffic from.
///
/// It binds a free loopback port and writes that port and a random token to `api.json` (mode 0600) in the app's
/// support directory; every request must send `Authorization: Bearer <token>`. Bodies hold tokens and personal data,
/// so the API is never on the proxy's LAN-facing port, and the token keeps out other users' processes and web pages.
///
///     GET /v1/transactions?since=<revision>&limit=<n>   metadata of what changed after `since`, oldest first
///     GET /v1/transactions/<id>                          one transaction with headers and bodies
///
/// Response bodies are as URLSession decoded them: already decompressed, even when the recorded headers still say
/// `Content-Encoding: gzip`.
final class APIServer: @unchecked Sendable {
    static let infoURL = CertificateAuthority.defaultDirectory.appendingPathComponent("api.json")

    private let source: APISource
    private let token = APIServer.makeToken()
    /// Tells a client that Network Monitor restarted (and its revisions started again from zero).
    private let instance = UUID().uuidString.lowercased()
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?

    init(source: APISource) {
        self.source = source
    }

    func start() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        let source = source
        let token = token
        let instance = instance
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: true).flatMap {
                    channel.pipeline.addHandler(APIHandler(source: source, token: token, instance: instance))
                }
            }
        do {
            let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
            self.channel = channel
            guard let port = channel.localAddress?.port else { throw APIError.noPort }
            try writeInfo(port: port)
        } catch {
            try? await group.shutdownGracefully()
            self.group = nil
            throw error
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            try? FileManager.default.removeItem(at: APIServer.infoURL)
        }
    }

    /// Written to a temporary file created 0600, then moved into place, so the token is never readable by others.
    private func writeInfo(port: Int) throws {
        let info: [String: Any] = ["port": port, "token": token, "pid": ProcessInfo.processInfo.processIdentifier, "version": 1]
        let data = try JSONSerialization.data(withJSONObject: info, options: [.sortedKeys])
        let directory = Self.infoURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent("api.json.\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw APIError.cannotWriteInfo
        }
        guard rename(temporary.path, Self.infoURL.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw APIError.cannotWriteInfo
        }
    }

    private static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }
}

enum APIError: LocalizedError {
    case noPort
    case cannotWriteInfo

    var errorDescription: String? {
        switch self {
        case .noPort: return "The API socket has no port."
        case .cannotWriteInfo: return "Could not write \(APIServer.infoURL.path)."
        }
    }
}

struct APIResponse: Sendable {
    let status: HTTPResponseStatus
    let body: Data

    static func json<T: Encodable>(_ value: T, status: HTTPResponseStatus = .ok) -> APIResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let body = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return APIResponse(status: status, body: body)
    }

    static func error(_ status: HTTPResponseStatus, _ message: String) -> APIResponse {
        json(["error": message], status: status)
    }
}

/// One per connection. Requests are answered in order (the pipelining assistance holds back the next one).
private final class APIHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let source: APISource
    private let token: String
    private let instance: String
    private var head: HTTPRequestHead?

    init(source: APISource, token: String, instance: String) {
        self.source = source
        self.token = token
        self.instance = instance
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
        case .body:
            break
        case .end:
            guard let head else { return }
            self.head = nil
            let promise = context.eventLoop.makePromise(of: APIResponse.self)
            let (source, token, instance) = (source, token, instance)
            promise.completeWithTask { await APIRoutes.respond(to: head, token: token, instance: instance, source: source) }
            promise.futureResult.whenSuccess { [self] response in
                write(response, keepAlive: head.isKeepAlive, context: context)
            }
        }
    }

    private func write(_ response: APIResponse, keepAlive: Bool, context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json; charset=utf-8")
        headers.add(name: "Content-Length", value: String(response.body.count))
        headers.add(name: "Connection", value: keepAlive ? "keep-alive" : "close")
        headers.add(name: "Cache-Control", value: "no-store")
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: response.status, headers: headers))), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(bytes: response.body)))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            if !keepAlive { context.close(promise: nil) }
        }
    }
}

enum APIRoutes {
    static let maxLimit = 5000

    static func respond(to head: HTTPRequestHead, token: String, instance: String, source: APISource) async -> APIResponse {
        guard head.headers.first(name: "Authorization") == "Bearer \(token)" else {
            return .error(.unauthorized, "Missing or wrong token: read it from \(APIServer.infoURL.path).")
        }
        guard head.method == .GET else { return .error(.methodNotAllowed, "Only GET is supported.") }
        guard let components = URLComponents(string: head.uri) else { return .error(.badRequest, "Bad URL.") }
        let parts = components.path.split(separator: "/").map(String.init)
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })

        switch parts {
        case ["v1", "transactions"]:
            let since = query["since"].flatMap(UInt64.init) ?? 0
            let limit = query["limit"].flatMap(Int.init).map { min(max($0, 1), maxLimit) }
            let (revision, transactions) = await source.list(since: since, limit: limit)
            return .json(APIList(instance: instance, revision: revision, transactions: transactions.map(APITransaction.init)))
        case let path where path.count == 3 && path[0] == "v1" && path[1] == "transactions":
            guard let id = UUID(uuidString: path[2]) else { return .error(.badRequest, "Not a transaction id.") }
            guard let transaction = await source.transaction(id: id) else {
                return .error(.notFound, "No such transaction: it may have been cleared, or dropped past the 5,000 kept.")
            }
            return .json(APITransactionDetail(transaction))
        default:
            return .error(.notFound, "Unknown path.")
        }
    }
}

// MARK: - Wire format

struct APIList: Encodable {
    let instance: String
    /// The newest revision: pass it as `since` next time to get only what changed after this.
    let revision: UInt64
    let transactions: [APITransaction]
}

struct APITransaction: Encodable {
    let id: String
    let revision: UInt64
    /// Milliseconds since 1970.
    let startedAt: Double
    let method: String
    let url: String
    let host: String
    let path: String
    let status: Int?
    let durationMs: Double?
    /// pending, completed or failed.
    let state: String
    let error: String?
    let requestContentType: String?
    let responseContentType: String?
    let requestSize: Int
    let responseSize: Int

    init(_ t: Transaction) {
        id = t.id.uuidString.lowercased()
        revision = t.revision
        startedAt = (t.startedAt.timeIntervalSince1970 * 1000).rounded()
        method = t.method
        url = t.url
        host = t.host
        path = t.path
        status = t.statusCode
        durationMs = t.duration.map { ($0 * 1000).rounded() }
        switch t.outcome {
        case .pending: state = "pending"
        case .completed: state = "completed"
        case .failed: state = "failed"
        }
        error = t.errorMessage
        requestContentType = t.requestContentType
        responseContentType = t.responseContentType
        requestSize = t.requestBody.count
        responseSize = t.responseBody.count
    }
}

struct APIHeader: Encodable {
    let name: String
    let value: String
}

struct APIBody: Encodable {
    /// utf8 when the bytes are valid UTF-8 text, base64 otherwise.
    let encoding: String
    let data: String
    let size: Int

    init(_ data: Data) {
        size = data.count
        if let text = String(data: data, encoding: .utf8) {
            encoding = "utf8"
            self.data = text
        } else {
            encoding = "base64"
            self.data = data.base64EncodedString()
        }
    }
}

struct APITransactionDetail: Encodable {
    let transaction: APITransaction
    let requestHeaders: [APIHeader]
    let requestBody: APIBody
    let responseHeaders: [APIHeader]
    let responseBody: APIBody

    init(_ t: Transaction) {
        transaction = APITransaction(t)
        requestHeaders = t.requestHeaders.map { APIHeader(name: $0.name, value: $0.value) }
        requestBody = APIBody(t.requestBody)
        responseHeaders = t.responseHeaders.map { APIHeader(name: $0.name, value: $0.value) }
        responseBody = APIBody(t.responseBody)
    }
}
