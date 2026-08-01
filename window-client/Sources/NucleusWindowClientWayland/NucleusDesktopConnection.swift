// The desktop Wayland client policy over swift-wayland's typed client layer.

import NucleusWindowClientContracts
package import WaylandClient
package import WaylandClientDispatch
import WaylandProtocolTypes
import WaylandProtocolsC

/// A live `wl_output` the desktop client can anchor surfaces to.
@MainActor
@safe public final class NucleusDesktopOutput {
    let proxy: WaylandProxy<WlOutputClient>
    package let registryName: UInt32
    package var logicalWidth: Int32 = 0
    package var logicalHeight: Int32 = 0
    package var logicalX: Int32 = 0
    package var logicalY: Int32 = 0
    package var scale: Int32 = 1
    package var name: String = ""
    package var refreshMillihertz: Int32 = 0
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
package final class NucleusDesktopConnection {
    private let connection: WaylandConnection
    private var registry: WaylandRegistry?
    private var seatEventBroker: NucleusDesktopSeatEventBroker?

    @unsafe
    package func withUnsafeNativeDisplay<Result>(
        _ body: (OpaquePointer) throws -> Result
    ) rethrows -> Result {
        try unsafe body(connection.display)
    }

    package private(set) var compositor: WaylandProxy<WlCompositorClient>?
    package private(set) var subcompositor: WaylandProxy<WlSubcompositorClient>?
    package private(set) var shm: WaylandProxy<WlShmClient>?
    package private(set) var seat: WaylandProxy<WlSeatClient>?
    package private(set) var layerShell: WaylandProxy<ZwlrLayerShellV1Client>?
    package private(set) var foreignToplevel: WaylandProxy<ZwlrForeignToplevelManagerV1Client>?
    package private(set) var sessionLock: WaylandProxy<ExtSessionLockManagerV1Client>?
    package private(set) var screencopy: WaylandProxy<ZwlrScreencopyManagerV1Client>?
    package private(set) var viewporter: WaylandProxy<WpViewporterClient>?
    package private(set) var fractionalScale: WaylandProxy<WpFractionalScaleManagerV1Client>?
    package private(set) var xdgOutput: WaylandProxy<ZxdgOutputManagerV1Client>?
    package private(set) var textInputManager: WaylandProxy<ZwpTextInputManagerV3Client>?
    package private(set) var cursorShape: WaylandProxy<WpCursorShapeManagerV1Client>?
    package private(set) var dataControl: WaylandProxy<ExtDataControlManagerV1Client>?
    package private(set) var dataDeviceManager: WaylandProxy<WlDataDeviceManagerClient>?
    package private(set) var windowManagement: WaylandProxy<XdgWmBaseClient>?
    package private(set) var dmaBuf: WaylandProxy<ZwpLinuxDmabufV1Client>?
    package private(set) var drmSyncobj: WaylandProxy<WpLinuxDrmSyncobjManagerV1Client>?
    package private(set) var presentation: WaylandProxy<WpPresentationClient>?
    package private(set) var idleNotifier: WaylandProxy<ExtIdleNotifierV1Client>?
    package private(set) var alphaModifier: WaylandProxy<WpAlphaModifierV1Client>?
    package private(set) var dmaBufFormats: [NucleusDesktopDmaBufFormat] = []
    package private(set) var dmaBufMainDevice: UInt64?
    private var dmaBufFeedback: NucleusDesktopDmaBufFeedback?

    package private(set) var outputs: [UInt32: NucleusDesktopOutput] = [:]
    package private(set) var capabilities: [NucleusDesktopCapabilityKind: NucleusDesktopCapability] =
        [:]

    package var onReady: (() -> Void)?
    package var onOutputsChanged: (() -> Void)?
    package var onGlobalChanged: ((NucleusDesktopCapabilityKind) -> Void)?
    package var onLifecycleEvent: ((NucleusDesktopLifecycleEvent) -> Void)?

    private var nextCapabilityGeneration: UInt64 = 1
    private var disconnected = false

    package convenience init?(socketName: String? = nil) {
        guard let connection = WaylandConnection(socket: socketName) else {
            return nil
        }
        self.init(
            connection: connection,
            performInitialRoundtrips: true)
    }

    package convenience init?(
        connectedFileDescriptor: Int32,
        performInitialRoundtrips: Bool = false
    ) {
        guard
            let connection = WaylandConnection(
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
        guard
            let registry = WaylandRegistry(
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

    package var fd: Int32 {
        connection.fd
    }

    @discardableResult
    package func flush() -> Int32 {
        connection.flush()
    }

    package func prepareRead() -> WaylandReadPreparation? {
        connection.prepareRead()
    }

    package func capability(
        for kind: NucleusDesktopCapabilityKind
    ) -> NucleusDesktopCapability? {
        capabilities[kind]
    }

    package func markCompositorDisconnected() {
        guard !disconnected else { return }
        disconnected = true
        for capability in capabilities.values {
            capability.invalidate()
        }
        capabilities.removeAll(keepingCapacity: false)
        onLifecycleEvent?(.compositorDisconnected)
    }

    package func createSurface()
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
                    self.dmaBufMainDevice = nil
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
            },
            onMainDeviceChanged: { [weak self] device in
                self?.dmaBufMainDevice = device
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
        onLifecycleEvent?(
            .capabilityUnavailable(
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
    package func ping(
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
    package func geometry(
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

    package func mode(
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

    package func done(
        _ proxy: WaylandBorrowedProxy<WlOutputClient>
    ) {
        onChanged?()
    }

    package func scale(
        _ proxy: WaylandBorrowedProxy<WlOutputClient>,
        factor: Int32
    ) {
        self.scale = factor
    }

    package func name(
        _ proxy: WaylandBorrowedProxy<WlOutputClient>,
        name: String
    ) {
        self.name = name
    }

    package func description(
        _ proxy: WaylandBorrowedProxy<WlOutputClient>,
        description: String
    ) {}
}
