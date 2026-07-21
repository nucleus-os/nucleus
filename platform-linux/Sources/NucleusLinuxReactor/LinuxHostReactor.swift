import Dispatch
import Glibc
import NucleusLinuxReactorC
import Synchronization
import SystemPackage

private func reactorMonotonicNowNanoseconds() -> UInt64 {
    var value = timespec()
    guard clock_gettime(CLOCK_MONOTONIC, &value) == 0,
          value.tv_sec >= 0,
          value.tv_nsec >= 0
    else { return 0 }
    let seconds = UInt64(value.tv_sec)
    let nanoseconds = UInt64(value.tv_nsec)
    let (scaledSeconds, overflow) = seconds.multipliedReportingOverflow(
        by: 1_000_000_000)
    if overflow { return UInt64.max }
    let (result, additionOverflow) = scaledSeconds.addingReportingOverflow(
        nanoseconds)
    return additionOverflow ? UInt64.max : result
}

public enum LinuxReactorPollMode: Sendable, Equatable {
    case oneShot
    case multishot
}

public struct LinuxReactorInterest: Sendable, Equatable {
    public let token: UInt64
    public let fileDescriptor: Int32
    public let events: Int16
    public let mode: LinuxReactorPollMode

    public init(
        token: UInt64,
        fileDescriptor: Int32,
        events: Int16,
        mode: LinuxReactorPollMode = .oneShot
    ) {
        self.token = token
        self.fileDescriptor = fileDescriptor
        self.events = events
        self.mode = mode
    }
}

public struct LinuxReactorEvent: Sendable, Equatable {
    public let token: UInt64
    public let result: Int32

    public init(token: UInt64, result: Int32) {
        self.token = token
        self.result = result
    }

    public var failureCode: Int32? {
        result < 0 ? result : nil
    }

    public var returnedEvents: Int16 {
        result >= 0 ? Int16(truncatingIfNeeded: result) : 0
    }
}

public struct LinuxPollResult: Sendable, Equatable {
    public let returnedEvents: Int16

    public init(returnedEvents: Int16) {
        self.returnedEvents = returnedEvents
    }

    public var isReadable: Bool {
        returnedEvents & Int16(POLLIN) != 0
    }

    public var isWritable: Bool {
        returnedEvents & Int16(POLLOUT) != 0
    }

    public var isHungUp: Bool {
        returnedEvents & Int16(POLLHUP) != 0
    }

    public var isInvalid: Bool {
        returnedEvents & Int16(POLLNVAL) != 0
    }

    public var hasError: Bool {
        returnedEvents & Int16(POLLERR) != 0
    }

    public var isTerminal: Bool {
        isHungUp || isInvalid || hasError
    }
}

public struct LinuxReactorBatch: Sendable, Equatable {
    public let events: [LinuxReactorEvent]
    public let didReachDeadline: Bool
    public let wasExplicitlyWoken: Bool
    /// The reactor intentionally left CQ work for the next host turn.
    public let didExhaustCompletionBudget: Bool
    /// Dispatch-source wake to resumed-main-actor latency for this batch.
    public let executorResumeLatencyNanoseconds: UInt64?

    public init(
        events: [LinuxReactorEvent],
        didReachDeadline: Bool,
        wasExplicitlyWoken: Bool,
        didExhaustCompletionBudget: Bool = false,
        executorResumeLatencyNanoseconds: UInt64? = nil
    ) {
        self.events = events
        self.didReachDeadline = didReachDeadline
        self.wasExplicitlyWoken = wasExplicitlyWoken
        self.didExhaustCompletionBudget = didExhaustCompletionBudget
        self.executorResumeLatencyNanoseconds = executorResumeLatencyNanoseconds
    }
}

public enum LinuxHostReactorError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    case system(operation: String, code: Int32)
    case duplicateToken(UInt64)
    case reservedToken(UInt64)
    case invalidInterest(token: UInt64, fileDescriptor: Int32, events: Int16)
    case cancelled
    case stopped

    public var description: String {
        switch self {
        case .system(let operation, let code):
            return "\(operation) failed (\(code))"
        case .duplicateToken(let token):
            return "duplicate reactor token \(token)"
        case .reservedToken(let token):
            return "reactor token \(token) is reserved"
        case .invalidInterest(let token, let descriptor, let events):
            return "invalid reactor interest token=\(token) fd=\(descriptor) events=\(events)"
        case .cancelled:
            return "reactor wait was cancelled"
        case .stopped:
            return "reactor is stopped"
        }
    }
}

