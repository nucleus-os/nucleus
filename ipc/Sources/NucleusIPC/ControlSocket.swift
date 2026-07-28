import FoundationEssentials
import Glibc

/// Where the control socket lives.
public enum ControlSocket {
    /// Explicit override, checked first so a test or a nested session can point
    /// a client at a specific compositor.
    public static let environmentVariable = "NUCLEUS_SOCKET"

    /// `$XDG_RUNTIME_DIR/nucleus-<display>.sock`.
    ///
    /// The Wayland display name is part of the filename so two compositors on
    /// one login session do not collide — which is exactly the situation a
    /// nested or test compositor creates.
    public static func defaultPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let explicit = environment[environmentVariable], !explicit.isEmpty {
            return explicit
        }
        guard let runtimeDirectory = environment["XDG_RUNTIME_DIR"],
            !runtimeDirectory.isEmpty
        else { return nil }
        let display = environment["WAYLAND_DISPLAY"] ?? "wayland-0"
        return "\(runtimeDirectory)/nucleus-\(display).sock"
    }
}

public enum ControlClientError: Error, Equatable, Sendable {
    case noSocketPath
    case socketPathTooLong(String)
    case cannotConnect(path: String, errno: Int32)
    case transportFailed(String)
    case malformedResponse(String)

    public var message: String {
        switch self {
        case .noSocketPath:
            "no control socket path; set \(ControlSocket.environmentVariable) "
                + "or XDG_RUNTIME_DIR"
        case .socketPathTooLong(let path):
            "control socket path is too long for a unix socket: \(path)"
        case .cannotConnect(let path, let code):
            "cannot connect to \(path): \(systemMessage(code))"
        case .transportFailed(let detail):
            "control transport failed: \(detail)"
        case .malformedResponse(let detail):
            "malformed response: \(detail)"
        }
    }
}

/// A blocking, one-shot control client.
///
/// Deliberately synchronous: every caller so far is a CLI that sends one
/// request and exits, and an async client would add a concurrency model to a
/// process whose whole job is a single round trip.
public struct ControlClient: Sendable {
    private let path: String

    public init(path: String) {
        self.path = path
    }

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws(ControlClientError) {
        guard let path = ControlSocket.defaultPath(environment: environment)
        else { throw .noSocketPath }
        self.path = path
    }

    public func send(
        _ request: ControlRequest
    ) throws(ControlClientError) -> ControlResponse {
        let descriptor = try connect()
        defer { close(descriptor) }
        do {
            try writeAll(descriptor, ControlCoding.line(request))
        } catch let error as ControlClientError {
            throw error
        } catch {
            throw .transportFailed("\(error)")
        }
        let line = try readLine(descriptor)
        do {
            return try ControlCoding.decoder().decode(
                ControlResponse.self, from: line)
        } catch {
            throw .malformedResponse(
                String(decoding: line, as: UTF8.self))
        }
    }

    private func connect() throws(ControlClientError) -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        // sun_path is a fixed C array; the terminating NUL has to fit too.
        let capacity = MemoryLayout.size(ofValue: address.sun_path) - 1
        let bytes = Array(path.utf8)
        guard bytes.count <= capacity else { throw .socketPathTooLong(path) }

        let descriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard descriptor >= 0 else {
            throw .cannotConnect(path: path, errno: errno)
        }
        // Fill sun_path first and let that access end. Taking a pointer to the
        // whole address while a pointer into its sun_path is still live is an
        // exclusivity violation, not merely a style question.
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

        let result = withUnsafePointer(to: &address) {
            unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                pointer in
                unsafe Glibc.connect(
                    descriptor,
                    pointer,
                    socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(descriptor)
            throw .cannotConnect(path: path, errno: code)
        }
        return descriptor
    }

    private func writeAll(
        _ descriptor: Int32, _ data: Data
    ) throws(ControlClientError) {
        var offset = 0
        let bytes = Array(data)
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer in
                unsafe write(
                    descriptor,
                    buffer.baseAddress.map { unsafe $0 + offset },
                    bytes.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw .transportFailed(systemMessage(errno))
            }
            if written == 0 { throw .transportFailed("connection closed") }
            offset += written
        }
    }

    /// Read up to and including the first newline.
    private func readLine(
        _ descriptor: Int32
    ) throws(ControlClientError) -> Data {
        var accumulated = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = chunk.withUnsafeMutableBytes { buffer in
                unsafe read(descriptor, buffer.baseAddress, buffer.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw .transportFailed(systemMessage(errno))
            }
            if count == 0 { break }
            accumulated.append(contentsOf: chunk[0..<count])
            if let newline = accumulated.firstIndex(of: UInt8(ascii: "\n")) {
                return Data(accumulated[0..<newline])
            }
        }
        guard !accumulated.isEmpty else {
            throw .transportFailed("connection closed before a response")
        }
        return Data(accumulated)
    }
}


/// `strerror` in one place, so the unsafe C-string bridge is marked once
/// rather than at every failure site.
func systemMessage(_ code: Int32) -> String {
    unsafe String(cString: strerror(code))
}
