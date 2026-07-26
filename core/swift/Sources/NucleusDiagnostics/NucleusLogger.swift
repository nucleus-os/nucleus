import Synchronization

#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(Darwin)
import Darwin
#endif

public enum NucleusLogLevel: String, Sendable {
    case debug
    case info
    case warning
    case error
}

/// Process-wide destination for first-party diagnostics.
///
/// The descriptor is borrowed. Its owner must keep it open until another
/// descriptor is installed or `resetToStandardError()` is called.
public enum NucleusLogging {
    private static let destination = Mutex<Int32>(2)

    public static func redirect(toFileDescriptor descriptor: Int32) {
        precondition(descriptor >= 0, "log destination must be a valid file descriptor")
        destination.withLock { $0 = descriptor }
    }

    public static func resetToStandardError() {
        destination.withLock { $0 = 2 }
    }

    fileprivate static func emit(
        level: NucleusLogLevel,
        subsystem: String,
        message: String
    ) {
        let line = "[nucleus][\(level.rawValue)][\(subsystem)] \(message)\n"
        let bytes = Array(line.utf8)
        destination.withLock { descriptor in
            bytes.withUnsafeBytes { buffer in
                guard var cursor = buffer.baseAddress else { return }
                var remaining = buffer.count
                while remaining > 0 {
                    let written = unsafe write(descriptor, cursor, remaining)
                    if written > 0 {
                        unsafe cursor = unsafe cursor.advanced(by: written)
                        remaining -= written
                    } else if written < 0 && errno == EINTR {
                        continue
                    } else {
                        return
                    }
                }
            }
        }
    }
}

public struct NucleusLogger: Sendable {
    public let subsystem: String

    public init(subsystem: String) {
        precondition(!subsystem.isEmpty, "log subsystem must not be empty")
        self.subsystem = subsystem
    }

    public func debug(_ message: String) {
        NucleusLogging.emit(level: .debug, subsystem: subsystem, message: message)
    }

    public func info(_ message: String) {
        NucleusLogging.emit(level: .info, subsystem: subsystem, message: message)
    }

    public func warning(_ message: String) {
        NucleusLogging.emit(level: .warning, subsystem: subsystem, message: message)
    }

    public func error(_ message: String) {
        NucleusLogging.emit(level: .error, subsystem: subsystem, message: message)
    }
}
