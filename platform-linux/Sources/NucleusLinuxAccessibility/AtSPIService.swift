import FoundationEssentials
import FoundationInternationalization
import NucleusLinuxDBus
public import NucleusLinuxReactor
public import NucleusUI
#if canImport(Glibc)
import Glibc
#endif

public struct AtSPIServiceError: Error, Sendable, Equatable {
    public var operation: String
    public var code: Int32

    public init(operation: String, code: Int32) {
        self.operation = operation
        self.code = code
    }
}

struct AtSPILiveResourceCounts: Sendable, Equatable {
    var connections = 0
    var fallbackSlots = 0
}

/// Nonblocking AT-SPI2 provider driven by the shell's existing poll loop.
///
/// The adapter connects to the dedicated accessibility bus, registers one
/// fallback object subtree, and answers requests from its latest immutable
/// export snapshot. `process()` never waits for I/O; actions are the only calls
/// that cross back into NucleusUI, and they run on the UI actor.
@MainActor
public final class AtSPIService: LinuxReactorSource {
    private(set) static var liveResourceCounts =
        AtSPILiveResourceCounts()

    public var onAction:
        (@MainActor (AccessibilityActionRequest) -> Bool)?
    public var diagnosticHandler:
        (@MainActor @Sendable (AtSPIServiceError, UInt64) -> Void)?

    enum ConnectionPhase {
        case idle
        case discovering
        case embedding
        case ready
    }

    var connection: SDBusConnection?
    private var objectRegistration: SDBusObjectRegistration?
    private var pendingCall: SDBusPendingCall?
    var connectionPhase = ConnectionPhase.idle
    var model: AtSPIExportModel
    var uniqueName = ""
    var registryName = ""
    var registryPath = AtSPIExportModel.nullPath
    var applicationID: Int32 = 0
    var busAddress = ""
    let locale: String
    private var isClosed = false
    private var reconnectDeadlineMicroseconds: UInt64?
    private var pendingEvents: [AtSPIEvent] = []
    private let maximumPendingEvents = 256
    private var reportedDiagnostics: Set<DiagnosticKey> = []
    public private(set) var connectionGeneration: UInt64 = 0

    var applicationBusName: String { uniqueName }
    var queuedEventCount: Int { pendingEvents.count }

    public init(applicationName: String) {
        model = AtSPIExportModel(applicationName: applicationName)
        _ = model.apply(
            snapshot: AccessibilityTreeSnapshot(),
            update: AccessibilityTreeUpdate(
                revision: 0,
                rootIDs: [],
                inserted: [],
                updated: [],
                removed: [],
                notifications: []))
        locale = Locale.current.identifier
        reconnectDeadlineMicroseconds = 0
    }

    isolated deinit {
        close()
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        reconnectDeadlineMicroseconds = nil
        pendingEvents.removeAll(keepingCapacity: false)
        onAction = nil
        disconnectTransport(flush: true)
    }

    public var fileDescriptor: Int32 {
        connection?.fileDescriptor ?? -1
    }

    public var pollEvents: Int16 {
        connection?.pollEvents ?? 0
    }

    public func timeoutMicroseconds() -> UInt64? {
        let current = Self.monotonicMicroseconds()
        var timeout = reconnectDeadlineMicroseconds.map {
            $0 > current ? $0 - current : 0
        }
        if let busTimeout = connection?.timeoutMicroseconds() {
            timeout = min(timeout ?? busTimeout, busTimeout)
        }
        return timeout
    }

    @discardableResult
    public func process() -> Bool {
        guard !isClosed else { return false }
        var changed = false
        if connection == nil {
            guard timeoutMicroseconds() == 0 else { return false }
            do {
                try beginConnectionAttempt()
                changed = true
            } catch {
                let failure = serviceFailure(
                    error, operation: "starting AT-SPI connection")
                transitionToReconnect(after: failure)
            }
        }
        guard let connection else { return changed }
        do {
            return try connection.process() || changed
        } catch {
            transitionToReconnect(after: serviceFailure(
                error, operation: "processing accessibility bus"))
            return true
        }
    }

