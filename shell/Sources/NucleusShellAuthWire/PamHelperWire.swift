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
    public static let maximumServiceBytes = 128

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
        withUnsafeBytes(of: length.littleEndian) { buffer.append(contentsOf: $0) }
        buffer.append(contentsOf: bytes)
    }

    public static func encodeField(_ bytes: [UInt8], into buffer: inout [UInt8]) {
        bytes.withUnsafeBytes { encodeField($0, into: &buffer) }
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
                return read(fd, base.advanced(by: filled), count - filled)
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
                return write(fd, base.advanced(by: written), bytes.count - written)
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
        let value = raw.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let length = Int(UInt32(littleEndian: value))
        guard length <= limit else { return nil }
        return length
    }
}