private final class ReactorWaitSignal: Sendable {
    private struct State {
        var pending = false
        var continuation: CheckedContinuation<UInt64?, Never>?
    }

    private let state = Mutex(State())

    func wait() async -> UInt64? {
        await withCheckedContinuation { continuation in
            let resumeImmediately = state.withLock { state in
                if state.pending {
                    state.pending = false
                    return true
                }
                precondition(
                    state.continuation == nil,
                    "LinuxHostReactor supports one waiter")
                state.continuation = continuation
                return false
            }
            if resumeImmediately {
                // The completion arrived before the actor actually suspended,
                // so there is no executor-resume latency to report.
                continuation.resume(returning: nil)
            }
        }
    }

    func signal(measureExecutorResume: Bool = false) {
        let timestampNanoseconds = measureExecutorResume
            ? reactorMonotonicNowNanoseconds()
            : nil
        let continuation = state.withLock { state in
            guard let continuation = state.continuation else {
                state.pending = true
                return Optional<CheckedContinuation<UInt64?, Never>>.none
            }
            state.continuation = nil
            return continuation
        }
        continuation?.resume(returning: timestampNanoseconds)
    }
}

private func makeCompletionEventHandler(
    fileDescriptor: Int32,
    waitSignal: ReactorWaitSignal
) -> DispatchWorkItem {
    DispatchWorkItem {
        while nucleus_linux_reactor_drain_counter(fileDescriptor) > 0 {}
        waitSignal.signal(measureExecutorResume: true)
    }
}

private func makeCloseHandler(fileDescriptor: Int32) -> DispatchWorkItem {
    DispatchWorkItem {
        _ = Glibc.close(fileDescriptor)
    }
}

/// Serializes cross-thread eventfd writes with close so a late wake can never
/// write through a recycled descriptor number after reactor teardown.
private final class ReactorControlSignal: Sendable {
    private let fileDescriptor: Int32
    private let isOpen = Mutex(true)

    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    func signal() {
        isOpen.withLock { isOpen in
            guard isOpen else { return }
            _ = nucleus_linux_reactor_signal(fileDescriptor)
        }
    }

    func close() {
        isOpen.withLock { isOpen in
            guard isOpen else { return }
            isOpen = false
            _ = Glibc.close(fileDescriptor)
        }
    }

    deinit {
        close()
    }
}

/// Single-owner io_uring reactor with an awaitable completion boundary.
///
/// All ring mutation and CQ consumption stays on the main actor. The dispatch
/// source only drains the kernel's completion eventfd and resumes the suspended
/// actor task; it never touches the ring or host state.
@MainActor
public final class LinuxHostReactor {
    private static let controlToken = UInt64.max
    private static let timerToken = UInt64.max - 1
    private static let requestablePollEvents = UInt16(truncatingIfNeeded:
        POLLIN | POLLPRI | POLLOUT | POLLRDNORM | POLLRDBAND
            | POLLWRNORM | POLLWRBAND)

    private struct Registration {
        var fileDescriptor: Int32
        var events: Int16
        var mode: LinuxReactorPollMode
        var context: UInt64?
    }

    private struct BatchBuilder {
        var events: [LinuxReactorEvent] = []
        var didReachDeadline = false
        var wasExplicitlyWoken = false

    }

    private var ring: IORing
    private let controlSignal: ReactorControlSignal
    private let controlFileDescriptor: Int32
    private let completionFileDescriptor: Int32
    private let timerFileDescriptor: Int32
    private let waitSignal: ReactorWaitSignal
    private let completionSource: DispatchSourceRead
    private var registrations: [UInt64: Registration] = [:]
    private var tokenByContext: [UInt64: UInt64] = [:]
    private var nextContext: UInt64 = 1
    private var hasPreparedRequests = false
    private var isStopped = false
    private var failure: LinuxHostReactorError?
    private let completionBudget: Int
    private var deferredBatch = BatchBuilder()
    private var deferredCompletionCount = 0

