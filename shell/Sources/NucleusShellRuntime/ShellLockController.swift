import NucleusShellWayland
import NucleusShellRender
import NucleusShellInput
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
    private let engine: ShellRenderEngine
    private let inputRouter: ShellInputRouter?
    private let scene: WindowScene
    private let publicationContext: WindowScenePublicationContext
    private let lockClient: SessionLockClient?

    private struct LockOutput {
        var surface: SessionLockSurface
        var window: Window
        var view: LockScreenView
        var renderOutputID: UInt64?
        var logicalOrigin: Point
    }

    private var lockOutputs: [LockOutput] = []

    public init(
        client: ShellWaylandClient,
        engine: ShellRenderEngine,
        scene: WindowScene,
        publicationContext: WindowScenePublicationContext,
        inputRouter: ShellInputRouter?
    ) {
        self.client = client
        self.engine = engine
        self.scene = scene
        self.publicationContext = publicationContext
        self.inputRouter = inputRouter
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
        guard let lockClient else { return }
        isLocked = true

        for output in client.outputs.values {
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
                window.setContentView(view)
                window.orderFront()
                scene.addWindow(window)
                return (view, window)
            }

            let record = LockOutput(
                surface: surface, window: window, view: view,
                renderOutputID: nil, logicalOrigin: origin)

            surface.onConfigure = { [weak self] width, height in
                self?.configureLockSurface(
                    surfaceID: UInt(bitPattern: surface.wlSurface),
                    width: width, height: height)
            }
            inputRouter?.register(
                window: window, forSurface: UInt(bitPattern: surface.wlSurface))
            lockOutputs.append(record)
        }
        client.flush()
    }

    /// Size the lock screen to exactly what the compositor requires. The
    /// protocol makes this size authoritative: attaching a differently-sized
    /// buffer is a protocol error that kills the locker.
    private func configureLockSurface(surfaceID: UInt, width: UInt32, height: UInt32) {
        guard let index = lockOutputs.firstIndex(where: {
            UInt(bitPattern: $0.surface.wlSurface) == surfaceID
        }) else { return }

        let scale = Double(lockOutputs[index].surface.output.scale)
        let logicalWidth = Double(width)
        let logicalHeight = Double(height)
        let origin = lockOutputs[index].logicalOrigin

        // The window owns the frame and syncs its content view, so this is the
        // single place the lock screen's logical rectangle is set.
        lockOutputs[index].window.setFrame(Rect(
            x: origin.x, y: origin.y, width: logicalWidth, height: logicalHeight))
        lockOutputs[index].window.setSurfaceAssociation(WindowSurfaceAssociation(
            surfaceID: PresentationSurfaceID(rawValue: UInt64(surfaceID)),
            transform: WindowSurfaceTransform(
                windowOriginInSurface: .zero,
                surfaceOriginInOutput: origin,
                backingScaleFactor: BackingScaleFactor(scale)
            )
        ))

        let pixelWidth = Int32(logicalWidth * scale)
        let pixelHeight = Int32(logicalHeight * scale)
        if let renderOutputID = lockOutputs[index].renderOutputID {
            engine.resizeSurface(
                renderOutputID, width: pixelWidth, height: pixelHeight, scale: scale)
        } else if let renderOutputID = engine.addSurface(
            waylandSurface: lockOutputs[index].surface.wlSurface,
            width: pixelWidth,
            height: pixelHeight,
            scale: scale,
            presentationContextID: publicationContext.visualContext.id.rawValue
        )
        {
            lockOutputs[index].renderOutputID = renderOutputID
        }
        // The lock's logical region is not the origin, so the geometry has to be
        // re-registered with it — `addSurface` assumes (0, 0).
        if let renderOutputID = lockOutputs[index].renderOutputID {
            engine.placeSurface(
                renderOutputID,
                logicalX: origin.x, logicalY: origin.y,
                logicalWidth: logicalWidth, logicalHeight: logicalHeight,
                scale: scale)
        }

        // Focus after the first configure, when there is something to type into.
        lockOutputs[index].view.focusPasswordField()
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
        for record in lockOutputs {
            // The password field may still hold text if the lock is being torn
            // down mid-attempt.
            record.view.clearPassword()
            inputRouter?.unregister(surfaceID: UInt(bitPattern: record.surface.wlSurface))
            scene.removeWindow(record.window)
            if let renderOutputID = record.renderOutputID {
                engine.removeSurface(renderOutputID)
            }
            record.surface.destroy()
        }
        lockOutputs.removeAll()
    }
}
