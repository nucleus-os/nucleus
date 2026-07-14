// Reusable in-process Wayland test client: the parity-fixture gate. It drives a
// libwayland-backed server over a socketpair (the server side becomes a wl_client
// on the display; no libwayland-client is linked), builds raw request wire bytes,
// pumps the server's event loop, and decodes the events the server flushes back.
//
// Fixtures built on this assert OBSERVABLE protocol behaviour at the wire level —
// independent of whether the server is the pure-Zig implementation or the
// libwayland-backed Swift router — so the same fixture gates the swap on both
// sides.

import Glibc
import WaylandWireTestC
import WaylandServerC
import WaylandServer
@testable import NucleusCompositorWaylandRuntime

// SOCK_NONBLOCK == O_NONBLOCK on Linux; OR'd into socketpair's type so reads on
// the test side never block when the server has no more to say.
private let nonblock: Int32 = 0o4000

/// Builds Wayland wire bytes for the client→server direction. Argument order and
/// types are the fixture's responsibility (it knows the protocol); this only
/// handles framing, little-endian words, and 32-bit string/array padding.
struct WireBuilder {
    private(set) var bytes: [UInt8] = []

    mutating func uint(_ v: UInt32) { append32(v) }
    mutating func int(_ v: Int32) { append32(UInt32(bitPattern: v)) }
    mutating func object(_ v: UInt32) { append32(v) }
    mutating func newId(_ v: UInt32) { append32(v) }

    mutating func string(_ s: String) {
        let utf8 = Array(s.utf8)
        let len = utf8.count + 1  // wayland string length includes the NUL
        append32(UInt32(len))
        bytes.append(contentsOf: utf8)
        bytes.append(0)
        let pad = (4 - (len % 4)) % 4
        for _ in 0..<pad { bytes.append(0) }
    }

    mutating func array(_ data: [UInt8]) {
        append32(UInt32(data.count))
        bytes.append(contentsOf: data)
        let pad = (4 - (data.count % 4)) % 4
        for _ in 0..<pad { bytes.append(0) }
    }

    /// Frame one request: object id, then `(size << 16) | opcode`, then the
    /// payload built by `build`. Appends to the running stream so a fixture can
    /// queue several requests and send them in one write.
    mutating func message(object: UInt32, opcode: UInt16, _ build: (inout WireBuilder) -> Void) {
        var payload = WireBuilder()
        build(&payload)
        let size = UInt32(8 + payload.bytes.count)
        append32(object)
        append32((size << 16) | UInt32(opcode))
        bytes.append(contentsOf: payload.bytes)
    }

    private mutating func append32(_ v: UInt32) {
        bytes.append(UInt8(v & 0xff))
        bytes.append(UInt8((v >> 8) & 0xff))
        bytes.append(UInt8((v >> 16) & 0xff))
        bytes.append(UInt8((v >> 24) & 0xff))
    }
}

/// One decoded event message read off the client socket. `body` is the argument
/// payload after the 8-byte header; accessors read individual args by offset.
struct WireMessage {
    let objectId: UInt32
    let opcode: UInt16
    let body: [UInt8]

    func u32(_ offset: Int) -> UInt32 {
        UInt32(body[offset]) | (UInt32(body[offset + 1]) << 8)
            | (UInt32(body[offset + 2]) << 16) | (UInt32(body[offset + 3]) << 24)
    }
    func i32(_ offset: Int) -> Int32 { Int32(bitPattern: u32(offset)) }

    func string(_ offset: Int) -> String? {
        let len = Int(u32(offset))
        guard len > 0, offset + 4 + len <= body.count else { return nil }
        let chars = body[(offset + 4)..<(offset + 4 + len - 1)]  // drop trailing NUL
        return String(decoding: chars, as: UTF8.self)
    }

    /// Split a byte stream into messages by their framed size.
    static func parse(_ bytes: [UInt8]) -> [WireMessage] {
        func word(_ o: Int) -> UInt32 {
            UInt32(bytes[o]) | (UInt32(bytes[o + 1]) << 8)
                | (UInt32(bytes[o + 2]) << 16) | (UInt32(bytes[o + 3]) << 24)
        }
        var out: [WireMessage] = []
        var off = 0
        while off + 8 <= bytes.count {
            let objectId = word(off)
            let sizeOpcode = word(off + 4)
            let size = Int(sizeOpcode >> 16)
            let opcode = UInt16(sizeOpcode & 0xffff)
            if size < 8 || off + size > bytes.count { break }
            out.append(WireMessage(
                objectId: objectId, opcode: opcode,
                body: Array(bytes[(off + 8)..<(off + size)])
            ))
            off += size
        }
        return out
    }

