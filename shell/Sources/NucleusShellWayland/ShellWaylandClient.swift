// The shell's Wayland client: policy over swift-wayland's ergonomic client layer. WaylandConnection
// owns the wl_display + loop and WaylandRegistry does the generic global binding; this class supplies
// the shell's policy — WHICH globals it wants (WaylandGlobalKind), the per-output model it wraps each
// wl_output in, and the onReady / onOutputsChanged hooks the host drives its surfaces from.
//
// The client counterpart to the compositor's server substrate: where the compositor CREATES globals
// and answers binds, the shell CONNECTS, enumerates the registry, and binds the globals it consumes.

import WaylandClientC
public import WaylandClientDispatch
import WaylandProtocolTypes
public import WaylandClient
import WaylandProtocolsC  // links the shared marshalling tables
#if canImport(Glibc)
import Glibc
#endif

/// A Wayland global the shell binds, keyed by its interface name. Extend as protocols are added.
public enum WaylandGlobalKind: String, CaseIterable {
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

    /// The interface descriptor pointer the client binds against (from the generated accessors).
    var interface: UnsafePointer<wl_interface>? {
        switch self {
        case .compositor: return unsafe swift_wayland_iface_wl_compositor()
        case .shm: return unsafe swift_wayland_iface_wl_shm()
        case .output: return unsafe swift_wayland_iface_wl_output()
        case .seat: return unsafe swift_wayland_iface_wl_seat()
        case .layerShell: return unsafe swift_wayland_iface_zwlr_layer_shell_v1()
        case .foreignToplevel: return unsafe swift_wayland_iface_zwlr_foreign_toplevel_manager_v1()
        case .sessionLock: return unsafe swift_wayland_iface_ext_session_lock_manager_v1()
        case .screencopy: return unsafe swift_wayland_iface_zwlr_screencopy_manager_v1()
        case .viewporter: return unsafe swift_wayland_iface_wp_viewporter()
        case .fractionalScale: return unsafe swift_wayland_iface_wp_fractional_scale_manager_v1()
        case .xdgOutput: return unsafe swift_wayland_iface_zxdg_output_manager_v1()
        case .textInputManager: return unsafe swift_wayland_iface_zwp_text_input_manager_v3()
        case .cursorShape: return unsafe swift_wayland_iface_wp_cursor_shape_manager_v1()
        case .dataControl: return unsafe swift_wayland_iface_ext_data_control_manager_v1()
        case .dataDeviceManager:
            return unsafe swift_wayland_iface_wl_data_device_manager()
        }
    }

    /// The protocol version the shell binds. Kept conservative; raise as drivers grow.
    var bindVersion: UInt32 {
        switch self {
        case .compositor: return 4
        case .shm: return 1
        case .output: return 3
        case .seat: return 5
        case .layerShell: return 4
        case .foreignToplevel: return 3
        case .sessionLock: return 1
        case .screencopy: return 3
        case .viewporter: return 1
        case .fractionalScale: return 1
        case .xdgOutput: return 3
        case .textInputManager: return 2
        case .cursorShape: return 1
        case .dataControl: return 1
        case .dataDeviceManager: return 3
        }
    }

    /// Reverse lookup from the interface descriptor a WaylandRegistry bound (pointer-identical).
    static func from(interface: UnsafePointer<wl_interface>) -> WaylandGlobalKind? {
        allCases.first { kind in unsafe kind.interface == interface }
    }
}

/// A live wl_output the shell can anchor surfaces to.
@MainActor
@safe public final class WaylandOutput {
    public let proxy: OpaquePointer
    public let registryName: UInt32
    public var logicalWidth: Int32 = 0
    public var logicalHeight: Int32 = 0
    public var logicalX: Int32 = 0
    public var logicalY: Int32 = 0
    public var scale: Int32 = 1
    public var name: String = ""
    /// Current mode refresh in millihertz, as reported by wl_output.mode.
    public var refreshMillihertz: Int32 = 0
    var onChanged: (() -> Void)?

