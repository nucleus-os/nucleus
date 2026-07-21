/// Receives frame demand produced by asynchronous renderer work.
///
/// Implementations are owned by the platform host and must be safe to call from
/// a renderer pthread. They wake the host's event loop; they do not enter
/// main-actor render state directly.
public protocol AsyncRenderWakeSink: Sendable {
    nonisolated func signalRenderWork()
}
