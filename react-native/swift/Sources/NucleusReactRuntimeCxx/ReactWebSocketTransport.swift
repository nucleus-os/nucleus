import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket
import NucleusReactRuntimeCxxBridge
import Synchronization

extension ReactNetworkTransport {
    func createWebSocket(
        callbacks: nucleus.react.NetworkWebSocketCallbacks
    ) -> nucleus.react.NetworkWebSocket {
        let socket = unsafe ReactWebSocket(
            eventLoopGroup: MultiThreadedEventLoopGroup.singleton,
            callbacks: callbacks
        )
        return unsafe nucleus.react.NetworkWebSocket(
            .init { [socket] url in socket.connect(url: String(url)) },
            .init { [socket] text in socket.send(text: String(text)) },
            .init { [socket] in socket.ping() },
            .init { [socket] reason in socket.close(reason: String(reason)) }
        )
    }
}

@safe private final class ReactWebSocket: @unchecked Sendable {
    private static let maximumMessageBytes = 16 * 1024 * 1024

    private struct State {
        var channel: Channel?
        var closeRequested = false
        var closeReported = false
        var fragmentedText: ByteBuffer?
    }

    private let eventLoopGroup: MultiThreadedEventLoopGroup
    private let callbacks: nucleus.react.NetworkWebSocketCallbacks
    private let state = Mutex(State())

    init(
        eventLoopGroup: MultiThreadedEventLoopGroup,
        callbacks: consuming nucleus.react.NetworkWebSocketCallbacks
    ) {
        self.eventLoopGroup = eventLoopGroup
        unsafe self.callbacks = callbacks
    }

    deinit {
        close(reason: "runtime shutdown")
    }

