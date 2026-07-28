// The desktop Wayland client policy over swift-wayland's typed client layer.

public import WaylandClientDispatch
import WaylandProtocolTypes
public import WaylandClient
import WaylandProtocolsC
import NucleusWindowClientContracts

/// A live `wl_output` the desktop client can anchor surfaces to.
@MainActor
@safe public final class NucleusDesktopOutput {
    let proxy: WaylandProxy<WlOutputClient>
    public let registryName: UInt32
    public var logicalWidth: Int32 = 0
    public var logicalHeight: Int32 = 0
    public var logicalX: Int32 = 0
    public var logicalY: Int32 = 0
    public var scale: Int32 = 1
    public var name: String = ""
    public var refreshMillihertz: Int32 = 0
    var onChanged: (() -> Void)?

    init(
        proxy: WaylandProxy<WlOutputClient>,
        registryName: UInt32
    ) {
        self.proxy = proxy
        self.registryName = registryName
    }
}

@MainActor
public final class NucleusDesktopConnection {
    private let connection: WaylandConnection
    private var registry: WaylandRegistry?
    private var seatEventBroker: NucleusDesktopSeatEventBroker?

    @_spi(NucleusWindowClientImplementation)
    public private(set) var compositor:
        WaylandProxy<WlCompositorClient>?
    @_spi(NucleusWindowClientImplementation)
    public private(set) var subcompositor:
        WaylandProxy<WlSubcompositorClient>?
    @_spi(NucleusWindowClientImplementation)
    public private(set) var shm: WaylandProxy<WlShmClient>?
    @_spi(NucleusWindowClientImplementation)
    public private(set) var seat: WaylandProxy<WlSeatClient>?
    @_spi(NucleusWindowClientImplementation)
    public private(set) var layerShell:
        WaylandProxy<ZwlrLayerShellV1Client>?
    @_spi(NucleusWindowClientImplementation)
    public private(set) var foreignToplevel:
        WaylandProxy<ZwlrForeignToplevelManagerV1Client>?
    @_spi(NucleusWindowClientImplementation)
    public private(set) var sessionLock:
        WaylandProxy<ExtSessionLockManagerV1Client>?
    @_spi(NucleusWindowClientImplementation)
    public private(set) var screencopy:
        WaylandProxy<ZwlrScreencopyManagerV1Client>?
    @_spi(NucleusWindowClientImplementation)
    public private(set) var viewporter:
        WaylandProxy<WpViewporterClient>?
    @_spi(NucleusWindowClientImplementation)
    public private(set) var fractionalScale:
        WaylandProxy<WpFractionalScaleManagerV1Client>?
    @_spi(NucleusWindowClientImplementation)
    public private(set) var xdgOutput:
        WaylandProxy<ZxdgOutputManagerV1Client>?
    @_spi(NucleusWindowClientImplementation)
    public private(set) var textInputManager:
        WaylandProxy<ZwpTextInputManagerV3Client>?
    @_spi(NucleusWindowClientImplementation)
    public private(set) var cursorShape:
        WaylandProxy<WpCursorShapeManagerV1Client>?
    @_spi(NucleusWindowClientImplementation)
    public private(set) var dataControl:
        WaylandProxy<ExtDataControlManagerV1Client>?
    @_spi(NucleusWindowClientImplementation)
    public private(set) var dataDeviceManager:
        WaylandProxy<WlDataDeviceManagerClient>?
    @_spi(NucleusWindowClientImplementation)
    public private(set) var windowManagement:
        WaylandProxy<XdgWmBaseClient>?
    @_spi(NucleusWindowClientImplementation)
    public private(set) var dmaBuf:
        WaylandProxy<ZwpLinuxDmabufV1Client>?
    @_spi(NucleusWindowClientImplementation)
    public private(set) var drmSyncobj:
        WaylandProxy<WpLinuxDrmSyncobjManagerV1Client>?
    @_spi(NucleusWindowClientImplementation)
    public private(set) var presentation:
        WaylandProxy<WpPresentationClient>?
    @_spi(NucleusWindowClientImplementation)
    public private(set) var idleNotifier:
        WaylandProxy<ExtIdleNotifierV1Client>?
    @_spi(NucleusWindowClientImplementation)
    public private(set) var alphaModifier:
        WaylandProxy<WpAlphaModifierV1Client>?
    @_spi(NucleusWindowClientImplementation)
    public private(set) var dmaBufFormats:
        [NucleusDesktopDmaBufFormat] = []
    private var dmaBufFeedback: NucleusDesktopDmaBufFeedback?

