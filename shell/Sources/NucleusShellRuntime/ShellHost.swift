@_spi(NucleusCompositor) import NucleusReactRuntime
import NucleusUI
import NucleusTextBackend
import NucleusUIEmbedder
import NucleusLayers
import NucleusRenderModel
import NucleusRenderHost
import NucleusAppHostBundle
import NucleusShellWayland
import NucleusShellPasteboard
import NucleusShellInput
import NucleusShellAuth
import NucleusLinuxDBus
import NucleusLinuxAccessibility
import NucleusShellServices
import NucleusLinuxEnvironment
import NucleusLinuxReactor
import NucleusShellProduct
import NucleusShellRender
import NucleusShellLoop
import NucleusRenderer
import NucleusShellSignalC
import Foundation
import Synchronization
import Tracy
#if canImport(Glibc)
import Glibc
#endif

// The shell composition root. Wires the whole out-of-process pipeline:
//
//   Wayland client  ──connect──▶ compositor
//        │ binds layer-shell, foreign-toplevel, …
//        ▼
//   LayerSurface (the bar)  ──configure(size)──▶  ShellRenderEngine
//        │                                              │ VK_KHR_wayland_surface swapchain
//        ▼                                              ▼
//   NucleusReactRuntime.Host  ──attachSurface──▶  root render context (RenderCommitSink)
//        │ evaluates bar.hbc, runs "bar"                │ commits → runtime-owned retained store
//        ▼                                              ▼
//   React <Bar/>  ──layer tree──────────────────▶  RenderCore.renderReady  ──present──▶ wl_surface
//
// The RN runtime boot reuses the same NucleusReactRuntime.Host facade the (now-deleted)
// compositor overlay used — the difference is only WHERE the surface attaches: a shell-owned
// root layer feeding this process's RenderCore, not the compositor's overlay scene.
@MainActor
public final class ShellHost {
    enum ReactorKind: UInt64 {
        case display = 1
        case exitSignal
        case renderWake
        case authentication
        case systemBus
        case accessibility
        case environment
        case pasteboardTransfer
        case dragTransfer
    }

    static let reactorKindShift: UInt64 = 56
    static let reactorInstanceMask =
        (UInt64(1) << reactorKindShift) - 1

    static func reactorToken(
        _ kind: ReactorKind,
        instance: UInt64 = 0
    ) -> UInt64 {
        precondition(
            instance <= reactorInstanceMask,
            "shell reactor instance space exhausted")
        return (kind.rawValue << reactorKindShift) | instance
    }

    let client: ShellWaylandClient
    let engine: ShellRenderEngine
    let renderWake: ShellRenderWakeSink
    let reactor: LinuxHostReactor
    let bundleURL: String
    let resourceHost: SwiftResourceHost
    let retainedStore: RetainedTreeStore
    let hostBundle: NucleusAppHostBundle
    let iconSourceResolver = ShellIconSourceResolver()

    var rnHost: NucleusReactRuntime.Host?
    var barSurface: LayerSurface?
    var barOutputID: UInt64?
    var barSurfaceID: Int?

    // The root render context the RN surface attaches into. Its commit sink lowers the RN
    // layer tree into the runtime-owned store, which the render engine's RenderCore reads.
    // The bar's root View is what the RN surface mounts into (attachSurface); its backing
    // layer tree commits through the context's sink.
    var renderContext: Context?
    var nativePublicationContext: WindowScenePublicationContext?
    var barRootView: View?

    /// The seat and the scene its input is routed into.
    ///
    /// Constructed here so input exists for the whole process lifetime, but no
    /// window is registered by default: the bar is a React Native surface with
    /// its own touch handling, so routing NucleusUI events into it would mean two
    /// input paths over one tree. A native surface owner calls
    /// `inputRouter.register(window:forSurface:)` to opt in.
    var seat: ShellSeat?
    var pasteboardAdapter: ShellWaylandPasteboardAdapter?
    var dragDropAdapter: ShellWaylandDragDropAdapter?
    public internal(set) var inputScene: WindowScene?
    public internal(set) var inputRouter: ShellInputRouter?
    var accessibilityAdapter: AtSPIService?
    var accessibilityBridge: AtSPIBridge?
    var environmentAdapter: PortalEnvironmentAdapter?

    /// Session lock. Nothing here locks on its own — no idle timer, no lid
    /// switch — and `lock()` refuses without an authenticator, because the
    /// compositor is deliberately fail-closed and a lock the shell cannot
    /// release would strand the session.
    public internal(set) var lockController: ShellLockController?
    var authenticator: PamAuthenticator?

    /// The system bus and the services on it. Opened lazily: a session with no
    /// bus is unusual but not fatal, and the shell renders either way.
    var systemBus: DBusConnection?
    public internal(set) var upower: UPowerService?
    /// Bar items driven by services. Held here because the runtime is what
    /// composes a service with a view — neither knows about the other.
    public let batteryWidget = BatteryWidget()

    var toplevels: ForeignToplevelManager?
    var running = false
    let exitSignalFD: Int32
    var renderWorkDue = true
    var nativeSceneDirty = true
    var animationDemand = false
    var nextPresentationDeadlineNs: UInt64?

    /// JS→native taskbar commands, pushed on the JS thread and drained on the main actor.
    let commandInbox: CommandInbox

    /// Bar height in logical px (reserved as work area via the layer-shell exclusive zone).
    public var barHeight: UInt32 = 28

    public init?(bundleURL: String, socketName: String? = nil) {
        // Block process-exit signals before Vulkan/Wayland initialization can
        // create worker threads; they inherit the mask and signalfd remains the
        // sole delivery path.
        let exitSignalFD = nucleus_shell_create_exit_signal_fd()
        guard exitSignalFD >= 0 else { return nil }
        var closeLocalSignalFD = true
        defer { if closeLocalSignalFD { close(exitSignalFD) } }
        guard let client = ShellWaylandClient(socketName: socketName) else { return nil }
        guard let reactor = try? LinuxHostReactor(queueDepth: 256) else {
            return nil
        }
        let resourceHost = SwiftResourceHost()
        let retainedStore = RetainedTreeStore(resourceHost: resourceHost)
        let hostBundle = NucleusAppHostBundle(resourceHost: resourceHost)
        guard let renderWake = ShellRenderWakeSink(),
              let engine = ShellRenderEngine(
                display: client.display,
                store: retainedStore,
                resourceHost: resourceHost,
                asyncRenderWakeSink: renderWake)
        else { return nil }
        self.exitSignalFD = exitSignalFD
        self.client = client
        self.reactor = reactor
        self.engine = engine
        self.renderWake = renderWake
        self.commandInbox = CommandInbox(wakeSink: renderWake)
        self.bundleURL = bundleURL
        self.resourceHost = resourceHost
        self.retainedStore = retainedStore
        self.hostBundle = hostBundle
        closeLocalSignalFD = false
    }

    deinit {
        close(exitSignalFD)
    }
}