    public init(
        queueDepth: UInt32 = 256,
        completionBudget: Int = 256
    ) throws(LinuxHostReactorError) {
        precondition(completionBudget > 0, "completion budget must be positive")
        let completionFD = nucleus_linux_reactor_create_event_fd()
        guard completionFD >= 0 else {
            throw .system(
                operation: "creating io_uring completion eventfd",
                code: completionFD)
        }
        var closeCompletionFD = true
        defer { if closeCompletionFD { _ = Glibc.close(completionFD) } }

        let controlFD = nucleus_linux_reactor_create_event_fd()
        guard controlFD >= 0 else {
            throw .system(
                operation: "creating reactor control eventfd",
                code: controlFD)
        }
        var closeControlFD = true
        defer { if closeControlFD { _ = Glibc.close(controlFD) } }

        let timerFD = nucleus_linux_reactor_create_timer_fd()
        guard timerFD >= 0 else {
            throw .system(
                operation: "creating reactor timerfd",
                code: timerFD)
        }
        var closeTimerFD = true
        defer { if closeTimerFD { _ = Glibc.close(timerFD) } }

        let ring: IORing
        do {
            ring = try IORing(queueDepth: queueDepth)
        } catch let error {
            throw .system(
                operation: "creating io_uring",
                code: -Int32(error.rawValue))
        }
        self.ring = ring
        do {
            try self.ring.registerEventFD(
                FileDescriptor(rawValue: completionFD))
        } catch {
            throw .system(
                operation: "registering io_uring completion eventfd",
                code: -Int32(error.rawValue))
        }

        let waitSignal = ReactorWaitSignal()
        let source = DispatchSource.makeReadSource(
            fileDescriptor: completionFD,
            queue: DispatchQueue(
                label: "org.nucleus.linux-reactor.completions",
                qos: .userInteractive))
        source.setEventHandler(handler: makeCompletionEventHandler(
            fileDescriptor: completionFD,
            waitSignal: waitSignal))
        source.activate()

        self.controlSignal = ReactorControlSignal(fileDescriptor: controlFD)
        self.controlFileDescriptor = controlFD
        self.completionFileDescriptor = completionFD
        self.timerFileDescriptor = timerFD
        self.waitSignal = waitSignal
        self.completionSource = source
        self.completionBudget = completionBudget
        closeCompletionFD = false
        closeControlFD = false
        closeTimerFD = false
    }

    isolated deinit {
        shutdown()
    }

    /// Interrupt an outstanding wait. Safe from renderer, JS, and other worker
    /// threads. Eventfd coalesces repeated requests until the actor drains it.
    public nonisolated func wake() {
        controlSignal.signal()
    }

    public func wait(
        interests: [LinuxReactorInterest],
        timeoutNanoseconds: UInt64?
    ) async throws(LinuxHostReactorError) -> LinuxReactorBatch {
        guard !Task.isCancelled else { throw .cancelled }
        if let failure { throw failure }
        guard !isStopped else { throw .stopped }

        do {
            try reconcile(interests)
            try programTimer(relativeNanoseconds: timeoutNanoseconds)
            try ensureInternalRegistrations()
            try submitPreparedRequests()
        } catch let error {
            fail(error)
            throw error
        }

        var executorResumeLatencyNanoseconds: UInt64?
        while true {
            if let failure { throw failure }
            guard !isStopped else { throw .stopped }
            let batch = drainCompletions(
                executorResumeLatencyNanoseconds:
                    executorResumeLatencyNanoseconds)
            if let failure { throw failure }
            if Task.isCancelled { throw .cancelled }
            if !batch.events.isEmpty
                || batch.didReachDeadline
                || batch.wasExplicitlyWoken
                || batch.didExhaustCompletionBudget
            {
                return batch
            }
            await withTaskCancellationHandler {
                let signaledAtNanoseconds = await waitSignal.wait()
                if let signaledAtNanoseconds,
                   signaledAtNanoseconds != 0
                {
                    let resumedAtNanoseconds =
                        reactorMonotonicNowNanoseconds()
                    executorResumeLatencyNanoseconds =
                        resumedAtNanoseconds >= signaledAtNanoseconds
                            ? resumedAtNanoseconds - signaledAtNanoseconds
                            : 0
                }
            } onCancel: {
                self.wake()
            }
            if Task.isCancelled {
                throw .cancelled
            }
        }
    }

