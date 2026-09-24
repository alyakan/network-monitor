import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

final class ProxyServer: @unchecked Sendable {
    private let authority: CertificateAuthority
    private let recorder: TransactionRecorder
    private let upstream = UpstreamClient()
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?

    init(authority: CertificateAuthority, recorder: TransactionRecorder) {
        self.authority = authority
        self.recorder = recorder
    }

    func start(identity: ProxyIdentity) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        self.group = group
        let authority = authority
        let recorder = recorder
        let upstream = upstream

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let operations = channel.pipeline.syncOperations
                    try operations.addHandler(ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)))
                    try operations.addHandler(HTTPResponseEncoder())
                    try operations.addHandler(ProxyHandler(authority: authority, upstream: upstream, recorder: recorder, identity: identity))
                }
            }

        do {
            channel = try await bootstrap.bind(host: "0.0.0.0", port: identity.port).get()
        } catch {
            try? await group.shutdownGracefully()
            self.group = nil
            throw error
        }
    }

    func stop() async {
        try? await channel?.close().get()
        channel = nil
        try? await group?.shutdownGracefully()
        group = nil
    }
}