    public private(set) var outputs: [UInt32: NucleusDesktopOutput] = [:]
    public private(set) var capabilities:
        [NucleusDesktopCapabilityKind: NucleusDesktopCapability] = [:]

    public var onReady: (() -> Void)?
    public var onOutputsChanged: (() -> Void)?
    public var onGlobalChanged: ((NucleusDesktopCapabilityKind) -> Void)?
    public var onLifecycleEvent: ((NucleusDesktopLifecycleEvent) -> Void)?

    private var nextCapabilityGeneration: UInt64 = 1
    private var disconnected = false

    public convenience init?(socketName: String? = nil) {
        guard let connection = WaylandConnection(socket: socketName) else {
            return nil
        }
        self.init(
            connection: connection,
            performInitialRoundtrips: true)
    }

    public convenience init?(
        connectedFileDescriptor: Int32,
        performInitialRoundtrips: Bool = false
    ) {
        guard let connection = WaylandConnection(
            fd: connectedFileDescriptor)
        else {
            return nil
        }
        self.init(
            connection: connection,
            performInitialRoundtrips: performInitialRoundtrips)
    }

    private init?(
        connection: WaylandConnection,
        performInitialRoundtrips: Bool
    ) {
        self.connection = connection

        let wanted: [AnyDesiredGlobal] = [
            singleton(
                WlCompositorClient.self,
                maximumVersion: 4,
                kind: .compositor,
                at: \.compositor),
            singleton(
                WlSubcompositorClient.self,
                maximumVersion: 1,
                kind: .subcompositor,
                at: \.subcompositor),
            singleton(
                WlShmClient.self,
                maximumVersion: 1,
                kind: .sharedMemory,
                at: \.shm),
            outputRequirement(),
            singleton(
                WlSeatClient.self,
                maximumVersion: 5,
                kind: .seat,
                at: \.seat),
            singleton(
                ZwlrLayerShellV1Client.self,
                maximumVersion: 4,
                kind: .layerShell,
                at: \.layerShell),
            singleton(
                ZwlrForeignToplevelManagerV1Client.self,
                maximumVersion: 3,
                kind: .foreignToplevel,
                at: \.foreignToplevel),
            singleton(
                ExtSessionLockManagerV1Client.self,
                maximumVersion: 1,
                kind: .sessionLock,
                at: \.sessionLock),
            singleton(
                ZwlrScreencopyManagerV1Client.self,
                maximumVersion: 3,
                kind: .screencopy,
                at: \.screencopy),
            singleton(
                WpViewporterClient.self,
                maximumVersion: 1,
                kind: .viewporter,
                at: \.viewporter),
            singleton(
                WpFractionalScaleManagerV1Client.self,
                maximumVersion: 1,
                kind: .fractionalScale,
                at: \.fractionalScale),
            singleton(
                ZxdgOutputManagerV1Client.self,
                maximumVersion: 3,
                kind: .outputDescription,
                at: \.xdgOutput),
            singleton(
                ZwpTextInputManagerV3Client.self,
                maximumVersion: 2,
                kind: .textInput,
                at: \.textInputManager),
            singleton(
                WpCursorShapeManagerV1Client.self,
                maximumVersion: 1,
                kind: .cursorShape,
                at: \.cursorShape),
            singleton(
                ExtDataControlManagerV1Client.self,
                maximumVersion: 1,
                kind: .dataControl,
                at: \.dataControl),
            singleton(
                WlDataDeviceManagerClient.self,
                maximumVersion: 3,
                kind: .dataDevice,
                at: \.dataDeviceManager),
            singleton(
                XdgWmBaseClient.self,
                maximumVersion: 6,
                kind: .windowManagement,
                at: \.windowManagement),
            singleton(
                ZwpLinuxDmabufV1Client.self,
                maximumVersion: 5,
                kind: .dmaBuf,
                at: \.dmaBuf),
            singleton(
                WpLinuxDrmSyncobjManagerV1Client.self,
                maximumVersion: 1,
                kind: .drmSyncobj,
                at: \.drmSyncobj),
            singleton(
                WpPresentationClient.self,
                maximumVersion: 2,
                kind: .presentationTiming,
                at: \.presentation),
            singleton(
                ExtIdleNotifierV1Client.self,
                maximumVersion: 2,
                kind: .idleNotification,
                at: \.idleNotifier),
            singleton(
                WpAlphaModifierV1Client.self,
                maximumVersion: 1,
                kind: .alphaModifier,
                at: \.alphaModifier),
        ]
        guard let registry = WaylandRegistry(
            connection,
            wanting: wanted)
        else {
            return nil
        }
        self.registry = registry

        if performInitialRoundtrips {
            connection.bootstrapRoundtrip()
            connection.bootstrapRoundtrip()
            onReady?()
        }
    }

