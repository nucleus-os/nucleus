// The platform seam that resolves the run-loop-ownership fork.
//
// SwiftUI's `App.main()` blocks on the platform runloop. Here the frame loop lives in
// the platform *backend* — the compositor's io_uring loop when the app is the shell, the
// Android host, or a future standalone Linux app host — never in `NucleusApp`. So
// `NucleusApp` does not own or drive a loop: `App.main()` builds the scene graph into the
// backend's rendering context and hands control to the backend, which drives frames. The
// seam is a protocol the backend installs, mirroring the codebase's other inversion
// seams (the app-host bundle, `CompositorShellPolicy`, `RenderUploadSink`): the core owns
// the protocol; the platform side conforms and registers.

import NucleusLayers
import NucleusUI

#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(Darwin)
import Darwin
#endif

/// The backend an app runs on. A platform host owns the rendering context (a real
/// `CommitSink` into its render path) and the frame loop; `NucleusApp` materializes the
/// app's `Scene`s into that context and hands off. One conformer is installed per
/// process via `NucleusAppRuntime.installHost` before `App.main()` runs.
@MainActor
public protocol PlatformAppHost: AnyObject {
    /// The root rendering context the app's window/view tree is built in — backed by the
    /// host's real `CommitSink`, so committed layer transactions flow to the host's
    /// renderer. `App.main()` pushes this as the current context while it materializes.
    func appContext() -> Context

    /// Mount one materialized window scene. Called once per leaf `Scene` (a `WindowGroup`)
    /// during materialization; the host adopts the scene into its surface/output model and
    /// renders it on its own loop.
    func present(_ scene: WindowScene)

    /// Hand control to the host. Blocks on the host's runloop for a host that owns the
    /// process (a standalone app host), or returns immediately for a host whose loop is
    /// already running elsewhere (the compositor drives its io_uring loop; the app is
    /// mounted into it). Either way `NucleusApp` never spins a loop of its own.
    func run()
}

/// Process-wide registration for the installed `PlatformAppHost` and the `App.main()`
/// launch sequence. The backend installs its host at bring-up; `App.main()` reads it.
@MainActor
public enum NucleusAppRuntime {
    static var installedHost: (any PlatformAppHost)?

    /// Install the platform backend's host. Call once, before the app's `main()` runs
    /// (at the backend's bring-up). Replacing an existing host is allowed but unusual.
    public static func installHost(_ host: any PlatformAppHost) {
        installedHost = host
    }

    /// The `App.main()` launch sequence: resolve the host (falling back to an in-memory
    /// host when no backend is linked), construct the app, materialize its scenes into the
    /// host's context, then hand off. The app is built here so it never crosses an
    /// isolation boundary. The context is current only for the duration of materialization
    /// — the scene graph retains it afterward, and the host drives frames off the
    /// committed tree.
    @MainActor
    static func launch<A: App>(_ appType: A.Type) {
        let host = installedHost ?? InMemoryAppHost()
        let context = host.appContext()
        // Build the scene description (deferred content closures — no views yet), then
        // materialize it with the host's context current so the view tree mints its layers
        // there. Imperative push/pop rather than the `withContext` closure form: the
        // closure would capture the non-`Sendable` scene/host and trip region isolation.
        let scene = A().body
        Application.pushContext(context)
        defer { Application.popContext() }
        do {
            try scene._materialize(into: host)
        } catch {
            writeStderr("NucleusApp: failed to build the app scene: \(error)\n")
            return
        }
        host.run()
    }
}

/// The fallback host when no platform backend is installed. It builds the scene graph
/// into an in-memory context — so tooling and tests can exercise an `App` without a
/// renderer — and reports that nothing is being driven. A real app links a backend and
/// installs its host; this never renders.
@MainActor
final class InMemoryAppHost: PlatformAppHost {
    private let context: Context
    private(set) var presentedScenes: [WindowScene] = []

    init() {
        do {
            context = try Context(commitSink: InMemoryCommitSink())
        } catch {
            preconditionFailure("in-memory app context must be constructible: \(error)")
        }
    }

    func appContext() -> Context { context }

    func present(_ scene: WindowScene) {
        presentedScenes.append(scene)
    }

    func run() {
        writeStderr(
            "NucleusApp: no PlatformAppHost installed — built \(presentedScenes.count) "
            + "scene(s) into an in-memory context with no render loop. Link a platform "
            + "backend and register it via NucleusAppRuntime.installHost.\n")
    }
}

@MainActor
func writeStderr(_ message: String) {
    let bytes = Array(message.utf8)
    _ = bytes.withUnsafeBytes { write(2, $0.baseAddress, $0.count) }
}
