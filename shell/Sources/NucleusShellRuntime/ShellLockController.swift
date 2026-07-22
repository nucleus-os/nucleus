import NucleusShellWayland
import NucleusShellProduct
import NucleusUI
import NucleusUIEmbedder

/// Drives the session lock: request the lock, present a native lock screen on
/// every output, route input to it, and unlock once authentication succeeds.
///
/// The compositor is the fail-closed authority — an unresponsive locker leaves
/// the session blocked, not open — so the hazard here is not "someone gets in",
/// it is "nobody gets out". Two rules follow, both enforced rather than
/// documented:
///
/// 1. `lock()` refuses without an authenticator. Requesting a lock the shell has
///    no way to release would strand the session.
/// 2. Nothing locks automatically. An idle timer or a lid switch may call
///    `lock()`, but this type never decides to on its own.
@MainActor
public final class ShellLockController {
    /// Verifies passwords. Without one, `lock()` refuses outright.
    public weak var authenticator: (any LockAuthenticator)?

    /// Fired after the session unlocks and the lock surfaces are gone.
    public var onUnlocked: (() -> Void)?

    public private(set) var isLocked = false

    private let client: ShellWaylandClient
    private let surfaceRegistry: NativeSurfaceRegistry
    private let publicationContext: WindowScenePublicationContext
    private let lockClient: SessionLockClient?

    private struct LockOutput {
        var outputID: UInt32
        var surface: SessionLockSurface
        var window: Window
        var view: LockScreenView
        var logicalOrigin: Point
    }

    private var lockOutputs: [LockOutput] = []

    func outputsChanged() {
        guard isLocked else { return }
        reconcileLockSurfaces()

        for index in lockOutputs.indices {
            let outputID = lockOutputs[index].outputID
            guard let output = client.outputs[outputID] else { continue }
            lockOutputs[index].logicalOrigin = Point(
                x: Double(output.logicalX),
                y: Double(output.logicalY))
            surfaceRegistry.updateRefreshRate(
                output.refreshMillihertz,
                surfaceID: UInt(bitPattern:
                    lockOutputs[index].surface.wlSurface))
            if lockOutputs[index].surface.hasConfigure {
                configureLockSurface(
                    surfaceID: UInt(bitPattern:
                        lockOutputs[index].surface.wlSurface),
                    width: lockOutputs[index].surface.configuredWidth,
                    height: lockOutputs[index].surface.configuredHeight,
                    focusPasswordField: false)
            }
        }
    }

    init(
        client: ShellWaylandClient,
        publicationContext: WindowScenePublicationContext,
        surfaceRegistry: NativeSurfaceRegistry
    ) {
        self.client = client
        self.publicationContext = publicationContext
        self.surfaceRegistry = surfaceRegistry
        self.lockClient = SessionLockClient(client: client)
        lockClient?.onLocked = { [weak self] in self?.presentLockSurfaces() }
        lockClient?.onFinished = { [weak self] in self?.handleLockRefused() }
    }

    /// Whether locking is possible at all: the compositor must offer the
    /// protocol and the shell must have a way to authenticate.
    public var canLock: Bool { lockClient != nil && authenticator != nil }

    /// Request the session lock.
    ///
    /// Returns whether the request was made. Refused without an authenticator —
    /// locking with no way to unlock hands the session to a compositor that is
    /// deliberately fail-closed, and there is no recovery from inside.
    @discardableResult
    public func lock() -> Bool {
        guard !isLocked else { return false }
        guard let lockClient else { return false }
        guard authenticator != nil else { return false }
        lockClient.lockSession()
        client.flush()
        return true
    }

    // MARK: - Presentation

    /// The compositor confirmed the lock; every output now needs a lock surface.
    /// Until each one commits a frame the session shows the compositor's blank
    /// fallback, which is the correct thing for it to show.
    private func presentLockSurfaces() {
        isLocked = true
        reconcileLockSurfaces()
        client.flush()
    }