    isolated deinit {}

    public var fd: Int32 {
        connection.fd
    }

    @discardableResult
    public func flush() -> Int32 {
        connection.flush()
    }

    public func prepareRead() -> WaylandReadPreparation? {
        connection.prepareRead()
    }

    public func capability(
        for kind: NucleusDesktopCapabilityKind
    ) -> NucleusDesktopCapability? {
        capabilities[kind]
    }

    public func markCompositorDisconnected() {
        guard !disconnected else { return }
        disconnected = true
        for capability in capabilities.values {
            capability.invalidate()
        }
        capabilities.removeAll(keepingCapacity: false)
        onLifecycleEvent?(.compositorDisconnected)
    }

    public func createSurface()
        throws(WaylandProxyError) -> WaylandProxy<WlSurfaceClient>
    {
        guard let compositor else {
            throw .destroyed
        }
        return try compositor.createSurface()
    }

    private func singleton<Interface: WaylandClientInterface>(
        _ interface: Interface.Type,
        maximumVersion: UInt32,
        kind: NucleusDesktopCapabilityKind,
        at keyPath: ReferenceWritableKeyPath<
            NucleusDesktopConnection,
            WaylandProxy<Interface>?
        >
    ) -> DesiredGlobal<Interface> {
        DesiredGlobal(
            maximumVersion: maximumVersion,
            onBind: { [weak self] bound in
                guard let self,
                      self[keyPath: keyPath] == nil
                else {
                    return
                }
                self[keyPath: keyPath] = bound.proxy
                if kind == .seat, let seat = self.seat {
                    self.seatEventBroker =
                        try? NucleusDesktopSeatEventBroker(proxy: seat)
                }
                if kind == .windowManagement,
                   let windowManagement = self.windowManagement
                {
                    try? windowManagement.installListener(self)
                }
                if kind == .dmaBuf, let dmaBuf = self.dmaBuf {
                    self.bindDmaBufFeedback(dmaBuf)
                }
                self.publishCapability(kind)
                self.onGlobalChanged?(kind)
            },
            onRemove: { [weak self] bound in
                guard let self,
                      self[keyPath: keyPath] === bound.proxy
                else {
                    return
                }
                self[keyPath: keyPath] = nil
                if kind == .seat {
                    self.seatEventBroker?.detach()
                    self.seatEventBroker = nil
                }
                if kind == .dmaBuf {
                    self.dmaBufFeedback = nil
                    self.dmaBufFormats = []
                }
                self.withdrawCapability(kind)
                self.onGlobalChanged?(kind)
            })
    }

    private func bindDmaBufFeedback(
        _ dmaBuf: WaylandProxy<ZwpLinuxDmabufV1Client>
    ) {
        guard let feedbackProxy = try? dmaBuf.getDefaultFeedback()
        else { return }
        let feedback = NucleusDesktopDmaBufFeedback(
            proxy: feedbackProxy,
            onFormatsChanged: { [weak self] formats in
                self?.dmaBufFormats = formats
                self?.onGlobalChanged?(.dmaBuf)
            })
        guard feedback.start() else { return }
        dmaBufFeedback = feedback
    }

