import ColliderCore
import ColliderPlatformC
import Dispatch
import Foundation
import Synchronization
import SystemPackage

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public final class PseudoTerminalLog: @unchecked Sendable {
    public let slavePath: String

    private struct State: Sendable {
        var stopRequested = false
        var failure: PseudoTerminalLogFailure?
    }

    private let state = Mutex(State())
    private let completion = DispatchGroup()
    private let master: Int32
    private let slave: Int32
    private let output: Int32

    public init(output path: FilePath) throws {
        var slavePathBytes = [CChar](repeating: 0, count: 4_096)
        var slave = Int32(-1)
        let master = unsafe collider_open_raw_pseudo_terminal(
            &slavePathBytes,
            slavePathBytes.count,
            &slave)
        guard master >= 0 else {
            throw PseudoTerminalLogFailure.system(
                operation: "create raw pseudo-terminal",
                code: errno)
        }
        let output: FileDescriptor
        do {
            output = try FileDescriptor.open(
                path,
                .writeOnly,
                options: [.create, .truncate, .closeOnExec],
                permissions: .ownerReadWrite)
        } catch {
            _ = close(slave)
            _ = close(master)
            throw error
        }

        let pathEnd =
            slavePathBytes.firstIndex(of: 0) ?? slavePathBytes.endIndex
        self.slavePath = String(
            decoding: slavePathBytes[..<pathEnd].map {
                UInt8(bitPattern: $0)
            },
            as: UTF8.self)
        self.master = master
        self.slave = slave
        self.output = output.rawValue
        completion.enter()
        DispatchQueue(
            label: "org.nucleus.collider.pseudo-terminal-log",
            qos: .utility
        ).async { [self] in
            drain()
        }
    }

    deinit {
        stop()
    }

    public func checkHealth() throws {
        if let failure = state.withLock({ $0.failure }) {
            throw failure
        }
    }

    public func stop() {
        state.withLock { $0.stopRequested = true }
        completion.wait()
    }

    private func drain() {
        defer {
            if fsync(output) != 0 {
                recordFailure(
                    operation: "synchronize pseudo-terminal log",
                    code: errno)
            }
            if close(output) != 0 {
                recordFailure(
                    operation: "close pseudo-terminal log",
                    code: errno)
            }
            if close(slave) != 0 {
                recordFailure(
                    operation: "close pseudo-terminal slave",
                    code: errno)
            }
            if close(master) != 0 {
                recordFailure(
                    operation: "close pseudo-terminal master",
                    code: errno)
            }
            completion.leave()
        }

        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                unsafe read(master, $0.baseAddress, $0.count)
            }
            if count > 0 {
                guard writeAll(buffer[..<count]) else {
                    return
                }
                continue
            }
            if state.withLock({ $0.stopRequested }),
                count == 0 || (count < 0 && errno == EIO)
            {
                return
            }
            if count < 0,
                errno != EAGAIN,
                errno != EWOULDBLOCK,
                errno != EIO,
                errno != EINTR
            {
                recordFailure(
                    operation: "read pseudo-terminal master",
                    code: errno)
                return
            }

            var descriptor = pollfd(
                fd: master,
                events: Int16(POLLIN),
                revents: 0)
            let timeout = state.withLock({ $0.stopRequested }) ? 20 : 100
            let result = unsafe poll(&descriptor, 1, Int32(timeout))
            if result < 0 && errno != EINTR {
                recordFailure(
                    operation: "poll pseudo-terminal master",
                    code: errno)
                return
            }
            if state.withLock({ $0.stopRequested }),
                result <= 0 || descriptor.revents & Int16(POLLIN) == 0
            {
                return
            }
            if result > 0,
                descriptor.revents & Int16(POLLIN) == 0
            {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }

    private func writeAll(_ bytes: ArraySlice<UInt8>) -> Bool {
        CredentialScrubber.bytes(Array(bytes)).withUnsafeBytes { rawBytes in
            var written = 0
            while written < rawBytes.count {
                let count = unsafe write(
                    output,
                    rawBytes.baseAddress!.advanced(by: written),
                    rawBytes.count - written)
                if count > 0 {
                    written += count
                    continue
                }
                if count < 0 && errno == EINTR {
                    continue
                }
                recordFailure(
                    operation: "write pseudo-terminal log",
                    code: errno)
                return false
            }
            return true
        }
    }

    private func recordFailure(operation: String, code: Int32) {
        state.withLock {
            if $0.failure == nil {
                $0.failure = .system(operation: operation, code: code)
            }
        }
    }
}

public enum PseudoTerminalLogFailure:
    Error,
    CustomStringConvertible,
    Equatable,
    Sendable
{
    case system(operation: String, code: Int32)

    public var description: String {
        switch self {
        case .system(let operation, let code):
            "\(operation) failed with errno \(code)"
        }
    }
}
