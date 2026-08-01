package import NucleusAppHostBundle
public import NucleusAppHostProtocols
import NucleusDiagnostics
package import NucleusLinuxReactor
package import NucleusRenderModel
import NucleusTextBackend
package import NucleusUI
public import NucleusWindowClientContracts
package import NucleusWindowClientRender
public import NucleusWindowClientWayland

public struct NucleusDesktopHostConfiguration: Sendable, Equatable {
    public var waylandSocketName: String?
    public var connectedWaylandFileDescriptor: Int32?
    public var enableVulkanValidation: Bool
    public var reactorQueueDepth: UInt32

    public init(
        waylandSocketName: String? = nil,
        connectedWaylandFileDescriptor: Int32? = nil,
        enableVulkanValidation: Bool = false,
        reactorQueueDepth: UInt32 = 256
    ) {
        self.waylandSocketName = waylandSocketName
        self.connectedWaylandFileDescriptor =
            connectedWaylandFileDescriptor
        self.enableVulkanValidation = enableVulkanValidation
        self.reactorQueueDepth = reactorQueueDepth
    }
}

/// The public Linux desktop host boundary.
///
/// This object owns one process-local Wayland connection, Linux reactor,
/// retained scene store, application host bundle, text system, and renderer.
/// Product frameworks compose policy and views around this host; they do not
/// construct client protocol or presentation implementations themselves.
@MainActor
public final class NucleusDesktopHost {
    package let wayland: NucleusDesktopConnection
    package let reactor: LinuxHostReactor
    package let resourceHost: SwiftResourceHost
    package let retainedStore: RetainedTreeStore
    package let applicationHost: NucleusAppHostBundle
    package let textSystem: TextSystem
    package let renderer: NucleusWindowClientRenderEngine

    public var capabilities: [NucleusDesktopCapabilityKind: NucleusDesktopCapability] {
        wayland.capabilities
    }

    public var onLifecycleEvent: ((NucleusDesktopLifecycleEvent) -> Void)?
    {
        get { wayland.onLifecycleEvent }
        set { wayland.onLifecycleEvent = newValue }
    }

    public func capability(
        for kind: NucleusDesktopCapabilityKind
    ) -> NucleusDesktopCapability? {
        wayland.capability(for: kind)
    }

    public func createWindow(
        configuration: NucleusDesktopWindowConfiguration
    ) throws(NucleusDesktopWindowError) -> NucleusDesktopWindow {
        try wayland.createWindow(configuration: configuration)
    }

    public func createPopup(
        parent: NucleusDesktopWindow,
        configuration: NucleusDesktopPopupConfiguration
    ) throws(NucleusDesktopWindowError) -> NucleusDesktopPopup {
        try wayland.createPopup(
            parent: parent,
            configuration: configuration)
    }

    public func createSubsurface(
        parent: NucleusDesktopWindow,
        configuration: NucleusDesktopSubsurfaceConfiguration = .init()
    ) throws(NucleusDesktopWindowError) -> NucleusDesktopSubsurface {
        try wayland.createSubsurface(
            parent: parent,
            configuration: configuration)
    }

    public func createSubsurface(
        parent: NucleusDesktopSubsurface,
        configuration: NucleusDesktopSubsurfaceConfiguration = .init()
    ) throws(NucleusDesktopWindowError) -> NucleusDesktopSubsurface {
        try wayland.createSubsurface(
            parent: parent,
            configuration: configuration)
    }

    public init?(
        configuration: NucleusDesktopHostConfiguration = .init(),
        asyncRenderWakeSink: any AsyncRenderWakeSink
    ) {
        let wayland: NucleusDesktopConnection?
        if let descriptor =
            configuration.connectedWaylandFileDescriptor
        {
            wayland = NucleusDesktopConnection(
                connectedFileDescriptor: descriptor,
                performInitialRoundtrips: true)
        } else {
            wayland = NucleusDesktopConnection(
                socketName: configuration.waylandSocketName)
        }
        guard let wayland,
            let reactor = try? LinuxHostReactor(
                queueDepth: configuration.reactorQueueDepth)
        else {
            return nil
        }

        let resourceHost = SwiftResourceHost()
        let retainedStore = RetainedTreeStore(resourceHost: resourceHost)
        let applicationHost = NucleusAppHostBundle(
            resourceHost: resourceHost)
        let textSystem = TextSystem()
        guard SkiaTextLayoutBackend.install(in: textSystem) else {
            NucleusLogger(subsystem: "desktop-host").error(
                "conflicting Graphite text borrow provider")
            return nil
        }
        guard
            let renderer = NucleusWindowClientRenderEngine(
                connection: wayland,
                enableValidation: configuration.enableVulkanValidation,
                store: retainedStore,
                resourceHost: resourceHost,
                asyncRenderWakeSink: asyncRenderWakeSink)
        else {
            return nil
        }

        self.wayland = wayland
        self.reactor = reactor
        self.resourceHost = resourceHost
        self.retainedStore = retainedStore
        self.applicationHost = applicationHost
        self.textSystem = textSystem
        self.renderer = renderer
    }
}
