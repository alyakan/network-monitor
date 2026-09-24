import Foundation
import NIOCore
import NIOHTTP1
import NIOSSL

struct ProxyIdentity: Sendable {
    let port: Int
    let addresses: Set<String>

    func isSelf(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let urlPort = url.port ?? (url.scheme == "https" ? 443 : 80)
        return urlPort == port && (addresses.contains(host) || host == "localhost" || host == "127.0.0.1")
    }
}

/// One instance per client connection. Handles plain proxy requests, CONNECT tunnels
/// (upgrading the connection to TLS with a per-host certificate) and the setup pages.
final class ProxyHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private struct Tunnel {
        let host: String
        let port: Int
    }

    private struct BufferedRequest {
        let head: HTTPRequestHead
        var body: ByteBuffer
    }

    private static let strippedResponseHeaders: Set<String> = [
        "content-encoding", "content-length", "transfer-encoding",
        "connection", "keep-alive", "proxy-connection", "upgrade", "trailer",
    ]

    private let authority: CertificateAuthority
    private let upstream: UpstreamClient
    private let recorder: TransactionRecorder
    private let identity: ProxyIdentity

    private var tunnel: Tunnel?
    private var pendingConnect: Tunnel?
    private var current: BufferedRequest?
    private var queue: [BufferedRequest] = []
    private var isBusy = false

    init(authority: CertificateAuthority, upstream: UpstreamClient, recorder: TransactionRecorder, identity: ProxyIdentity) {
        self.authority = authority
        self.upstream = upstream
        self.recorder = recorder
        self.identity = identity
    }

    // MARK: - ChannelInboundHandler

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            if head.method == .CONNECT {
                pendingConnect = Self.parseAuthority(head.uri)
            } else {
                current = BufferedRequest(head: head, body: context.channel.allocator.buffer(capacity: 0))
            }
        case .body(var chunk):
            current?.body.writeBuffer(&chunk)
        case .end:
            if let target = pendingConnect {
                pendingConnect = nil
                establishTunnel(to: target, context: context)
            } else if let request = current {
                current = nil
                queue.append(request)
                processQueue(context: context)
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    // MARK: - CONNECT

    private static func parseAuthority(_ uri: String) -> Tunnel? {
        let parts = uri.split(separator: ":", maxSplits: 1)
        guard let host = parts.first, !host.isEmpty else { return nil }
        let port = parts.count > 1 ? Int(parts[1]) ?? 443 : 443
        return Tunnel(host: String(host), port: port)
    }

    private func establishTunnel(to target: Tunnel?, context: ChannelHandlerContext) {
        guard let target else {
            writeSimpleResponse(status: .badRequest, body: "Malformed CONNECT request", keepAlive: false, context: context)
            return
        }
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "0")
        let head = HTTPResponseHead(version: .http1_1, status: .custom(code: 200, reasonPhrase: "Connection Established"), headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { [self] result in
            switch result {
            case .success:
                tunnel = target
                insertTLS(host: target.host, context: context)
            case .failure:
                context.close(promise: nil)
            }
        }
    }

    /// Pipeline before: [decoder, encoder, self]. After: [tls, decoder', encoder, self].
    /// The TLS handler is inserted behind the old decoder so its leftover bytes (the
    /// ClientHello, if it already arrived) are forwarded into TLS when the decoder is removed.
    private func insertTLS(host: String, context: ChannelHandlerContext) {
        do {
            let ssl = NIOSSLServerHandler(context: try authority.sslContext(for: host))
            let pipeline = context.pipeline
            let oldDecoder = try pipeline.syncOperations.handler(type: ByteToMessageHandler<HTTPRequestDecoder>.self)
            try pipeline.syncOperations.addHandler(ssl, position: .after(oldDecoder))
            pipeline.syncOperations.removeHandler(oldDecoder).flatMapThrowing {
                let decoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
                try pipeline.syncOperations.addHandler(decoder, position: .after(ssl))
            }.whenFailure { _ in
                context.close(promise: nil)
            }
        } catch {
            context.close(promise: nil)
        }
    }

    // MARK: - Request handling

    private func processQueue(context: ChannelHandlerContext) {
        guard !isBusy, !queue.isEmpty else { return }
        isBusy = true
        handle(queue.removeFirst(), context: context)
    }

    private func requestFinished(keepAlive: Bool, context: ChannelHandlerContext) {
        isBusy = false
        if keepAlive {
            processQueue(context: context)
        } else {
            context.close(promise: nil)
        }
    }

    private func resolveURL(for head: HTTPRequestHead) -> URL? {
        if head.uri.hasPrefix("http://") || head.uri.hasPrefix("https://") {
            return URL(string: head.uri)
        }
        guard let tunnel else { return nil }
        let portSuffix = tunnel.port == 443 ? "" : ":\(tunnel.port)"
        return URL(string: "https://\(tunnel.host)\(portSuffix)\(head.uri)")
    }

    private func handle(_ request: BufferedRequest, context: ChannelHandlerContext) {
        let keepAlive = request.head.isKeepAlive
        guard let url = resolveURL(for: request.head), !identity.isSelf(url) else {
            serveLocalPage(for: request.head, keepAlive: keepAlive, context: context)
            return
        }

        let headers = request.head.headers.map { HTTPHeaderField(name: $0.name, value: $0.value) }
        let body = Data(request.body.readableBytesView)
        let transaction = Transaction(
            id: UUID(),
            startedAt: Date(),
            method: request.head.method.rawValue,
            url: url.absoluteString,
            host: url.host ?? "",
            path: url.path.isEmpty ? "/" : url.path + (url.query.map { "?\($0)" } ?? ""),
            requestHeaders: headers,
            requestBody: body
        )
        recorder.transactionDidStart(transaction)

        let isHead = request.head.method == .HEAD
        let loop = context.eventLoop
        Task { [upstream, recorder] in
            do {
                let response = try await upstream.send(method: transaction.method, url: url, headers: headers, body: body)
                let duration = Date().timeIntervalSince(transaction.startedAt)
                recorder.transactionDidComplete(
                    id: transaction.id,
                    statusCode: response.statusCode,
                    headers: response.headers,
                    body: response.body,
                    duration: duration
                )
                loop.execute { self.writeUpstreamResponse(response, isHead: isHead, keepAlive: keepAlive, context: context) }
            } catch {
                let duration = Date().timeIntervalSince(transaction.startedAt)
                recorder.transactionDidFail(id: transaction.id, message: error.localizedDescription, duration: duration)
                loop.execute {
                    self.writeSimpleResponse(status: .badGateway, body: "Network Monitor: \(error.localizedDescription)", keepAlive: keepAlive, context: context)
                }
            }
        }
    }

    // MARK: - Responses

    private func writeUpstreamResponse(_ response: UpstreamResponse, isHead: Bool, keepAlive: Bool, context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        for field in response.headers where !Self.strippedResponseHeaders.contains(field.name.lowercased()) {
            headers.add(name: field.name, value: field.value)
        }
        let status = HTTPResponseStatus(statusCode: response.statusCode)
        let hasBody = !isHead && status.mayHaveResponseBody
        if hasBody {
            headers.replaceOrAdd(name: "Content-Length", value: "\(response.body.count)")
        } else if isHead {
            headers.replaceOrAdd(name: "Content-Length", value: response.headers.value(for: "Content-Length") ?? "0")
        }
        headers.replaceOrAdd(name: "Connection", value: keepAlive ? "keep-alive" : "close")

        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
        if hasBody, !response.body.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: response.body.count)
            buffer.writeBytes(response.body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        writeEnd(keepAlive: keepAlive, context: context)
    }

    private func writeSimpleResponse(status: HTTPResponseStatus, body: String, keepAlive: Bool, context: ChannelHandlerContext) {
        writeResponse(status: status, contentType: "text/plain; charset=utf-8", body: Array(body.utf8), extraHeaders: [], keepAlive: keepAlive, context: context)
    }

    private func writeResponse(
        status: HTTPResponseStatus,
        contentType: String,
        body: [UInt8],
        extraHeaders: [(String, String)],
        keepAlive: Bool,
        context: ChannelHandlerContext
    ) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: "\(body.count)")
        headers.add(name: "Connection", value: keepAlive ? "keep-alive" : "close")
        for (name, value) in extraHeaders {
            headers.add(name: name, value: value)
        }
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: body.count)
        buffer.writeBytes(body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        writeEnd(keepAlive: keepAlive, context: context)
    }

    private func writeEnd(keepAlive: Bool, context: ChannelHandlerContext) {
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { [self] _ in
            requestFinished(keepAlive: keepAlive, context: context)
        }
    }

    // MARK: - Setup pages served by the proxy itself

    private func serveLocalPage(for head: HTTPRequestHead, keepAlive: Bool, context: ChannelHandlerContext) {
        var path = head.uri
        if let range = path.range(of: "://") {
            path = String(path[range.upperBound...])
            path = path.firstIndex(of: "/").map { String(path[$0...]) } ?? "/"
        }
        if let query = path.firstIndex(of: "?") {
            path = String(path[..<query])
        }

        switch path {
        case "/ca", "/ca.cer", "/ca.crt":
            writeResponse(
                status: .ok,
                contentType: "application/x-x509-ca-cert",
                body: authority.certificateDER,
                extraHeaders: [("Content-Disposition", "attachment; filename=\"NetworkMonitor-CA.cer\"")],
                keepAlive: keepAlive,
                context: context
            )
        case "/ca.pem":
            writeResponse(
                status: .ok,
                contentType: "application/x-pem-file",
                body: Array(authority.certificatePEM.utf8),
                extraHeaders: [("Content-Disposition", "attachment; filename=\"NetworkMonitor-CA.pem\"")],
                keepAlive: keepAlive,
                context: context
            )
        default:
            writeResponse(
                status: .ok,
                contentType: "text/html; charset=utf-8",
                body: Array(SetupPage.html.utf8),
                extraHeaders: [],
                keepAlive: keepAlive,
                context: context
            )
        }
    }
}

enum SetupPage {
    static let html = """
    <!doctype html>
    <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Network Monitor</title>
    <style>
    body{font-family:-apple-system,system-ui,sans-serif;margin:40px auto;max-width:560px;padding:0 20px;line-height:1.5;color:#1d1d1f}
    a.btn{display:inline-block;padding:12px 20px;background:#0a84ff;color:#fff;border-radius:10px;text-decoration:none;font-weight:600}
    li{margin-bottom:8px}
    </style></head>
    <body>
    <h1>Network Monitor</h1>
    <p>The proxy is running. Install its root certificate to inspect HTTPS traffic.</p>
    <p><a class="btn" href="/ca">Download CA certificate</a></p>
    <ol>
    <li>Tap the button and allow the profile download.</li>
    <li>Settings &rarr; General &rarr; VPN &amp; Device Management &rarr; install “Network Monitor Root CA”.</li>
    <li>Settings &rarr; General &rarr; About &rarr; Certificate Trust Settings &rarr; enable full trust.</li>
    </ol>
    </body></html>
    """
}
