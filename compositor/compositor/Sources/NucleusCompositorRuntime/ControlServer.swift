// ControlServer — the compositor side of the control socket.
//
// Connections are served synchronously inside `process()`: accept, read one
// request, answer, close. A control exchange is a single small line, so
// tracking per-connection state across reactor turns would buy nothing and cost
// a state machine. The bound is enforced rather than assumed — the accepted
// socket carries send and receive timeouts, so a client that connects and then
// stalls cannot hold the compositor's main actor.

import FoundationEssentials
import Glibc
import NucleusIPC
import NucleusLinuxReactor

@MainActor
protocol ControlRequestHandler: AnyObject {
    func handle(_ request: ControlRequest) -> ControlResponse
}

@MainActor
@safe final class ControlServer: LinuxReactorSource {
    /// How long a connected client may take to send its request or receive its
    /// answer before it is abandoned.
    ///
    /// This is a hard bound on how long one misbehaving client can hold the
    /// compositor's main actor, so it is deliberately far shorter than a
    /// network timeout would be: a local unix-socket peer writes one small line
    /// in a single call, and anything slower than this is not worth a stutter.
    private static let exchangeTimeoutMilliseconds: Int = 100
    private static let maximumRequestBytes = 64 * 1024

    private let listener: Int32
    private let path: String
    private unowned let handler: any ControlRequestHandler

    /// Bind and listen. Returns nil when no path is resolvable or the socket
    /// cannot be created; the compositor runs without a control socket rather
    /// than refusing to start, because losing remote control is not worth
    /// losing the session.
    init?(handler: any ControlRequestHandler, path: String? = ControlSocket.defaultPath()) {
        guard let path else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path) - 1
        let bytes = Array(path.utf8)
        guard bytes.count <= capacity else { return nil }

        // A socket left by a crashed compositor would make bind fail with
        // EADDRINUSE forever; removing it first is what makes restart work.
        _ = unsafe unlink(path)

        // NONBLOCK is load-bearing: `process()` drains by calling accept until
        // it fails, and on a blocking listener that final call would never
        // return, wedging the compositor's main actor on the first connection.
        // CLOEXEC keeps the listener out of applications the launcher spawns.
        let descriptor = socket(
            AF_UNIX,
            Int32(SOCK_STREAM.rawValue) | Int32(SOCK_NONBLOCK.rawValue)
                | Int32(SOCK_CLOEXEC.rawValue),
            0)
        guard descriptor >= 0 else { return nil }
        withUnsafeMutablePointer(to: &address.sun_path) {
            unsafe $0.withMemoryRebound(
                to: UInt8.self, capacity: capacity + 1
            ) { destination in
                for index in bytes.indices {
                    unsafe destination[index] = bytes[index]
                }
                unsafe destination[bytes.count] = 0
            }
        }
        let bound = withUnsafePointer(to: &address) {
            unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                unsafe bind(
                    descriptor, $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else {
            close(descriptor)
            return nil
        }
        // Owner-only: the control socket performs privileged session actions,
        // and XDG_RUNTIME_DIR is per-user but not necessarily per-session.
        _ = unsafe chmod(path, 0o600)
        self.listener = descriptor
        self.path = path
        self.handler = handler
    }

    isolated deinit {
        close(listener)
        _ = unsafe unlink(path)
    }

    var socketPath: String { path }

    // MARK: LinuxReactorSource

    var fileDescriptor: Int32 { listener }
    var pollEvents: Int16 { Int16(POLLIN) }
    func timeoutMicroseconds() -> UInt64? { nil }

    @discardableResult
    func process() -> Bool {
        var served = false
        // Drain every pending connection: the listener is registered one-shot,
        // so a connection left queued would wait for the next unrelated wake.
        while true {
            let connection = accept(listener, nil, nil)
            if connection < 0 {
                // EAGAIN is the drained case and the loop's only exit; EINTR
                // is a signal, not an empty queue, so it retries.
                if errno == EINTR { continue }
                break
            }
            serve(connection)
            close(connection)
            served = true
        }
        return served
    }

    func transportDidFail(operation: String) {
        logRuntime("control: \(operation)")
    }

    // MARK: one exchange

    private func serve(_ connection: Int32) {
        applyTimeouts(connection)
        guard let line = readRequestLine(connection) else { return }
        let response: ControlResponse
        do {
            let request = try ControlCoding.decoder().decode(
                ControlRequest.self, from: Data(line))
            response = handler.handle(request)
        } catch {
            response = .error("could not decode request")
        }
        guard let reply = try? ControlCoding.line(response) else { return }
        writeAll(connection, Array(reply))
    }

    /// Bound the accepted socket. An accepted descriptor does not inherit the
    /// listener's O_NONBLOCK on Linux, so these timeouts are what keep a
    /// connected-then-silent client from stalling the main actor.
    private func applyTimeouts(_ connection: Int32) {
        var timeout = timeval(
            tv_sec: 0,
            tv_usec: suseconds_t(Self.exchangeTimeoutMilliseconds * 1000))
        for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
            _ = withUnsafePointer(to: &timeout) {
                unsafe setsockopt(
                    connection, SOL_SOCKET, option, $0,
                    socklen_t(MemoryLayout<timeval>.size))
            }
        }
    }

    private func readRequestLine(_ connection: Int32) -> [UInt8]? {
        var accumulated = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while accumulated.count <= Self.maximumRequestBytes {
            let count = chunk.withUnsafeMutableBytes { buffer in
                unsafe read(connection, buffer.baseAddress, buffer.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { break }
            accumulated.append(contentsOf: chunk[0..<count])
            if let newline = accumulated.firstIndex(of: UInt8(ascii: "\n")) {
                return Array(accumulated[0..<newline])
            }
        }
        // No newline within the bound, or the peer hung up mid-line. An
        // unterminated request is not a request.
        return nil
    }

    private func writeAll(_ connection: Int32, _ bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer in
                unsafe write(
                    connection,
                    buffer.baseAddress.map { unsafe $0 + offset },
                    bytes.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                return
            }
            if written == 0 { return }
            offset += written
        }
    }
}
