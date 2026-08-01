import Foundation
import NucleusAppHostBundle
import NucleusConfig
import NucleusDiagnostics
import NucleusLinuxAccessibility
import NucleusLinuxDBus
import NucleusLinuxEnvironment
import NucleusLinuxReactor
import NucleusRenderModel
import NucleusRenderer
package import NucleusSessionProtocol
import NucleusShellAuth
import NucleusShellProduct
package import NucleusShellServices
import NucleusShellSignalC
package import NucleusUI
import NucleusUIEmbedder
package import NucleusWindowClientHost
package import NucleusWindowClientInput
import NucleusWindowClientPasteboard
import NucleusWindowClientRender
import NucleusWindowClientRuntime
package import NucleusWindowClientWayland
import Tracy

#if canImport(FoundationInternationalization)
import FoundationInternationalization
#endif

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
//   layer/lock Wayland surfaces ──NativeSurfaceRegistry──▶ NucleusWindowClientRenderEngine
//                                                           │ DMA-BUF + syncobj
//                                                           ▼
//                                                     compositor
@MainActor
package final class ShellHost {
    enum ReactorKind: UInt64 {
        case display = 1
        case exitSignal
        case renderWake
        case authenticationResponse
        case authenticationProcess
        case systemBus
        case accessibility
        case environment
        case pasteboardTransfer
        case dragTransfer
        case configService
        case shellPolicy
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

    let client: NucleusDesktopConnection
    let engine: NucleusWindowClientRenderEngine
    let desktopHost: NucleusDesktopHost
    let renderWake: ShellRenderWakeSink
    let reactor: LinuxHostReactor
    let resourceHost: SwiftResourceHost
    let retainedStore: RetainedTreeStore
    let hostBundle: NucleusAppHostBundle
    let textSystem: TextSystem
    let iconSourceResolver = ShellIconSourceResolver()
    let actionDispatcher: ShellActionDispatcher
    let notifications = NotificationService()

    var nativePublicationContext: WindowScenePublicationContext?
    var surfaceRegistry: NativeSurfaceRegistry?
    var productController: ShellProductController?
    var wallpaperSurfaces: [UInt32: NativeWallpaperSurface] = [:]
    var barSurfaces: [UInt32: NativeBarSurface] = [:]
    var feedbackSurface: NativeFeedbackSurface?
    var notificationSurface: NativeNotificationSurface?
    let wallpaperPath: String
    var wallpaperFailureReported = false

    /// The seat and the scene its input is routed into.
    ///
    /// The authoritative native scene and its Wayland input adapter.
    var seat: NucleusDesktopSeat?
    var pasteboardAdapter: NucleusDesktopPasteboardAdapter?
    var dragDropAdapter: NucleusDesktopDragDropAdapter?
    package internal(set) var inputScene: WindowScene?
    package internal(set) var inputRouter: NucleusDesktopInputRouter?
    var accessibilityAdapter: AtSPIService?
    var accessibilityBridge: AtSPIBridge?
    var environmentAdapter: PortalEnvironmentAdapter?

    /// Session lock. Nothing here locks on its own — no idle timer, no lid
    /// switch — and `lock()` refuses without an authenticator, because the
    /// compositor is deliberately fail-closed and a lock the shell cannot
    /// release would strand the session.
    package internal(set) var lockController: ShellLockController?
    var authenticator: PamAuthenticator?

    /// The system bus and the services on it. Opened lazily: a session with no
    /// bus is unusual but not fatal, and the shell renders either way.
    var systemBus: DBusConnection?
    package internal(set) var upower: UPowerService?
    var toplevels: NucleusDesktopForeignToplevelManager?
    var idleNotification: NucleusDesktopIdleNotification?
    var running = false
    let exitSignalFD: Int32
    var renderWorkDue = true
    var nativeSceneDirty = true
    var animationDemand = false
    var nextPresentationDeadlineNs: UInt64?
    var nextClockUpdateNanoseconds: UInt64?
    var startupFrameDiagnosticsRemaining = 8
    var readinessReporter: SessionReadinessReporter?
    var liveConfiguration: ShellConfiguration
    var configurationEpoch: ConfigurationServiceEpoch
    var configurationGeneration: ConfigurationGeneration
    let configurationChannel: ConfigurationClientChannel?
    let policyChannel: ShellPolicyChannel?
    var policyReady = false
    var startupReadiness = NucleusWindowClientStartupReadinessTracker()
    let clockFormatStyle: Date.FormatStyle

    /// Bar height in logical px (reserved as work area via the layer-shell exclusive zone).
    package var barHeight: UInt32 = 28

    package init?(
        socketName: String? = nil,
        waylandDescriptor: Int32? = nil,
        configuration: SessionConfiguration = .defaults,
        liveConfiguration: ShellConfiguration =
            NucleusConfiguration.defaults.shellProjection,
        configurationEpoch: ConfigurationServiceEpoch =
            ConfigurationServiceEpoch(high: 0, low: 0),
        configurationGeneration: ConfigurationGeneration =
            ConfigurationGeneration(rawValue: 0),
        configurationChannel: ConfigurationClientChannel? = nil,
        policyChannel: ShellPolicyChannel? = nil
    ) {
        // Block process-exit signals before Vulkan/Wayland initialization can
        // create worker threads; they inherit the mask and signalfd remains the
        // sole delivery path.
        let exitSignalFD = nucleus_shell_create_exit_signal_fd()
        guard exitSignalFD >= 0 else { return nil }
        var closeLocalSignalFD = true
        defer { if closeLocalSignalFD { close(exitSignalFD) } }
        let clockFormatStyle = ShellFormatting.clockStyle()
        let actionDispatcher = ShellActionDispatcher()
        guard let renderWake = ShellRenderWakeSink() else { return nil }
        guard
            let desktopHost = NucleusDesktopHost(
                configuration: .init(
                    waylandSocketName: socketName,
                    connectedWaylandFileDescriptor:
                        waylandDescriptor,
                    enableVulkanValidation:
                        configuration.enableVulkanValidation),
                asyncRenderWakeSink: renderWake)
        else {
            return nil
        }
        self.exitSignalFD = exitSignalFD
        self.desktopHost = desktopHost
        self.client = desktopHost.wayland
        self.reactor = desktopHost.reactor
        self.engine = desktopHost.renderer
        self.renderWake = renderWake
        self.clockFormatStyle = clockFormatStyle
        self.actionDispatcher = actionDispatcher
        self.liveConfiguration = liveConfiguration
        self.configurationEpoch = configurationEpoch
        self.configurationGeneration = configurationGeneration
        self.configurationChannel = configurationChannel
        self.policyChannel = policyChannel
        self.resourceHost = desktopHost.resourceHost
        self.retainedStore = desktopHost.retainedStore
        self.hostBundle = desktopHost.applicationHost
        self.textSystem = desktopHost.textSystem
        self.wallpaperPath = ShellFormatting.wallpaperPath(
            configuredPath: configuration.wallpaperPath,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        closeLocalSignalFD = false
    }

    deinit {
        close(exitSignalFD)
    }
}