    /// Match the protocol's one-lock-surface-per-live-output requirement as
    /// outputs appear and disappear while the session is held.
    private func reconcileLockSurfaces() {
        guard let lockClient else { return }

        let liveOutputIDs = Set(client.outputs.keys)
        for index in lockOutputs.indices.reversed()
            where !liveOutputIDs.contains(lockOutputs[index].outputID)
        {
            tearDownLockSurface(at: index)
        }

        let hostedOutputIDs = Set(lockOutputs.map(\.outputID))
        for output in client.outputs.values
            where !hostedOutputIDs.contains(output.registryName)
        {
            guard let surface = lockClient.lockSurface(for: output) else { continue }

            let origin = Point(
                x: Double(output.logicalX),
                y: Double(output.logicalY)
            )
            let (view, window) = publicationContext.withSemanticContext {
                let view = LockScreenView()
                view.authenticator = authenticator
                view.onAuthenticated = { [weak self] in self?.unlock() }

                let window = Window(title: "Lock")
                window.role = .lock
                window.level = .criticalOverlay
                window.setContentView(view)
                return (view, window)
            }

            let record = LockOutput(
                outputID: output.registryName,
                surface: surface, window: window, view: view,
                logicalOrigin: origin)

            surface.onConfigure = { [weak self] width, height in
                self?.configureLockSurface(
                    surfaceID: UInt(bitPattern: surface.wlSurface),
                    width: width, height: height)
            }
            surfaceRegistry.register(
                window: window,
                waylandSurface: surface.wlSurface,
                refreshMillihertz: output.refreshMillihertz)
            lockOutputs.append(record)
        }
    }

    /// Size the lock screen to exactly what the compositor requires. The
    /// protocol makes this size authoritative: attaching a differently-sized
    /// buffer is a protocol error that kills the locker.
    private func configureLockSurface(
        surfaceID: UInt,
        width: UInt32,
        height: UInt32,
        focusPasswordField: Bool = true
    ) {
        guard let index = lockOutputs.firstIndex(where: {
            UInt(bitPattern: $0.surface.wlSurface) == surfaceID
        }) else { return }

        let scale = Double(max(1, lockOutputs[index].surface.output.scale))
        let logicalWidth = Double(width)
        let logicalHeight = Double(height)
        let origin = lockOutputs[index].logicalOrigin

        _ = surfaceRegistry.configure(
            surfaceID: surfaceID,
            logicalOrigin: origin,
            logicalWidth: logicalWidth,
            logicalHeight: logicalHeight,
            scale: scale,
            refreshMillihertz:
                lockOutputs[index].surface.output.refreshMillihertz)

        // Focus after the first configure, when there is something to type into.
        if focusPasswordField {
            lockOutputs[index].view.focusPasswordField()
        }
    }

    /// The compositor refused the lock, or revoked it. Either way the session is
    /// not locked and the UI must not pretend otherwise.
    private func handleLockRefused() {
        tearDownLockSurfaces()
        isLocked = false
    }

    // MARK: - Unlock

    private func unlock() {
        guard isLocked else { return }
        // Surfaces first, then the lock: the protocol requires the lock surfaces
        // to be destroyed before `unlock_and_destroy`.
        tearDownLockSurfaces()
        lockClient?.unlockAndDestroy()
        client.flush()
        isLocked = false
        onUnlocked?()
    }

    private func tearDownLockSurfaces() {
        for index in lockOutputs.indices.reversed() {
            tearDownLockSurface(at: index)
        }
    }

    private func tearDownLockSurface(at index: Int) {
        let record = lockOutputs.remove(at: index)
        // The password field may still hold text if the lock is being torn
        // down mid-attempt.
        record.view.clearPassword()
        surfaceRegistry.unregister(
            surfaceID: UInt(bitPattern: record.surface.wlSurface))
        record.surface.destroy()
    }

    func shutdown() {
        tearDownLockSurfaces()
        isLocked = false
    }
}