    init(proxy: OpaquePointer, registryName: UInt32) {
        unsafe self.proxy = proxy
        self.registryName = registryName
    }
}

@MainActor
public final class ShellWaylandClient {
    private let connection: WaylandConnection
    private var registry: WaylandRegistry!
    private var seatEventBroker: ShellSeatEventBroker?

    /// Singleton-bound globals (one instance each).
    public private(set) var globals: [WaylandGlobalKind: BoundGlobal] = [:]
    /// wl_outputs (multi-instance), keyed by registry name.
    public private(set) var outputs: [UInt32: WaylandOutput] = [:]

    /// Called after the initial registry roundtrips complete. The host creates its surfaces here.
    public var onReady: (() -> Void)?
    /// Fired when an output is added/removed so the shell can (re)place per-output surfaces.
    public var onOutputsChanged: (() -> Void)?
    /// Fired after a singleton global is bound or removed.
    public var onGlobalChanged: ((WaylandGlobalKind) -> Void)?

    public convenience init?(socketName: String? = nil) {
        guard let connection = WaylandConnection(socket: socketName) else {
            return nil
        }
        self.init(connection: connection, performInitialRoundtrips: true)
    }

    /// Adopt a connected endpoint without a blocking setup roundtrip.
    ///
    /// The caller drives prepared reads until the registry has arrived.
    /// This is the deterministic in-process fixture seam; production socket
    /// connections use `init(socketName:)`.
    public convenience init?(connectedFileDescriptor: Int32) {
        guard let connection = WaylandConnection(fd: connectedFileDescriptor)
        else { return nil }
        self.init(connection: connection, performInitialRoundtrips: false)
    }

    private init?(
        connection: WaylandConnection,
        performInitialRoundtrips: Bool
    ) {
        self.connection = connection

        let wanted: [DesiredGlobal] = WaylandGlobalKind.allCases.compactMap { kind in
            guard let interface = unsafe kind.interface else { return nil }
            return unsafe DesiredGlobal(
                interface,
                maxVersion: kind.bindVersion,
                allowsMultiple: kind == .output)
        }
        guard let reg = WaylandRegistry(connection, wanting: wanted) else {
            return nil
        }
        registry = reg
        reg.onBind = { [weak self] in self?.bound($0) }
        reg.onRemove = { [weak self] in self?.removed($0) }

        if performInitialRoundtrips {
            // The first roundtrip surfaces globals; the second drains initial
            // per-global state such as output geometry.
            connection.bootstrapRoundtrip()
            connection.bootstrapRoundtrip()
            onReady?()
        }
    }

    // WaylandConnection disconnects the display in its own deinit; nothing to tear down here.
    isolated deinit {}

    /// The raw wl_display, for the render backend's VK_KHR_wayland_surface swapchain.
    public var display: OpaquePointer { unsafe connection.display }

    /// The display fd registered with the Linux host reactor.
    public var fd: Int32 { connection.fd }

    /// Apply pending requests and flush them to the compositor (call at end of each frame).
    @discardableResult
    public func flush() -> Int32 { connection.flush() }

    /// Prepare the one display read that the host reactor must complete or cancel.
    public func prepareRead() -> WaylandReadPreparation? {
        connection.prepareRead()
    }

    public func proxy(_ kind: WaylandGlobalKind) -> OpaquePointer? {
        unsafe globals[kind]?.proxy
    }

    /// Create a bare wl_surface from the bound compositor (the drawing surface a role —
    /// layer-shell, session-lock — is then assigned to).
    public func createSurface() -> OpaquePointer? {
        guard let compositor = unsafe proxy(.compositor) else { return nil }
        return unsafe wl_compositor_create_surface(compositor)
    }

    // MARK: - Registry callbacks (main-actor, from WaylandRegistry)

