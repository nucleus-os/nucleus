public import NucleusUI
import NucleusUIEmbedder
import NucleusRenderModel
import NucleusAppHostBundle
import NucleusShellWayland
import NucleusShellPasteboard
public import NucleusShellInput
import NucleusShellAuth
import NucleusLinuxDBus
import NucleusLinuxAccessibility
public import NucleusShellServices
import NucleusLinuxEnvironment
import NucleusLinuxReactor
public import NucleusLinuxSession
import NucleusShellProduct
import NucleusShellRender
import NucleusShellLoop
import NucleusRenderer
import NucleusShellSignalC
import FoundationEssentials
import FoundationInternationalization
import Tracy
#if canImport(Glibc)
import Glibc
#endif

// The shell composition root. Wires the whole out-of-process pipeline:
//
//   Wayland client  ──connect──▶ compositor
//        │ binds layer-shell, foreign-toplevel, …
//        ▼
//   native NucleusUI product  ──WindowScene publication──▶ retained store
//        │                                                   │
//        ▼                                                   ▼
//   layer/lock Wayland surfaces ──NativeSurfaceRegistry──▶ ShellRenderEngine
//                                                           │ VK_KHR_wayland_surface
//                                                           ▼
//                                                     compositor
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
    let resourceHost: SwiftResourceHost
    let retainedStore: RetainedTreeStore
    let hostBundle: NucleusAppHostBundle
    let iconSourceResolver = ShellIconSourceResolver()

    var nativePublicationContext: WindowScenePublicationContext?
    var surfaceRegistry: NativeSurfaceRegistry?
    var productController: ShellProductController?
    var wallpaperSurfaces: [UInt32: NativeWallpaperSurface] = [:]
    var barSurfaces: [UInt32: NativeBarSurface] = [:]
    let wallpaperPath: String
    var wallpaperFailureReported = false

    /// The seat and the scene its input is routed into.
    ///
    /// The authoritative native scene and its Wayland input adapter.
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
    var toplevels: ForeignToplevelManager?
    var running = false
    let exitSignalFD: Int32
    var renderWorkDue = true
    var nativeSceneDirty = true
    var animationDemand = false
    var nextPresentationDeadlineNs: UInt64?
    var nextClockUpdateNanoseconds: UInt64?
    var startupFrameDiagnosticsRemaining = 8
    var readinessReporter: SessionReadinessReporter?
    var startupReadiness = ShellStartupReadinessTracker()
    let clockFormatStyle: Date.FormatStyle

    /// Bar height in logical px (reserved as work area via the layer-shell exclusive zone).
    public var barHeight: UInt32 = 28

    public init?(
        socketName: String? = nil,
        configuration: SessionConfiguration = .defaults
    ) {
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
        let clockFormatStyle = ShellFormatting.clockStyle()
        guard let renderWake = ShellRenderWakeSink(),
              let engine = ShellRenderEngine(
                display: client.display,
                enableValidation: configuration.enableVulkanValidation,
                store: retainedStore,
                resourceHost: resourceHost,
                asyncRenderWakeSink: renderWake)
        else { return nil }
        self.exitSignalFD = exitSignalFD
        self.client = client
        self.reactor = reactor
        self.engine = engine
        self.renderWake = renderWake
        self.clockFormatStyle = clockFormatStyle
        self.resourceHost = resourceHost
        self.retainedStore = retainedStore
        self.hostBundle = hostBundle
        self.wallpaperPath = ShellFormatting.wallpaperPath(
            configuredPath: configuration.wallpaperPath,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        closeLocalSignalFD = false
    }

    deinit {
        close(exitSignalFD)
    }
}