    public func shutdown() {
        guard !isStopped else { return }
        isStopped = true
        waitSignal.signal()
        try? ring.unregisterEventFD()
        completionSource.setCancelHandler(handler: makeCloseHandler(
            fileDescriptor: completionFileDescriptor))
        completionSource.cancel()
        controlSignal.close()
        _ = Glibc.close(timerFileDescriptor)
        registrations.removeAll()
        tokenByContext.removeAll()
    }

    private func fail(_ error: LinuxHostReactorError) {
        failure = error
        waitSignal.signal()
    }

    private func reconcile(
        _ interests: [LinuxReactorInterest]
    ) throws(LinuxHostReactorError) {
        var desired: [UInt64: LinuxReactorInterest] = [:]
        desired.reserveCapacity(interests.count + 2)
        for interest in interests {
            guard interest.token != Self.controlToken,
                  interest.token != Self.timerToken
            else { throw .reservedToken(interest.token) }
            let eventBits = UInt16(bitPattern: interest.events)
            guard interest.fileDescriptor >= 0,
                  interest.events > 0,
                  eventBits & ~Self.requestablePollEvents == 0
            else {
                throw .invalidInterest(
                    token: interest.token,
                    fileDescriptor: interest.fileDescriptor,
                    events: interest.events)
            }
            guard desired.updateValue(interest, forKey: interest.token) == nil
            else { throw .duplicateToken(interest.token) }
        }

        let removedTokens = registrations.keys.filter {
            $0 != Self.controlToken && $0 != Self.timerToken
                && desired[$0] == nil
        }
        for token in removedTokens {
            try removeRegistration(token: token)
        }

        for (token, interest) in desired {
            if let existing = registrations[token],
               existing.fileDescriptor == interest.fileDescriptor,
               existing.events == interest.events,
               existing.mode == interest.mode
            {
                if existing.context == nil {
                    try arm(token: token)
                }
                continue
            }
            if registrations[token] != nil {
                try removeRegistration(token: token)
            }
            registrations[token] = Registration(
                fileDescriptor: interest.fileDescriptor,
                events: interest.events,
                mode: interest.mode,
                context: nil)
            try arm(token: token)
        }
    }

    private func ensureInternalRegistrations() throws(LinuxHostReactorError) {
        if registrations[Self.controlToken] == nil {
            registrations[Self.controlToken] = Registration(
                fileDescriptor: controlFileDescriptor,
                events: Int16(POLLIN),
                mode: .multishot,
                context: nil)
        }
        if registrations[Self.timerToken] == nil {
            registrations[Self.timerToken] = Registration(
                fileDescriptor: timerFileDescriptor,
                events: Int16(POLLIN),
                mode: .multishot,
                context: nil)
        }
        if registrations[Self.controlToken]?.context == nil {
            try arm(token: Self.controlToken)
        }
        if registrations[Self.timerToken]?.context == nil {
            try arm(token: Self.timerToken)
        }
    }

    private func arm(token: UInt64) throws(LinuxHostReactorError) {
        guard var registration = registrations[token],
              registration.context == nil
        else { return }
        let context = allocateContext()
        try preparePoll(
            fileDescriptor: registration.fileDescriptor,
            events: registration.events,
            isMultiShot: registration.mode == .multishot,
            context: context)
        registration.context = context
        registrations[token] = registration
        tokenByContext[context] = token
    }

    private func removeRegistration(
        token: UInt64
    ) throws(LinuxHostReactorError) {
        guard let registration = registrations.removeValue(forKey: token)
        else { return }
        guard let context = registration.context else { return }
        try prepareCancellation(matchingContext: context)
    }

    private func preparePoll(
        fileDescriptor: Int32,
        events: Int16,
        isMultiShot: Bool,
        context: UInt64
    ) throws(LinuxHostReactorError) {
        func makeRequest() -> IORing.Request {
            IORing.Request.pollAdd(
                FileDescriptor(rawValue: fileDescriptor),
                pollEvents: IORing.Request.PollEvents(
                    rawValue: UInt32(UInt16(bitPattern: events))),
                isMultiShot: isMultiShot,
                context: context)
        }
        if ring.prepare(request: makeRequest()) {
            hasPreparedRequests = true
            return
        }
        try submitPreparedRequests()
        guard ring.prepare(request: makeRequest()) else {
            throw .system(operation: "preparing io_uring poll", code: -ENOSPC)
        }
        hasPreparedRequests = true
    }

