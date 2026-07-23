import Dispatch
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public actor RuntimeCancellation {
    private var nextID: UInt64 = 0
    private var handlers: [UInt64: @Sendable () -> Void] = [:]
    private var processGroups: [UInt64: Int32] = [:]
    private var interrupted = false

    public init() {}

    func register(_ handler: @escaping @Sendable () -> Void) -> UInt64 {
        let id = nextID
        nextID &+= 1
        handlers[id] = handler
        return id
    }

    func unregister(_ id: UInt64) { handlers[id] = nil }

    func registerProcessGroup(_ processGroup: Int32) -> UInt64 {
        let id = nextID
        nextID &+= 1
        processGroups[id] = processGroup
        return id
    }

    func unregisterProcessGroup(_ id: UInt64) { processGroups[id] = nil }

    func hasActiveProcessGroups() -> Bool { !processGroups.isEmpty }

    @discardableResult
    public func forward(signal number: Int32) -> SignalForwardingResult {
        #if !os(Windows)
        var failures: [Int32: Int32] = [:]
        for processGroup in processGroups.values {
            if kill(-processGroup, number) != 0 { failures[processGroup] = errno }
        }
        return SignalForwardingResult(
            attemptedProcessGroups: processGroups.count,
            failures: failures)
        #else
        _ = number
        return SignalForwardingResult(
            attemptedProcessGroups: 0,
            failures: [:])
        #endif
    }

    public func cancelAll() {
        for handler in handlers.values { handler() }
    }

    public func interruptAll() {
        interrupted = true
        cancelAll()
    }

    public func wasInterrupted() -> Bool { interrupted }
}

public struct SignalForwardingResult: Sendable {
    public let attemptedProcessGroups: Int
    public let failures: [Int32: Int32]
}

public final class RuntimeSignalHandlers: @unchecked Sendable {
    private let sources: [DispatchSourceSignal]

    public init(cancellation: RuntimeCancellation) {
        var sources: [DispatchSourceSignal] = []
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: number,
                queue: .global(qos: .userInitiated))
            source.setEventHandler {
                Task {
                    await cancellation.forward(signal: number)
                    await cancellation.interruptAll()
                }
            }
            source.resume()
            sources.append(source)
        }
        for number in [SIGCONT, SIGWINCH] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: number,
                queue: .global(qos: .userInitiated))
            source.setEventHandler {
                Task { await cancellation.forward(signal: number) }
            }
            source.resume()
            sources.append(source)
        }
        signal(SIGTSTP, SIG_IGN)
        let suspendSource = DispatchSource.makeSignalSource(
            signal: SIGTSTP,
            queue: .global(qos: .userInitiated))
        suspendSource.setEventHandler {
            Task {
                await cancellation.forward(signal: SIGTSTP)
                _ = kill(getpid(), SIGSTOP)
            }
        }
        suspendSource.resume()
        sources.append(suspendSource)
        self.sources = sources
    }

    public func cancel() {
        for source in sources { source.cancel() }
    }

    deinit { cancel() }
}
