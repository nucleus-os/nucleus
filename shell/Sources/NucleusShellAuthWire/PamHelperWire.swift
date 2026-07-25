#if canImport(Glibc)
import Glibc
#endif

/// The wire format between the shell and its authentication helper.
///
/// Deliberately tiny and length-prefixed. It crosses a process boundary that
/// exists for isolation, so nothing here parses anything it was not told the
/// length of, and every length is bounded.
public enum PamHelperWire {
    /// A PAM message shown to the user. Bounded so a hostile or broken module
    /// cannot make the shell allocate arbitrarily.
    public static let maximumMessageBytes = 4096
    /// Bounded for the same reason. Far above any real passphrase.
    public static let maximumPasswordBytes = 1024
    public static let maximumServiceBytes = 256
    public static let responseHeaderBytes = 5
    public static let maximumResponseBytes =
        responseHeaderBytes + maximumMessageBytes

    /// What the helper concluded. The distinction between `rejected` and
    /// `unavailable` is load-bearing: a user must never be told their password
    /// was wrong when the machinery simply failed.
    public enum Outcome: UInt8, Sendable, Equatable {
        case rejected = 0
        case accepted = 1
        case unavailable = 2
    }

    /// Exit statuses. Anything else — a signal, a PAM module calling `exit`,
    /// a crash — is treated as `unavailable` by the parent, never as success.
    public static let exitAccepted: Int32 = 0
    public static let exitRejected: Int32 = 1
    public static let exitUnavailable: Int32 = 2

    // MARK: - Framing

    /// Append a length-prefixed field.
    public static func encodeField(_ bytes: UnsafeRawBufferPointer, into buffer: inout [UInt8]) {
        let length = UInt32(bytes.count)
        withUnsafeBytes(of: length.littleEndian) {
            unsafe buffer.append(contentsOf: $0)
        }
        unsafe buffer.append(contentsOf: bytes)
    }

    public static func encodeField(_ bytes: [UInt8], into buffer: inout [UInt8]) {
        bytes.withUnsafeBytes { unsafe encodeField($0, into: &buffer) }
    }

    /// Read exactly `count` bytes, retrying short reads and `EINTR`. Returns nil
    /// on EOF or error — a truncated response is never a successful one.
    public static func readExactly(_ count: Int, from fd: Int32) -> [UInt8]? {
        guard count >= 0 else { return nil }
        guard count > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return unsafe read(
                    fd, base.advanced(by: filled), count - filled)
            }
            if n > 0 {
                filled += n
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        return buffer
    }

    /// Write every byte, retrying short writes and `EINTR`.
    @discardableResult
    public static func writeAll(_ bytes: [UInt8], to fd: Int32) -> Bool {
        var written = 0
        while written < bytes.count {
            let n = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return unsafe write(
                    fd, base.advanced(by: written), bytes.count - written)
            }
            if n > 0 {
                written += n
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }

    public static func readLength(from fd: Int32, limit: Int) -> Int? {
        guard let raw = readExactly(4, from: fd) else { return nil }
        let value = raw.withUnsafeBytes {
            unsafe $0.loadUnaligned(as: UInt32.self)
        }
        let length = Int(UInt32(littleEndian: value))
        guard length <= limit else { return nil }
        return length
    }

    /// Incremental parent-side parser. It accepts arbitrary pipe fragmentation
    /// without ever reading past the one bounded response frame.
    public struct ResponseParser: Sendable {
        public enum State: Sendable, Equatable {
            case incomplete
            case complete(Outcome, String)
            case malformed
        }

        private var bytes: [UInt8] = []

        public init() {
            bytes.reserveCapacity(PamHelperWire.maximumResponseBytes)
        }

        public mutating func append(_ incoming: UnsafeRawBufferPointer) -> State {
            guard bytes.count <= PamHelperWire.maximumResponseBytes,
                  incoming.count <= PamHelperWire.maximumResponseBytes - bytes.count
            else { return .malformed }
            unsafe bytes.append(contentsOf: incoming)
            return state(eof: false)
        }

        public mutating func append(_ incoming: [UInt8]) -> State {
            incoming.withUnsafeBytes { unsafe append($0) }
        }

        public func state(eof: Bool) -> State {
            guard bytes.count >= responseHeaderBytes else {
                return eof ? .malformed : .incomplete
            }
            guard let outcome = Outcome(rawValue: bytes[0]) else {
                return .malformed
            }
            let length = bytes[1..<5].withUnsafeBytes {
                unsafe Int(UInt32(
                    littleEndian: $0.loadUnaligned(as: UInt32.self)))
            }
            guard length <= maximumMessageBytes else { return .malformed }
            let expected = responseHeaderBytes + length
            guard bytes.count <= expected else { return .malformed }
            guard bytes.count == expected else {
                return eof ? .malformed : .incomplete
            }
            return .complete(
                outcome,
                String(decoding: bytes[responseHeaderBytes..<expected], as: UTF8.self))
        }
    }
}