    private func bound(_ global: BoundGlobal) {
        guard let kind = unsafe WaylandGlobalKind.from(interface: global.interface) else { return }
        if kind == .output {
            let output = unsafe WaylandOutput(proxy: global.proxy, registryName: global.name)
            output.onChanged = { [weak self] in
                self?.onOutputsChanged?()
            }
            outputs[global.name] = output
            // The per-output object is the owner; `outputs` keeps it alive for the proxy's lifetime.
            unsafe WlOutputClient.addListener(output.proxy, owner: output)
            onOutputsChanged?()
        } else if globals[kind] == nil {
            globals[kind] = global
            if kind == .seat {
                seatEventBroker = unsafe ShellSeatEventBroker(proxy: global.proxy)
            }
            onGlobalChanged?(kind)
        }
    }

    private func removed(_ global: BoundGlobal) {
        if outputs[global.name] != nil {
            outputs[global.name] = nil
            onOutputsChanged?()
            return
        }
        guard let kind = unsafe WaylandGlobalKind.from(interface: global.interface),
              globals[kind]?.name == global.name
        else {
            return
        }
        globals.removeValue(forKey: kind)
        if kind == .seat {
            seatEventBroker?.detach()
            seatEventBroker = nil
        }
        onGlobalChanged?(kind)
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

/// Owns the one listener libwayland permits on `wl_seat` from the moment the
/// registry binds it. `ShellSeat` may be constructed after the initial
/// roundtrip; the broker replays the latest capability snapshot instead of
/// losing that one-shot event.
@MainActor
private final class ShellSeatEventBroker: WlSeatEvents {
    private weak var consumer: ShellSeat?
    private var capabilities: WlSeatCapability?

    init(proxy: OpaquePointer) {
        unsafe WlSeatClient.addListener(proxy, owner: self)
    }

    func attach(_ consumer: ShellSeat) {
        self.consumer = consumer
        if let capabilities {
            consumer.bindPointerIfNeeded(capabilities.rawValue)
            consumer.bindKeyboardIfNeeded(capabilities.rawValue)
        }
    }

    func detach(_ expected: ShellSeat? = nil) {
        guard expected == nil || consumer === expected else { return }
        consumer = nil
    }

    nonisolated func capabilities(
        _ proxy: WaylandBorrowedProxy<WlSeatClient>,
        capabilities: WlSeatCapability
    ) {
        MainActor.assumeIsolated {
            self.capabilities = capabilities
            consumer?.bindPointerIfNeeded(capabilities.rawValue)
            consumer?.bindKeyboardIfNeeded(capabilities.rawValue)
        }
    }

    nonisolated func name(
        _ proxy: WaylandBorrowedProxy<WlSeatClient>,
        name: String
    ) {}
}

// A wl_output's events land on its own per-output owner object (not @MainActor), so its geometry
// fields are updated directly; the name string is decoded in-place.
extension WaylandOutput: WlOutputEvents {
    public nonisolated func geometry(_ proxy: WaylandBorrowedProxy<WlOutputClient>, x: Int32, y: Int32, physical_width: Int32, physical_height: Int32, subpixel: WlOutputSubpixel, make: String, model: String, transform: WlOutputTransform) {
        MainActor.assumeIsolated {
            logicalX = x
            logicalY = y
        }
    }
    public nonisolated func mode(_ proxy: WaylandBorrowedProxy<WlOutputClient>, flags: WlOutputMode, width: Int32, height: Int32, refresh: Int32) {
        MainActor.assumeIsolated {
            // Other advertised modes are alternatives, not current geometry.
            guard flags.contains(.current) else { return }
            logicalWidth = width
            logicalHeight = height
            refreshMillihertz = max(0, refresh)
        }
    }
    public nonisolated func done(_ proxy: WaylandBorrowedProxy<WlOutputClient>) {
        MainActor.assumeIsolated { onChanged?() }
    }
    public nonisolated func scale(_ proxy: WaylandBorrowedProxy<WlOutputClient>, factor: Int32) {
        MainActor.assumeIsolated { self.scale = factor }
    }
    public nonisolated func name(_ proxy: WaylandBorrowedProxy<WlOutputClient>, name: String) {
        MainActor.assumeIsolated { self.name = name }
    }
    public nonisolated func description(_ proxy: WaylandBorrowedProxy<WlOutputClient>, description: String) {}
}
