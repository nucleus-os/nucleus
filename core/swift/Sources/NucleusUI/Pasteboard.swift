public enum PasteboardFailure: Error, Sendable, Equatable {
    case unavailable
    case cancelled
    case transport(String)
}

/// Platform data-exchange seam used by editing controls.
///
/// Reads and writes are asynchronous because native selections may transfer
/// through pipes or another process. An implementation must never block its
/// actor while waiting for native I/O.
@MainActor
public protocol PasteboardAdapter: AnyObject {
    func readString() async throws(PasteboardFailure) -> String?
    func writeString(_ string: String) async throws(PasteboardFailure)
    func clear() async throws(PasteboardFailure)

    /// Cancel outstanding operations and release native state. Idempotent.
    func shutdown()
}

@MainActor
public final class Pasteboard {
    public typealias DiagnosticHandler =
        @MainActor @Sendable (_ operation: String, _ failure: PasteboardFailure) -> Void

    private var adapter: any PasteboardAdapter
    public private(set) var adapterGeneration: UInt64 = 1
    public var diagnosticHandler: DiagnosticHandler?
    private var isShutdown = false

    public init(adapter: any PasteboardAdapter) {
        self.adapter = adapter
    }

    isolated deinit {
        if !isShutdown {
            adapter.shutdown()
        }
    }

    public func replaceAdapter(_ replacement: any PasteboardAdapter) {
        precondition(!isShutdown, "a shut down pasteboard cannot replace its adapter")
        adapter.shutdown()
        adapter = replacement
        adapterGeneration &+= 1
        precondition(adapterGeneration != 0, "pasteboard adapter generation exhausted")
    }

    public func readString() async throws(PasteboardFailure) -> String? {
        guard !isShutdown else {
            throw PasteboardFailure.unavailable
        }
        do {
            try Task.checkCancellation()
            let value = try await adapter.readString()
            try Task.checkCancellation()
            return value
        } catch is CancellationError {
            throw report(.cancelled, operation: "read-string")
        } catch let failure as PasteboardFailure {
            throw report(failure, operation: "read-string")
        } catch {
            throw report(
                .transport(String(describing: error)),
                operation: "read-string")
        }
    }

    public func writeString(
        _ string: String
    ) async throws(PasteboardFailure) {
        guard !isShutdown else {
            throw PasteboardFailure.unavailable
        }
        do {
            try Task.checkCancellation()
            try await adapter.writeString(string)
            try Task.checkCancellation()
        } catch is CancellationError {
            throw report(.cancelled, operation: "write-string")
        } catch let failure as PasteboardFailure {
            throw report(failure, operation: "write-string")
        } catch {
            throw report(
                .transport(String(describing: error)),
                operation: "write-string")
        }
    }

    public func clear() async throws(PasteboardFailure) {
        guard !isShutdown else {
            throw PasteboardFailure.unavailable
        }
        do {
            try Task.checkCancellation()
            try await adapter.clear()
            try Task.checkCancellation()
        } catch is CancellationError {
            throw report(.cancelled, operation: "clear")
        } catch let failure as PasteboardFailure {
            throw report(failure, operation: "clear")
        } catch {
            throw report(
                .transport(String(describing: error)),
                operation: "clear")
        }
    }

    public func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        adapter.shutdown()
        adapterGeneration &+= 1
        precondition(adapterGeneration != 0, "pasteboard adapter generation exhausted")
    }

    /// Report a failure discovered after an adapter operation has returned.
    ///
    /// Native selection sources can fail later, while servicing another
    /// process's asynchronous transfer request. Those failures still belong to
    /// this context's pasteboard diagnostics even though there is no suspended
    /// `writeString` call left to throw from.
    public func reportAdapterFailure(
        _ failure: PasteboardFailure,
        operation: String
    ) {
        _ = report(failure, operation: operation)
    }

    @discardableResult
    private func report(
        _ failure: PasteboardFailure,
        operation: String
    ) -> PasteboardFailure {
        diagnosticHandler?(operation, failure)
        return failure
    }
}

/// Deterministic context-local pasteboard used by tests and in-memory hosts.
@MainActor
public final class InMemoryPasteboardAdapter: PasteboardAdapter {
    public private(set) var string: String?
    private var isShutdown = false

    public init(string: String? = nil) {
        self.string = string
    }

    public func readString() async throws(PasteboardFailure) -> String? {
        guard !isShutdown else { throw .unavailable }
        return string
    }

    public func writeString(
        _ string: String
    ) async throws(PasteboardFailure) {
        guard !isShutdown else { throw .unavailable }
        self.string = string
    }

    public func clear() async throws(PasteboardFailure) {
        guard !isShutdown else { throw .unavailable }
        string = nil
    }

    public func shutdown() {
        isShutdown = true
        string = nil
    }
}

/// Explicit adapter for a host that has not installed native data exchange.
@MainActor
public final class UnavailablePasteboardAdapter: PasteboardAdapter {
    public init() {}

    public func readString() async throws(PasteboardFailure) -> String? {
        throw .unavailable
    }

    public func writeString(
        _ string: String
    ) async throws(PasteboardFailure) {
        _ = string
        throw .unavailable
    }

    public func clear() async throws(PasteboardFailure) {
        throw .unavailable
    }

    public func shutdown() {}
}