    func connect(url value: String) {
        guard
            let url = URL(string: value),
            let scheme = url.scheme?.lowercased(),
            scheme == "ws" || scheme == "wss",
            let host = url.host
        else {
            reportConnection(false, error: "invalid WebSocket URL")
            return
        }

        let secure = scheme == "wss"
        let port = url.port ?? (secure ? 443 : 80)
        let path = url.path.isEmpty ? "/" : url.path
        let uri = url.query.map { "\(path)?\($0)" } ?? path
        let inbound = ReactWebSocketInboundHandler(socket: self)
        let requestHandler = WebSocketUpgradeRequestHandler(
            host: host,
            port: port,
            secure: secure,
            uri: uri,
            failure: { [weak self] error in
                self?.reportConnection(false, error: error)
            }
        )
        let upgrader = NIOWebSocketClientUpgrader(
            upgradePipelineHandler: { [socket = self] channel, _ in
                channel.pipeline.addHandler(inbound).map {
                    socket.didUpgrade(channel)
                }
            }
        )
        let upgradeConfiguration: NIOHTTPClientUpgradeSendableConfiguration = (
            upgraders: [upgrader],
            completionHandler: { context in
                context.pipeline.removeHandler(requestHandler, promise: nil)
            }
        )

        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .channelInitializer { channel in
                if secure {
                    do {
                        let configuration = TLSConfiguration.makeClientConfiguration()
                        let context = try NIOSSLContext(configuration: configuration)
                        let handler = try NIOSSLClientHandler(
                            context: context,
                            serverHostname: host
                        )
                        try channel.pipeline.syncOperations.addHandler(handler)
                        return channel.pipeline.addHTTPClientHandlers(
                            withClientUpgrade: upgradeConfiguration
                        ).flatMap {
                            channel.pipeline.addHandler(requestHandler)
                        }
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
                return channel.pipeline.addHTTPClientHandlers(
                    withClientUpgrade: upgradeConfiguration
                ).flatMap {
                    channel.pipeline.addHandler(requestHandler)
                }
            }

        bootstrap.connect(host: host, port: port).whenFailure { [weak self] error in
            self?.reportConnection(false, error: String(describing: error))
        }
    }

    func send(text: String) {
        guard let channel = state.withLock({ $0.channel }) else { return }
        let frame = WebSocketFrame(
            fin: true,
            opcode: .text,
            data: channel.allocator.buffer(string: text)
        )
        channel.writeAndFlush(frame, promise: nil)
    }

    func ping() {
        guard let channel = state.withLock({ $0.channel }) else { return }
        let frame = WebSocketFrame(
            fin: true,
            opcode: .ping,
            data: channel.allocator.buffer(capacity: 0)
        )
        channel.writeAndFlush(frame, promise: nil)
    }

    func close(reason: String) {
        let channel = state.withLock { state -> Channel? in
            guard !state.closeRequested else { return nil }
            state.closeRequested = true
            return state.channel
        }
        guard let channel else { return }
        var data = channel.allocator.buffer(capacity: 2 + reason.utf8.count)
        data.writeInteger(UInt16(1000), endianness: .big)
        data.writeString(reason)
        channel.writeAndFlush(
            WebSocketFrame(fin: true, opcode: .connectionClose, data: data)
        ).flatMap {
            channel.close()
        }.whenFailure { _ in
            channel.close(promise: nil)
        }
    }

    fileprivate func didReceive(_ frame: WebSocketFrame, context: ChannelHandlerContext) {
        switch frame.opcode {
        case .text:
            if frame.fin {
                deliverText(frame.data, context: context)
            } else {
                let accepted = state.withLock { state -> Bool in
                    guard state.fragmentedText == nil,
                        frame.data.readableBytes <= Self.maximumMessageBytes
                    else { return false }
                    state.fragmentedText = frame.data
                    return true
                }
                if !accepted {
                    closeProtocolError(context: context)
                }
            }
        case .continuation:
            let continuation = state.withLock { state -> (valid: Bool, message: ByteBuffer?) in
                guard var accumulated = state.fragmentedText else {
                    return (false, nil)
                }
                var fragment = frame.data
                guard
                    accumulated.readableBytes + fragment.readableBytes
                        <= Self.maximumMessageBytes
                else {
                    state.fragmentedText = nil
                    return (false, nil)
                }
                accumulated.writeBuffer(&fragment)
                if frame.fin {
                    state.fragmentedText = nil
                    return (true, accumulated)
                }
                state.fragmentedText = accumulated
                return (true, nil)
            }
            guard continuation.valid else {
                closeProtocolError(context: context)
                return
            }
            if let message = continuation.message {
                deliverText(message, context: context)
            }
        case .ping:
            context.writeAndFlush(
                NIOAny(WebSocketFrame(fin: true, opcode: .pong, data: frame.data)),
                promise: nil
            )
        case .connectionClose:
            context.close(promise: nil)
        case .binary, .pong:
            break
        default:
            context.close(promise: nil)
        }
    }

    private func deliverText(_ data: ByteBuffer, context: ChannelHandlerContext) {
        guard data.readableBytes <= Self.maximumMessageBytes else {
            closeProtocolError(context: context)
            return
        }
        var data = data
        let bytes = data.readBytes(length: data.readableBytes) ?? []
        guard let text = String(bytes: bytes, encoding: .utf8) else {
            closeProtocolError(context: context)
            return
        }
        unsafe callbacks.didReceiveText(std.string(text))
    }

    private func closeProtocolError(context: ChannelHandlerContext) {
        let channel = context.channel
        var data = channel.allocator.buffer(capacity: 2)
        data.writeInteger(UInt16(1002), endianness: .big)
        context.writeAndFlush(
            NIOAny(WebSocketFrame(fin: true, opcode: .connectionClose, data: data))
        ).flatMap {
            channel.close()
        }.whenFailure { _ in
            channel.close(promise: nil)
        }
    }

    fileprivate func didClose(reason: String) {
        let report = state.withLock { state -> Bool in
            guard !state.closeReported else { return false }
            state.closeReported = true
            state.channel = nil
            return true
        }
        guard report else { return }
        unsafe callbacks.didClose(std.string(reason))
    }

    private func didUpgrade(_ channel: Channel) {
        let closeImmediately = state.withLock { state -> Bool in
            if state.closeRequested { return true }
            state.channel = channel
            return false
        }
        if closeImmediately {
            channel.close(promise: nil)
        } else {
            reportConnection(true, error: "")
        }
    }

    private func reportConnection(_ connected: Bool, error: String) {
        unsafe callbacks.didConnect(connected, std.string(error))
    }
}

private final class ReactWebSocketInboundHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame

    private weak var socket: ReactWebSocket?

    init(socket: ReactWebSocket) {
        self.socket = socket
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        socket?.didReceive(unwrapInboundIn(data), context: context)
    }

    func channelInactive(context: ChannelHandlerContext) {
        socket?.didClose(reason: "connection closed")
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        socket?.didClose(reason: String(describing: error))
        context.close(promise: nil)
    }
}

private final class WebSocketUpgradeRequestHandler:
    ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable
{
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let host: String
    private let port: Int
    private let secure: Bool
    private let uri: String
    private let failure: @Sendable (String) -> Void

    init(
        host: String,
        port: Int,
        secure: Bool,
        uri: String,
        failure: @escaping @Sendable (String) -> Void
    ) {
        self.host = host
        self.port = port
        self.secure = secure
        self.uri = uri
        self.failure = failure
    }

    func channelActive(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        let defaultPort = secure ? 443 : 80
        headers.add(name: "Host", value: port == defaultPort ? host : "\(host):\(port)")
        headers.add(name: "Content-Length", value: "0")
        let head = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: uri,
            headers: headers
        )
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .head(let head) = unwrapInboundIn(data) {
            failure("WebSocket upgrade rejected with HTTP \(head.status.code)")
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failure(String(describing: error))
        context.close(promise: nil)
    }
}