    public func apply(
        snapshot: AccessibilityTreeSnapshot,
        update: AccessibilityTreeUpdate
    ) {
        let exported = model.apply(snapshot: snapshot, update: update)
        guard connectionPhase == .ready else {
            enqueue(events: exported.events)
            return
        }
        emitOrQueue(exported.events)
    }

    public func transportDidFail(
        operation: String
    ) {
        transportDidFail(operation: operation, code: -ECONNRESET)
    }

    public func transportDidFail(
        operation: String,
        code: Int32
    ) {
        guard !isClosed else { return }
        transitionToReconnect(after: AtSPIServiceError(
            operation: operation,
            code: code))
    }

    // MARK: - Connection and registration

    private struct DiagnosticKey: Hashable {
        var operation: String
        var generation: UInt64
    }

    public var isReady: Bool { connectionPhase == .ready }

    private func beginConnectionAttempt() throws(DBusError) {
        precondition(connection == nil && objectRegistration == nil)
        reconnectDeadlineMicroseconds = nil
        if let address = ProcessInfo.processInfo.environment[
            "AT_SPI_BUS_ADDRESS"],
            !address.isEmpty
        {
            try connectAccessibilityBus(address: address)
            return
        }

        let discovery = try SDBusConnection(.session)
        connection = discovery
        Self.liveResourceCounts.connections += 1
        connectionPhase = .discovering
        pendingCall = try discovery.callAsync(
            service: "org.a11y.Bus",
            path: "/org/a11y/bus",
            interface: "org.a11y.Bus",
            member: "GetAddress"
        ) { [weak self] result in
            self?.didDiscoverAccessibilityBus(result)
        }
    }

    private func didDiscoverAccessibilityBus(
        _ result: Result<SDBusMessage, DBusError>
    ) {
        guard !isClosed, connectionPhase == .discovering else { return }
        pendingCall = nil
        switch result {
        case .failure(let error):
            transitionToReconnect(after: serviceFailure(
                error, operation: "querying AT-SPI bus address"))
        case .success(let message):
            guard let address = message.readString(), !address.isEmpty else {
                transitionToReconnect(after: AtSPIServiceError(
                    operation: "decoding AT-SPI bus address",
                    code: -EBADMSG))
                return
            }
            closeConnection(flush: false)
            do {
                try connectAccessibilityBus(address: address)
            } catch {
                transitionToReconnect(after: serviceFailure(
                    error, operation: "connecting to accessibility bus"))
            }
        }
    }

    private func connectAccessibilityBus(
        address: String
    ) throws(DBusError) {
        precondition(connection == nil && objectRegistration == nil)
        let accessibilityConnection = try SDBusConnection(address: address)
        connection = accessibilityConnection
        Self.liveResourceCounts.connections += 1
        busAddress = address
        guard let name = accessibilityConnection.uniqueName else {
            throw DBusError(
                name: "org.nucleus.DBus.Error.InvalidConnection",
                message: "The accessibility bus assigned no unique name")
        }
        uniqueName = name
        objectRegistration = try accessibilityConnection.registerFallback(
            path: "/org/a11y/atspi"
        ) { [weak self] message in
            guard let self else { return -ECANCELED }
            return self.handle(message)
        }
        Self.liveResourceCounts.fallbackSlots += 1
        connectionPhase = .embedding
        pendingCall = try accessibilityConnection.callAsync(
            service: "org.a11y.atspi.Registry",
            path: AtSPIExportModel.rootPath,
            interface: "org.a11y.atspi.Socket",
            member: "Embed",
            encode: {
                $0.objectReference(
                    busName: name,
                    path: AtSPIExportModel.rootPath)
            }
        ) { [weak self] result in
            self?.didEmbedApplication(result)
        }
    }

