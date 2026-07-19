// The shell's Wayland client: policy over swift-wayland's ergonomic client layer. WaylandConnection
// owns the wl_display + loop and WaylandRegistry does the generic global binding; this class supplies
// the shell's policy — WHICH globals it wants (WaylandGlobalKind), the per-output model it wraps each
// wl_output in, and the onReady / onOutputsChanged hooks the host drives its surfaces from.
//
// The client counterpart to the compositor's server substrate: where the compositor CREATES globals
// and answers binds, the shell CONNECTS, enumerates the registry, and binds the globals it consumes.

import WaylandClientC
import WaylandClientDispatch
import WaylandClient
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

    /// The interface descriptor pointer the client binds against (from the generated accessors).
    var interface: UnsafePointer<wl_interface>? {
        switch self {
        case .compositor: return swift_wayland_iface_wl_compositor()
        case .shm: return swift_wayland_iface_wl_shm()
        case .output: return swift_wayland_iface_wl_output()
        case .seat: return swift_wayland_iface_wl_seat()
        case .layerShell: return swift_wayland_iface_zwlr_layer_shell_v1()
        case .foreignToplevel: return swift_wayland_iface_zwlr_foreign_toplevel_manager_v1()
        case .sessionLock: return swift_wayland_iface_ext_session_lock_manager_v1()
        case .screencopy: return swift_wayland_iface_zwlr_screencopy_manager_v1()
        case .viewporter: return swift_wayland_iface_wp_viewporter()
        case .fractionalScale: return swift_wayland_iface_wp_fractional_scale_manager_v1()
        case .xdgOutput: return swift_wayland_iface_zxdg_output_manager_v1()
        case .textInputManager: return swift_wayland_iface_zwp_text_input_manager_v3()
        case .cursorShape: return swift_wayland_iface_wp_cursor_shape_manager_v1()
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
        case .textInputManager: return 1
        case .cursorShape: return 1
        }
    }

    /// Reverse lookup from the interface descriptor a WaylandRegistry bound (pointer-identical).
    static func from(interface: UnsafePointer<wl_interface>) -> WaylandGlobalKind? {
        allCases.first { $0.interface == interface }
    }
}

/// A live wl_output the shell can anchor surfaces to.
public final class WaylandOutput {
    public let proxy: OpaquePointer
    public let registryName: UInt32
    public var logicalWidth: Int32 = 0
    public var logicalHeight: Int32 = 0
    public var scale: Int32 = 1
    public var name: String = ""

    init(proxy: OpaquePointer, registryName: UInt32) {
        self.proxy = proxy
        self.registryName = registryName
    }
}

@MainActor
public final class ShellWaylandClient {
    private let connection: WaylandConnection
    private var registry: WaylandRegistry!

    /// Singleton-bound globals (one instance each).
    public private(set) var globals: [WaylandGlobalKind: BoundGlobal] = [:]
    /// wl_outputs (multi-instance), keyed by registry name.
    public private(set) var outputs: [UInt32: WaylandOutput] = [:]

    /// Called after the initial registry roundtrips complete. The host creates its surfaces here.
    public var onReady: (() -> Void)?
    /// Fired when an output is added/removed so the shell can (re)place per-output surfaces.
    public var onOutputsChanged: (() -> Void)?

    public init?(socketName: String? = nil) {
        guard let conn = WaylandConnection(socket: socketName) else { return nil }
        connection = conn

        let wanted: [DesiredGlobal] = WaylandGlobalKind.allCases.compactMap { kind in
            kind.interface.map { DesiredGlobal($0, maxVersion: kind.bindVersion,
                                               allowsMultiple: kind == .output) }
        }
        guard let reg = WaylandRegistry(conn, wanting: wanted) else { return nil }
        registry = reg
        reg.onBind = { [weak self] in self?.bound($0) }
        reg.onRemove = { [weak self] in self?.removed($0) }

        // Two roundtrips: the first surfaces the globals (bind fires onBind), the second drains their
        // initial events (output geometry/mode, etc.) so geometry is known before onReady.
        connection.roundtrip()
        connection.roundtrip()
        onReady?()
    }

    // WaylandConnection disconnects the display in its own deinit; nothing to tear down here.
    isolated deinit {}

    /// The raw wl_display, for the render backend's VK_KHR_wayland_surface swapchain.
    public var display: OpaquePointer { connection.display }

    /// The display fd, for poll()-based loop integration.
    public var fd: Int32 { connection.fd }

    /// Drain queued events (call after poll() reports the fd readable).
    @discardableResult
    public func dispatch() -> Int32 { connection.dispatch() }

    /// Apply pending requests and flush them to the compositor (call at end of each frame).
    public func flush() { connection.flush() }

    /// Block until the server has processed all issued requests (used at setup time).
    public func roundtrip() { _ = connection.roundtrip() }

    public func proxy(_ kind: WaylandGlobalKind) -> OpaquePointer? { globals[kind]?.proxy }

    /// Create a bare wl_surface from the bound compositor (the drawing surface a role —
    /// layer-shell, session-lock — is then assigned to).
    public func createSurface() -> OpaquePointer? {
        guard let compositor = proxy(.compositor) else { return nil }
        return wl_compositor_create_surface(compositor)
    }

    // MARK: - Registry callbacks (main-actor, from WaylandRegistry)

    private func bound(_ global: BoundGlobal) {
        guard let kind = WaylandGlobalKind.from(interface: global.interface) else { return }
        if kind == .output {
            let output = WaylandOutput(proxy: global.proxy, registryName: global.name)
            outputs[global.name] = output
            // The per-output object is the owner; `outputs` keeps it alive for the proxy's lifetime.
            WlOutputClient.addListener(output.proxy, owner: output)
            onOutputsChanged?()
        } else if globals[kind] == nil {
            globals[kind] = global
        }
    }

    private func removed(_ global: BoundGlobal) {
        if outputs[global.name] != nil {
            outputs[global.name] = nil
            onOutputsChanged?()
        }
    }
}

// A wl_output's events land on its own per-output owner object (not @MainActor), so its geometry
// fields are updated directly; the name string is decoded in-place.
extension WaylandOutput: WlOutputEvents {
    public nonisolated func geometry(_ proxy: OpaquePointer, x: Int32, y: Int32, physical_width: Int32, physical_height: Int32, subpixel: Int32, make: UnsafePointer<CChar>?, model: UnsafePointer<CChar>?, transform: Int32) {}
    public nonisolated func mode(_ proxy: OpaquePointer, flags: UInt32, width: Int32, height: Int32, refresh: Int32) {
        logicalWidth = width
        logicalHeight = height
    }
    public nonisolated func done(_ proxy: OpaquePointer) {}
    public nonisolated func scale(_ proxy: OpaquePointer, factor: Int32) {
        self.scale = factor
    }
    public nonisolated func name(_ proxy: OpaquePointer, name: UnsafePointer<CChar>?) {
        guard let name else { return }
        self.name = String(cString: name)
    }
    public nonisolated func description(_ proxy: OpaquePointer, description: UnsafePointer<CChar>?) {}
}
