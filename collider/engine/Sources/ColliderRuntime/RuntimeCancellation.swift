import Dispatch
import Synchronization

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
    private var interruptionSignal: Int32?

    /// The same process groups, reachable without suspending.
    ///
    /// A signal handler has to forward before it returns. Reaching an actor
    /// means scheduling a task and awaiting it, and the interval between the
    /// signal arriving and that task running is exactly the interval in which
    /// the process may be killed outright -- so the one action that must happen
    /// before death was the one deferred past it. A cancelled build left its
    /// children running for this reason: they are placed in their own process
    /// group, which is what keeps a signal aimed at this process from reaching
    /// them, and the forwarding that was supposed to reach them never ran.
    private let immediateState = Mutex(ImmediateState())

    private struct ImmediateState {
        var processGroups: [UInt64: Int32] = [:]
        var interrupted = false
    }

    public init() {}

    package func register(_ handler: @escaping @Sendable () -> Void) -> UInt64 {
        let id = nextID
        nextID &+= 1
        if interrupted {
            handler()
        } else {
            handlers[id] = handler
        }
        return id
    }

    package func unregister(_ id: UInt64) { handlers[id] = nil }

    func registerProcessGroup(_ processGroup: Int32) -> UInt64 {
        let id = nextID
        nextID &+= 1
        processGroups[id] = processGroup
        immediateState.withLock { $0.processGroups[id] = processGroup }
        return id
    }

    func unregisterProcessGroup(_ id: UInt64) {
        processGroups[id] = nil
        immediateState.withLock { $0.processGroups[id] = nil }
    }

    /// Signals every live process group without suspending, for a caller that
    /// may not survive long enough to await.
    ///
    /// It escalates on its own rather than reading the actor's record of having
    /// been interrupted, because reading that would suspend and the escalation
    /// exists for the case where a first signal was not enough.
    public nonisolated func forwardImmediately(
        signal number: Int32
    ) -> SignalForwardingResult {
        #if !os(Windows)
        let (groups, escalate) = immediateState.withLock {
            state -> ([Int32], Bool) in
            let escalate = state.interrupted
            state.interrupted = true
            return (Array(state.processGroups.values), escalate)
        }
        let delivered = escalate ? SIGKILL : number
        var failures: [Int32: Int32] = [:]
        for processGroup in groups {
            if kill(-processGroup, delivered) != 0 { failures[processGroup] = errno }
        }
        return SignalForwardingResult(
            signal: delivered,
            attemptedProcessGroups: groups.count,
            failures: failures)
        #else
        _ = number
        return SignalForwardingResult(
            signal: number,
            attemptedProcessGroups: 0,
            failures: [:])
        #endif
    }

    func hasActiveProcessGroups() -> Bool { !processGroups.isEmpty }

    @discardableResult
    public func forward(signal number: Int32) -> SignalForwardingResult {
        #if !os(Windows)
        var failures: [Int32: Int32] = [:]
        for processGroup in processGroups.values {
            if kill(-processGroup, number) != 0 { failures[processGroup] = errno }
        }
        return SignalForwardingResult(
            signal: number,
            attemptedProcessGroups: processGroups.count,
            failures: failures)
        #else
        _ = number
        return SignalForwardingResult(
            signal: number,
            attemptedProcessGroups: 0,
            failures: [:])
        #endif
    }

    /// The first interruption asks every child and registered runtime resource
    /// to shut down normally. A subsequent interruption escalates active native
    /// process groups to SIGKILL while using the same registered cleanup path
    /// for resources such as containers.
    @discardableResult
    public func handleInterruption(signal number: Int32) -> SignalForwardingResult {
        #if !os(Windows)
        let forwarded = forward(signal: interrupted ? SIGKILL : number)
        #else
        let forwarded = forward(signal: number)
        #endif
        interrupted = true
        interruptionSignal = interruptionSignal ?? number
        cancelAll()
        return forwarded
    }

    public func cancelAll() {
        for handler in handlers.values { handler() }
    }

    public func interruptAll(signal: Int32? = nil) {
        interrupted = true
        interruptionSignal = interruptionSignal ?? signal
        cancelAll()
    }

    public func wasInterrupted() -> Bool { interrupted }

    public func receivedInterruptionSignal() -> Int32? { interruptionSignal }
}

public struct SignalForwardingResult: Sendable {
    public let signal: Int32
    public let attemptedProcessGroups: Int
    public let failures: [Int32: Int32]
}

public struct RuntimeTerminalSignalCallbacks: Sendable {
    public let willInterrupt: @Sendable () -> Void
    public let didResize: @Sendable () -> Void
    public let willSuspend: @Sendable () -> Void
    public let didResume: @Sendable () -> Void

    public init(
        willInterrupt: @escaping @Sendable () -> Void = {},
        didResize: @escaping @Sendable () -> Void = {},
        willSuspend: @escaping @Sendable () -> Void = {},
        didResume: @escaping @Sendable () -> Void = {}
    ) {
        self.willInterrupt = willInterrupt
        self.didResize = didResize
        self.willSuspend = willSuspend
        self.didResume = didResume
    }
}

public final class RuntimeSignalHandlers: @unchecked Sendable {
    private let sources: [DispatchSourceSignal]

    public init(
        cancellation: RuntimeCancellation,
        terminal: RuntimeTerminalSignalCallbacks = RuntimeTerminalSignalCallbacks()
    ) {
        var sources: [DispatchSourceSignal] = []
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: number,
                queue: .global(qos: .userInitiated))
            source.setEventHandler {
                terminal.willInterrupt()
                // Forwarded here rather than inside the task below, because
                // this is the last point guaranteed to run: everything after it
                // depends on the process still being alive to run it.
                _ = cancellation.forwardImmediately(signal: number)
                Task { await cancellation.interruptAll(signal: number) }
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
                if number == SIGWINCH {
                    terminal.didResize()
                } else {
                    terminal.didResume()
                }
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
            terminal.willSuspend()
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