    private func outputRequirement() -> DesiredGlobal<WlOutputClient> {
        DesiredGlobal(
            maximumVersion: 3,
            allowsMultiple: true,
            onBind: { [weak self] global in
                guard let self else { return }
                let output = NucleusDesktopOutput(
                    proxy: global.proxy,
                    registryName: global.name)
                output.onChanged = { [weak self] in
                    self?.onOutputsChanged?()
                }
                outputs[global.name] = output
                if outputs.count == 1 {
                    publishCapability(.output)
                }
                try? output.proxy.installListener(output)
                onOutputsChanged?()
            },
            onRemove: { [weak self] global in
                guard let self,
                      outputs[global.name]?.proxy === global.proxy
                else {
                    return
                }
                outputs[global.name] = nil
                if outputs.isEmpty {
                    withdrawCapability(.output)
                }
                onOutputsChanged?()
            })
    }

    private func publishCapability(_ kind: NucleusDesktopCapabilityKind) {
        capabilities[kind]?.invalidate()
        let capability = NucleusDesktopCapability(
            kind: kind,
            generation: nextCapabilityGeneration)
        nextCapabilityGeneration &+= 1
        capabilities[kind] = capability
        onLifecycleEvent?(.capabilityAvailable(capability))
    }

    private func withdrawCapability(_ kind: NucleusDesktopCapabilityKind) {
        guard let capability = capabilities.removeValue(forKey: kind) else {
            return
        }
        capability.invalidate()
        onLifecycleEvent?(.capabilityUnavailable(
            kind: kind,
            generation: capability.generation))
    }

    func attachSeatConsumer(_ seat: NucleusDesktopSeat) -> Bool {
        guard let seatEventBroker else { return false }
        seatEventBroker.attach(seat)
        return true
    }

    func detachSeatConsumer(_ seat: NucleusDesktopSeat) {
        seatEventBroker?.detach(seat)
    }
}

extension NucleusDesktopConnection: XdgWmBaseEvents {
    public func ping(
        _ proxy: WaylandBorrowedProxy<XdgWmBaseClient>,
        serial: UInt32
    ) {
        try? windowManagement?.pong(serial: serial)
    }
}

@MainActor
private final class NucleusDesktopSeatEventBroker: WlSeatEvents {
    private weak var consumer: NucleusDesktopSeat?
    private var capabilities: WlSeatCapability?

    init(proxy: WaylandProxy<WlSeatClient>)
        throws(WaylandProxyError)
    {
        try proxy.installListener(self)
    }

    func attach(_ consumer: NucleusDesktopSeat) {
        self.consumer = consumer
        if let capabilities {
            consumer.bindPointerIfNeeded(capabilities)
            consumer.bindKeyboardIfNeeded(capabilities)
        }
    }

    func detach(_ expected: NucleusDesktopSeat? = nil) {
        guard expected == nil || consumer === expected else { return }
        consumer = nil
    }

    func capabilities(
        _ proxy: WaylandBorrowedProxy<WlSeatClient>,
        capabilities: WlSeatCapability
    ) {
        self.capabilities = capabilities
        consumer?.bindPointerIfNeeded(capabilities)
        consumer?.bindKeyboardIfNeeded(capabilities)
    }

    func name(
        _ proxy: WaylandBorrowedProxy<WlSeatClient>,
        name: String
    ) {}
}

extension NucleusDesktopOutput: WlOutputEvents {
    public func geometry(
        _ proxy: WaylandBorrowedProxy<WlOutputClient>,
        x: Int32,
        y: Int32,
        physical_width: Int32,
        physical_height: Int32,
        subpixel: WlOutputSubpixel,
        make: String,
        model: String,
        transform: WlOutputTransform
    ) {
        logicalX = x
        logicalY = y
    }

    public func mode(
        _ proxy: WaylandBorrowedProxy<WlOutputClient>,
        flags: WlOutputMode,
        width: Int32,
        height: Int32,
        refresh: Int32
    ) {
        guard flags.contains(.current) else { return }
        logicalWidth = width
        logicalHeight = height
        refreshMillihertz = max(0, refresh)
    }

    public func done(
        _ proxy: WaylandBorrowedProxy<WlOutputClient>
    ) {
        onChanged?()
    }

    public func scale(
        _ proxy: WaylandBorrowedProxy<WlOutputClient>,
        factor: Int32
    ) {
        self.scale = factor
    }

    public func name(
        _ proxy: WaylandBorrowedProxy<WlOutputClient>,
        name: String
    ) {
        self.name = name
    }

    public func description(
        _ proxy: WaylandBorrowedProxy<WlOutputClient>,
        description: String
    ) {}
}
