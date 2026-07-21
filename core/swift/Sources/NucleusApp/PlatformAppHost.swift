// The platform seam that resolves the run-loop-ownership fork.
//
// SwiftUI's `App.main()` blocks on the platform runloop. Here the frame loop lives in
// the platform *backend* — the compositor's io_uring loop when the app is the shell, the
// Android host, or a future standalone Linux app host — never in `NucleusApp`. So
// `NucleusApp` does not own or drive a loop: `App.main()` builds the scene graph into the
// backend's rendering context and hands control to the backend, which drives frames. The
// seam is a protocol the backend installs, mirroring the codebase's other inversion
// seams (the app-host bundle, `CompositorShellPolicy`, `CompositorRenderService`): the core owns
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

public struct SceneID: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        precondition(rawValue != 0, "SceneID.zero is reserved")
        self.rawValue = rawValue
    }
}

public enum SceneActivationPolicy: Sendable, Equatable {
    case automatic
    case nonactivating
}

/// Typed portable request made before a scene is built. A Wayland host maps the
/// role to its surface protocol while retaining anchors, exclusive zones,
/// keyboard interactivity, and configure/ack state entirely in its adapter.
public struct ScenePresentationRequest: Sendable, Equatable {
    public var id: SceneID
    public var title: String
    public var role: WindowRole
    public var activationPolicy: SceneActivationPolicy

    public init(
        id: SceneID,
        title: String,
        role: WindowRole,
        activationPolicy: SceneActivationPolicy
    ) {
        self.id = id
        self.title = title
        self.role = role
        self.activationPolicy = activationPolicy
    }
}

public enum PlatformAppHostError: Error, Sendable, Equatable {
    case contextUnavailable(String)
    case presentationFailed(String)
}

/// The backend an app runs on. A platform host owns each scene's rendering
/// context, its protocol surface, activation, teardown, and the frame loop.
@MainActor
public protocol PlatformAppHost: AnyObject {
    /// Return the real visual context for one typed scene request.
    func makeContext(
        for request: ScenePresentationRequest
    ) throws(PlatformAppHostError) -> Context

    /// Construct the semantic services before any retained content for this
    /// scene. A production host installs its native adapters here.
    func makeServices(
        for request: ScenePresentationRequest
    ) throws(PlatformAppHostError) -> UIHostServices

    /// Adopt one retained scene. The host transitions it through activation
    /// states and eventually calls `disconnect()` before destroying its
    /// protocol surface and visual context.
    func present(
        _ scene: WindowScene,
        request: ScenePresentationRequest
    ) throws(PlatformAppHostError)

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

    /// The `App.main()` launch sequence. A production launch requires an
    /// installed host; tests and tools opt into `InMemoryAppHost` explicitly.
    @MainActor
    static func launch<A: App>(_ appType: A.Type) {
        guard let host = installedHost else {
            writeStderr(
                "NucleusApp: no PlatformAppHost installed; refusing to build "
                + "an unpresented application scene.\n")
            return
        }
        let app = A()
        let scene = app.body
        let materializer = SceneMaterializer(host: host)
        do {
            try scene._materialize(using: materializer)
        } catch {
            writeStderr("NucleusApp: failed to build the app scene: \(error)\n")
            return
        }
        host.run()
    }
}

/// Explicit in-memory host for tests and scene-description tools.
@MainActor
public final class InMemoryAppHost: PlatformAppHost {
    private let runtimeHost = LayerRuntimeHost.inMemory()
    public private(set) var presentedScenes:
        [(request: ScenePresentationRequest, scene: WindowScene)] = []

    public init() {}

    public func makeContext(
        for request: ScenePresentationRequest
    ) throws(PlatformAppHostError) -> Context {
        do {
            return try Context(
                id: ContextID(rawValue: UInt32(truncatingIfNeeded: request.id.rawValue)),
                commitSink: InMemoryCommitSink(runtimeHost: runtimeHost))
        } catch {
            throw .contextUnavailable(String(describing: error))
        }
    }

    public func makeServices(
        for request: ScenePresentationRequest
    ) throws(PlatformAppHostError) -> UIHostServices {
        _ = request
        return .inMemory()
    }

    public func present(
        _ scene: WindowScene,
        request: ScenePresentationRequest
    ) throws(PlatformAppHostError) {
        presentedScenes.append((request, scene))
    }

    public func run() {}
}

@MainActor
final class SceneMaterializer {
    private let host: any PlatformAppHost
    private var nextSceneID: UInt64 = 1

    init(host: any PlatformAppHost) {
        self.host = host
    }

    func present<Content: View>(
        title: String,
        role: WindowRole,
        activationPolicy: SceneActivationPolicy,
        makeContent: () throws -> Content
    ) throws {
        let request = ScenePresentationRequest(
            id: SceneID(rawValue: nextSceneID),
            title: title,
            role: role,
            activationPolicy: activationPolicy)
        nextSceneID &+= 1
        precondition(nextSceneID != 0, "scene identity exhausted")

        let services = try host.makeServices(for: request)
        guard services.validateForRetainedMaterialization() else {
            throw PlatformAppHostError.contextUnavailable(
                "a production text backend is required before retained UI materialization")
        }
        let visualContext = try host.makeContext(for: request)
        let uiContext = UIContext(
            services: services,
            resourceHostHandle: visualContext.commitSink.resourceHostHandle,
            runtimeHost: visualContext.runtimeHost)
        let scene = try Application.withContexts(
            uiContext: uiContext,
            visualContext: visualContext
        ) {
            let root = try makeContent()
            let window = Window(
                title: title,
                role: role,
                level: .normal,
                styleMask: [.titled, .closable, .resizable])
            window.setContentView(root)
            return WindowScene(
                windows: [window],
                uiContext: uiContext,
                visualContext: visualContext)
        }
        try host.present(scene, request: request)
    }
}

@MainActor
func writeStderr(_ message: String) {
    let bytes = Array(message.utf8)
    _ = bytes.withUnsafeBytes { write(2, $0.baseAddress, $0.count) }
}