    private func didEmbedApplication(
        _ result: Result<SDBusMessage, DBusError>
    ) {
        guard !isClosed, connectionPhase == .embedding else { return }
        pendingCall = nil
        switch result {
        case .failure(let error):
            transitionToReconnect(after: serviceFailure(
                error, operation: "registering with AT-SPI registry"))
            return
        case .success(let message):
            guard let reference = readObjectReference(message) else {
                transitionToReconnect(after: AtSPIServiceError(
                    operation: "decoding AT-SPI registry reference",
                    code: -EBADMSG))
                return
            }
            registryName = reference.0
            registryPath = reference.1
        }

        connectionPhase = .ready
        connectionGeneration &+= 1
        precondition(
            connectionGeneration != 0,
            "AT-SPI connection generation exhausted")
        reconnectDeadlineMicroseconds = nil
        reportedDiagnostics.removeAll(keepingCapacity: true)
        let queued = pendingEvents
        pendingEvents.removeAll(keepingCapacity: true)
        emitOrQueue(queued)
    }

    private func disconnectTransport(flush: Bool) {
        pendingCall?.cancel()
        pendingCall = nil
        if let objectRegistration {
            objectRegistration.cancel()
            self.objectRegistration = nil
            Self.liveResourceCounts.fallbackSlots -= 1
        }
        closeConnection(flush: flush)
        connectionPhase = .idle
        uniqueName = ""
        registryName = ""
        registryPath = AtSPIExportModel.nullPath
    }

    private func closeConnection(flush: Bool) {
        guard let connection else { return }
        connection.close(flush: flush)
        self.connection = nil
        Self.liveResourceCounts.connections -= 1
    }

    func transitionToReconnect(after failure: AtSPIServiceError) {
        report(failure)
        disconnectTransport(flush: false)
        reconnectDeadlineMicroseconds = Self.monotonicMicroseconds()
            .saturatingAdd(250_000)
    }

    private func report(_ failure: AtSPIServiceError) {
        let key = DiagnosticKey(
            operation: failure.operation,
            generation: connectionGeneration)
        guard reportedDiagnostics.insert(key).inserted else { return }
        diagnosticHandler?(failure, connectionGeneration)
    }

    private func enqueue(events: [AtSPIEvent]) {
        guard !events.isEmpty else { return }
        let overflow = max(
            0,
            pendingEvents.count + events.count - maximumPendingEvents)
        if overflow > 0 {
            pendingEvents.removeFirst(min(overflow, pendingEvents.count))
        }
        pendingEvents.append(contentsOf: events.suffix(maximumPendingEvents))
        if pendingEvents.count > maximumPendingEvents {
            pendingEvents.removeFirst(
                pendingEvents.count - maximumPendingEvents)
        }
    }

    func emitOrQueue(_ events: [AtSPIEvent]) {
        for index in events.indices {
            guard emit(events[index]) else {
                enqueue(events: Array(events[index...]))
                return
            }
        }
    }

    private func serviceFailure(
        _ error: any Error,
        operation: String
    ) -> AtSPIServiceError {
        if let error = error as? AtSPIServiceError { return error }
        if let error = error as? DBusError {
            return AtSPIServiceError(
                operation: operation,
                code: error.systemCode ?? -EIO)
        }
        return AtSPIServiceError(operation: operation, code: -EIO)
    }

    private static func monotonicMicroseconds() -> UInt64 {
        var now = timespec()
        // `now` is a live, correctly aligned value for the duration of the C
        // call, and clock_gettime writes exactly one initialized timespec.
        let result = unsafe clock_gettime(CLOCK_MONOTONIC, &now)
        precondition(result == 0, "CLOCK_MONOTONIC is unavailable")
        let seconds = UInt64(max(0, now.tv_sec))
        let microseconds = UInt64(max(0, now.tv_nsec)) / 1_000
        return seconds.saturatingMultiply(1_000_000)
            .saturatingAdd(microseconds)
    }

}

private extension UInt64 {
    func saturatingAdd(_ other: UInt64) -> UInt64 {
        let result = addingReportingOverflow(other)
        return result.overflow ? .max : result.partialValue
    }

    func saturatingMultiply(_ other: UInt64) -> UInt64 {
        let result = multipliedReportingOverflow(by: other)
        return result.overflow ? .max : result.partialValue
    }
}