    private func prepareCancellation(
        matchingContext context: UInt64
    ) throws(LinuxHostReactorError) {
        if ring.prepare(request: .cancel(
            .first,
            matchingContext: context))
        {
            hasPreparedRequests = true
            return
        }
        try submitPreparedRequests()
        guard ring.prepare(request: .cancel(
            .first,
            matchingContext: context))
        else {
            throw .system(
                operation: "preparing io_uring poll cancellation",
                code: -ENOSPC)
        }
        hasPreparedRequests = true
    }

    private func submitPreparedRequests() throws(LinuxHostReactorError) {
        guard hasPreparedRequests else { return }
        do {
            try ring.submitPreparedRequests()
            hasPreparedRequests = false
        } catch let error {
            throw .system(
                operation: "submitting io_uring requests",
                code: -Int32(error.rawValue))
        }
    }

    private func programTimer(
        relativeNanoseconds: UInt64?
    ) throws(LinuxHostReactorError) {
        let result = nucleus_linux_reactor_program_timer(
            timerFileDescriptor,
            relativeNanoseconds ?? 0,
            relativeNanoseconds == nil ? 0 : 1)
        guard result == 0 else {
            throw .system(operation: "programming reactor timer", code: result)
        }
    }

    private func drainCompletions(
        executorResumeLatencyNanoseconds: UInt64?
    ) -> LinuxReactorBatch {
        var batch = deferredBatch
        deferredBatch = BatchBuilder()
        var consumed = deferredCompletionCount
        deferredCompletionCount = 0
        while consumed < completionBudget,
              let completion = ring.tryConsumeCompletion()
        {
            consumed += 1
            process(completion, into: &batch)
        }

        var didExhaustCompletionBudget = false
        if consumed == completionBudget,
           let completion = ring.tryConsumeCompletion()
        {
            // Consume one CQE to distinguish an exactly-full batch from actual
            // backlog. Its observable outcome is held for the next host turn.
            process(completion, into: &deferredBatch)
            deferredCompletionCount = 1
            didExhaustCompletionBudget = true
        }
        return LinuxReactorBatch(
            events: batch.events,
            didReachDeadline: batch.didReachDeadline,
            wasExplicitlyWoken: batch.wasExplicitlyWoken,
            didExhaustCompletionBudget: didExhaustCompletionBudget,
            executorResumeLatencyNanoseconds:
                executorResumeLatencyNanoseconds)
    }

    private func process(
        _ completion: consuming IORing.Completion,
        into batch: inout BatchBuilder
    ) {
        let context = completion.context
        guard context != 0,
              let token = tokenByContext[context]
        else { return }
        let willContinue = completion.flags.contains(.moreCompletions)
        if !willContinue {
            tokenByContext.removeValue(forKey: context)
        }
        guard var registration = registrations[token],
              registration.context == context
        else { return }
        if !willContinue {
            registration.context = nil
            registrations[token] = registration
        }

        if completion.result == -ECANCELED { return }
        if completion.result < 0,
           token == Self.controlToken || token == Self.timerToken
        {
            fail(.system(
                operation: token == Self.controlToken
                    ? "polling reactor control eventfd"
                    : "polling reactor timerfd",
                code: completion.result))
            return
        }
        if token == Self.controlToken {
            drainCounterDescriptor(controlFileDescriptor)
            batch.wasExplicitlyWoken = true
        } else if token == Self.timerToken {
            drainCounterDescriptor(timerFileDescriptor)
            batch.didReachDeadline = true
        } else {
            batch.events.append(LinuxReactorEvent(
                token: token,
                result: completion.result))
        }
    }

    private func drainCounterDescriptor(_ descriptor: Int32) {
        while nucleus_linux_reactor_drain_counter(descriptor) > 0 {}
    }

    private func allocateContext() -> UInt64 {
        let context = nextContext
        nextContext &+= 1
        precondition(nextContext != 0, "io_uring context space exhausted")
        return context
    }
}
