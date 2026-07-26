// The shell's Wayland client policy over swift-wayland's typed client layer.

public import WaylandClientDispatch
import WaylandProtocolTypes
public import WaylandClient
import WaylandProtocolsC

/// A singleton Wayland global whose availability can change at runtime.
public enum WaylandGlobalKind: String {
    case compositor = "wl_compositor"
    case shm = "wl_shm"
    case output = "wl_output"
    case seat = "wl_seat"
    case layerShell = "zwlr_layer_shell_v1"
    case foreignToplevel = "zwlr_foreign_toplevel_manager_v1"
    case sessionLock = "ext_session_lock_manager_v1"
    case screencopy = "zwlr_screencopy_manager_v1"
    case viewporter = "wp_viewporter"
    case fractionalScale = "wp_fractional_scale_manager_v1"
    case xdgOutput = "zxdg_output_manager_v1"
    case textInputManager = "zwp_text_input_manager_v3"
    case cursorShape = "wp_cursor_shape_manager_v1"
    case dataControl = "ext_data_control_manager_v1"
    case dataDeviceManager = "wl_data_device_manager"
}

/// A live `wl_output` the shell can anchor surfaces to.
@MainActor
@safe public final class WaylandOutput {
    public let proxy: WaylandProxy<WlOutputClient>
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
public final class ShellWaylandClient {
    private let connection: WaylandConnection
    private var registry: WaylandRegistry?
    private var seatEventBroker: ShellSeatEventBroker?

    public private(set) var compositor:
        WaylandProxy<WlCompositorClient>?
    public private(set) var shm: WaylandProxy<WlShmClient>?
    public private(set) var seat: WaylandProxy<WlSeatClient>?
    public private(set) var layerShell:
        WaylandProxy<ZwlrLayerShellV1Client>?
    public private(set) var foreignToplevel:
        WaylandProxy<ZwlrForeignToplevelManagerV1Client>?
    public private(set) var sessionLock:
        WaylandProxy<ExtSessionLockManagerV1Client>?
    public private(set) var screencopy:
        WaylandProxy<ZwlrScreencopyManagerV1Client>?
    public private(set) var viewporter:
        WaylandProxy<WpViewporterClient>?
    public private(set) var fractionalScale:
        WaylandProxy<WpFractionalScaleManagerV1Client>?
    public private(set) var xdgOutput:
        WaylandProxy<ZxdgOutputManagerV1Client>?
    public private(set) var textInputManager:
        WaylandProxy<ZwpTextInputManagerV3Client>?
    public private(set) var cursorShape:
        WaylandProxy<WpCursorShapeManagerV1Client>?
    public private(set) var dataControl:
        WaylandProxy<ExtDataControlManagerV1Client>?
    public private(set) var dataDeviceManager:
        WaylandProxy<WlDataDeviceManagerClient>?

    public private(set) var outputs: [UInt32: WaylandOutput] = [:]

    public var onReady: (() -> Void)?
    public var onOutputsChanged: (() -> Void)?
    public var onGlobalChanged: ((WaylandGlobalKind) -> Void)?

    public convenience init?(socketName: String? = nil) {
        guard let connection = WaylandConnection(socket: socketName) else {
            return nil
        }
        self.init(
            connection: connection,
            performInitialRoundtrips: true)
    }

    public convenience init?(connectedFileDescriptor: Int32) {
        guard let connection = WaylandConnection(
            fd: connectedFileDescriptor)
        else {
            return nil
        }
        self.init(
            connection: connection,
            performInitialRoundtrips: false)
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
                WlShmClient.self,
                maximumVersion: 1,
                kind: .shm,
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
                kind: .xdgOutput,
                at: \.xdgOutput),
            singleton(
                ZwpTextInputManagerV3Client.self,
                maximumVersion: 2,
                kind: .textInputManager,
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
                kind: .dataDeviceManager,
                at: \.dataDeviceManager),
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

    /// The native display required by `VK_KHR_wayland_surface`.
    @unsafe public var display: OpaquePointer {
        unsafe connection.display
    }

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
        kind: WaylandGlobalKind,
        at keyPath: ReferenceWritableKeyPath<
            ShellWaylandClient,
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
                        try? ShellSeatEventBroker(proxy: seat)
                }
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
                self.onGlobalChanged?(kind)
            })
    }

    private func outputRequirement() -> DesiredGlobal<WlOutputClient> {
        DesiredGlobal(
            maximumVersion: 3,
            allowsMultiple: true,
            onBind: { [weak self] global in
                guard let self else { return }
                let output = WaylandOutput(
                    proxy: global.proxy,
                    registryName: global.name)
                output.onChanged = { [weak self] in
                    self?.onOutputsChanged?()
                }
                outputs[global.name] = output
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
                onOutputsChanged?()
            })
    }

    func attachSeatConsumer(_ seat: ShellSeat) -> Bool {
        guard let seatEventBroker else { return false }
        seatEventBroker.attach(seat)
        return true
    }

    func detachSeatConsumer(_ seat: ShellSeat) {
        seatEventBroker?.detach(seat)
    }
}

@MainActor
private final class ShellSeatEventBroker: WlSeatEvents {
    private weak var consumer: ShellSeat?
    private var capabilities: WlSeatCapability?

    init(proxy: WaylandProxy<WlSeatClient>)
        throws(WaylandProxyError)
    {
        try proxy.installListener(self)
    }

    func attach(_ consumer: ShellSeat) {
        self.consumer = consumer
        if let capabilities {
            consumer.bindPointerIfNeeded(capabilities)
            consumer.bindKeyboardIfNeeded(capabilities)
        }
    }

    func detach(_ expected: ShellSeat? = nil) {
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

extension WaylandOutput: WlOutputEvents {
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