    /// First message matching object id and opcode, or nil.
    static func first(_ messages: [WireMessage], object: UInt32, opcode: UInt16) -> WireMessage? {
        messages.first { $0.objectId == object && $0.opcode == opcode }
    }

    /// Byte offset of the argument following a 32-bit-padded string starting at
    /// `offset` — for stepping past a string to the next wire argument.
    func afterString(_ offset: Int) -> Int {
        let len = Int(u32(offset))
        let padded = ((len + 3) / 4) * 4
        return offset + 4 + padded
    }

    /// Decode a wl_registry.global event body: name(uint), interface(string),
    /// version(uint).
    func registryGlobal() -> (name: UInt32, interface: String, version: UInt32)? {
        guard let iface = string(4) else { return nil }
        let versionOffset = afterString(4)
        guard versionOffset + 4 <= body.count else { return nil }
        return (u32(0), iface, u32(versionOffset))
    }
}

final class WaylandTestClient {
    let display: WaylandDisplay
    private let testFd: Int32  // our end; the server end (sv[0]) is owned by wl_client

    init?(display: WaylandDisplay) {
        var sv: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue) | nonblock, 0, &sv) == 0 else {
            return nil
        }
        guard let client = display.createClient(fd: sv[0]) else {
            close(sv[0]); close(sv[1]); return nil
        }
        self.display = display
        _ = client // retained by the Wayland display until disconnect
        self.testFd = sv[1]
    }

    @discardableResult
    func send(_ builder: WireBuilder) -> Bool {
        let bytes = builder.bytes
        let n = bytes.withUnsafeBytes { write(testFd, $0.baseAddress, $0.count) }
        return n == bytes.count
    }

    /// Send a request stream with one ancillary file descriptor (SCM_RIGHTS) — the
    /// wire encoding for an `fd` argument (e.g. wl_shm.create_pool). The fd occupies
    /// no wire bytes; it travels in the control message.
    func send(_ builder: WireBuilder, fd: OwnedTestFD) throws {
        let bytes = builder.bytes
        guard !bytes.isEmpty else { throw WaylandWireError.emptyMessage }
        let code = bytes.withUnsafeBytes {
            swift_wayland_test_send_fd(testFd, $0.baseAddress, $0.count, fd.rawValue)
        }
        guard code == 0 else { throw WaylandWireError.systemCall("sendmsg", code) }
    }

    /// Dispatch the server's event loop until `done` holds or `maxIters` is hit.
    func pump(_ maxIters: Int = 32, until done: () -> Bool = { false }) {
        for _ in 0..<maxIters {
            display.dispatch()
            if done() { break }
        }
    }

    /// Send wl_display.get_registry and return the advertised globals parsed from
    /// the wl_registry.global events. `registryId` is the new_id minted for the
    /// registry (default 2). Consumes the registry events; later requests bind
    /// globals by the names discovered here.
    func globals(
        registryId: UInt32 = 2
    ) -> [(name: UInt32, interface: String, version: UInt32)] {
        var req = WireBuilder()
        req.message(object: 1, opcode: 1) { $0.newId(registryId) }  // wl_display.get_registry
        _ = send(req)
        pump()
        var out: [(name: UInt32, interface: String, version: UInt32)] = []
        for m in drainEvents() where m.objectId == registryId && m.opcode == 0 {
            if let g = m.registryGlobal() { out.append(g) }
        }
        return out
    }

    /// Flush server-queued events to the socket and decode everything available.
    func drainEvents() -> [WireMessage] {
        display.flushClients()
        var all: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = buf.withUnsafeMutableBytes { read(testFd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            all.append(contentsOf: buf[0..<Int(n)])
        }
        return WireMessage.parse(all)
    }

    deinit {
        close(testFd)
        display.dispatch()
    }
}

enum WaylandWireError: Error, CustomStringConvertible {
    case emptyMessage
    case sizeOverflow
    case systemCall(String, Int32)

    var description: String {
        switch self {
        case .emptyMessage: "empty Wayland wire message"
        case .sizeOverflow: "Wayland SHM allocation size overflow"
        case .systemCall(let operation, let code):
            "\(operation) failed: \(String(cString: strerror(code)))"
        }
    }
}

final class OwnedTestFD {
    let rawValue: Int32
    init(_ rawValue: Int32) { self.rawValue = rawValue }
    deinit { close(rawValue) }
}
