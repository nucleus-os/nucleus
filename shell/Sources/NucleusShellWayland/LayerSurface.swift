// A wlr-layer-shell surface — the client role a shell panel (bar, dock, background, overlay)
// assigns to its wl_surface. Owns the configure handshake and the anchor/size/exclusive-zone
// policy; the actual pixels are presented by the render backend's Vulkan swapchain onto the
// wl_surface this wraps.
//
// Lifecycle: create wl_surface → get_layer_surface → set anchor/size/exclusive zone →
// commit with NO buffer (triggers the server's initial configure) → on configure, ack and
// report the size → the render backend sizes its swapchain and presents (the WSI does the
// buffer attach + commit). Resizes re-fire onConfigure.

import WaylandClientC
import WaylandClientDispatch

public enum LayerShellLayer: UInt32 {
    case background = 0
    case bottom = 1
    case top = 2
    case overlay = 3
}

/// Anchor edges (bitmask). A bar anchors top|left|right and spans the output width.
public struct LayerAnchor: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let top = LayerAnchor(rawValue: 1)
    public static let bottom = LayerAnchor(rawValue: 2)
    public static let left = LayerAnchor(rawValue: 4)
    public static let right = LayerAnchor(rawValue: 8)
    public static let bar: LayerAnchor = [.top, .left, .right]
}

public enum KeyboardInteractivity: UInt32 {
    case none = 0
    case exclusive = 1
    case onDemand = 2
}

/// Configuration for a layer surface, decided by the panel before its first commit.
public struct LayerSurfaceConfig {
    public var layer: LayerShellLayer
    public var anchor: LayerAnchor
    /// Logical size; 0 on an anchored axis means "span the anchored edges".
    public var width: UInt32
    public var height: UInt32
    /// Reserve this many logical px of work area on the anchored edge (-1 = honor size).
    public var exclusiveZone: Int32
    public var keyboard: KeyboardInteractivity
    public var namespace: String

    public init(layer: LayerShellLayer, anchor: LayerAnchor, width: UInt32, height: UInt32,
                exclusiveZone: Int32, keyboard: KeyboardInteractivity = .none, namespace: String) {
        self.layer = layer
        self.anchor = anchor
        self.width = width
        self.height = height
        self.exclusiveZone = exclusiveZone
        self.keyboard = keyboard
        self.namespace = namespace
    }

    /// A top bar: overlay-height strip anchored across the top, reserving `height` work area.
    public static func topBar(height: UInt32, namespace: String = "nucleus-shell.bar") -> LayerSurfaceConfig {
        LayerSurfaceConfig(layer: .top, anchor: .bar, width: 0, height: height,
                           exclusiveZone: Int32(height), keyboard: .none, namespace: namespace)
    }
}

@MainActor
public final class LayerSurface {
    public let wlSurface: OpaquePointer
    public let layerSurface: OpaquePointer
    public let config: LayerSurfaceConfig
    /// The output this panel is on (nil = compositor picks).
    public let output: WaylandOutput?

    /// The last configured pixel size (post-scale is applied by the render backend).
    public private(set) var configuredWidth: UInt32 = 0
    public private(set) var configuredHeight: UInt32 = 0

    /// Fired on each configure with the negotiated logical size. The render backend sizes
    /// its swapchain and presents in response.
    public var onConfigure: ((UInt32, UInt32) -> Void)?
    /// Fired when the compositor destroys the surface (output removed, session end).
    public var onClosed: (() -> Void)?

    private var acked = false
    private var isDestroyed = false

    public init?(client: ShellWaylandClient, config: LayerSurfaceConfig, output: WaylandOutput?) {
        guard let layerShell = client.proxy(.layerShell),
              let surface = client.createSurface() else { return nil }
        self.wlSurface = surface
        self.config = config
        self.output = output

        guard let ls = config.namespace.withCString({ nsPtr -> OpaquePointer? in
            zwlr_layer_shell_v1_get_layer_surface(
                layerShell, surface, output?.proxy, config.layer.rawValue, nsPtr)
        }) else {
            wl_surface_destroy(surface)
            return nil
        }
        self.layerSurface = ls

        zwlr_layer_surface_v1_set_anchor(ls, config.anchor.rawValue)
        zwlr_layer_surface_v1_set_size(ls, config.width, config.height)
        zwlr_layer_surface_v1_set_exclusive_zone(ls, config.exclusiveZone)
        zwlr_layer_surface_v1_set_keyboard_interactivity(ls, config.keyboard.rawValue)

        installListener()
        // Commit with no buffer to elicit the initial configure.
        wl_surface_commit(surface)
    }

    private func installListener() {
        ZwlrLayerSurfaceV1Client.addListener(layerSurface, owner: self)
    }

    /// Update the reserved work area (e.g. when the bar height changes).
    public func setExclusiveZone(_ zone: Int32) {
        zwlr_layer_surface_v1_set_exclusive_zone(layerSurface, zone)
        wl_surface_commit(wlSurface)
    }

    public func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        zwlr_layer_surface_v1_destroy(layerSurface)
        wl_surface_destroy(wlSurface)
    }

    isolated deinit {
        destroy()
    }
}

// The generated event dispatch is nonisolated (a @convention(c) libwayland callback); the shell
// pumps wl_display on its main-thread event loop, so each handler reasserts the main actor.
extension LayerSurface: ZwlrLayerSurfaceV1Events {
    public nonisolated func configure(_ proxy: OpaquePointer, serial: UInt32, width: UInt32, height: UInt32) {
        zwlr_layer_surface_v1_ack_configure(proxy, serial)  // C call; the proxy stays out of the actor hop
        MainActor.assumeIsolated {
            acked = true
            configuredWidth = width
            configuredHeight = height
            onConfigure?(width, height)
        }
    }
    public nonisolated func closed(_ proxy: OpaquePointer) {
        MainActor.assumeIsolated { onClosed?() }
    }
}
