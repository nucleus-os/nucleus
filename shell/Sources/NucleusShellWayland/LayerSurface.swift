// A wlr-layer-shell surface — the client role a shell panel (bar, dock, background, overlay)
// assigns to its wl_surface. Owns the configure handshake and the anchor/size/exclusive-zone
// policy; the actual pixels are presented by the render backend's Vulkan swapchain onto the
// wl_surface this wraps.
//
// Lifecycle: create wl_surface → get_layer_surface → set anchor/size/exclusive zone →
// commit with NO buffer (triggers the server's initial configure) → on configure, ack and
// report the size → the render backend sizes its swapchain and presents (the WSI does the
// buffer attach + commit). Resizes re-fire onConfigure.

public import WaylandClientDispatch
import WaylandProtocolTypes

/// Anchor edges (bitmask). A bar anchors top|left|right and spans the output width.
public extension ZwlrLayerSurfaceV1Anchor {
    static let bar: Self = [.top, .left, .right]
    static let all: Self = [.top, .bottom, .left, .right]
}

/// Configuration for a layer surface, decided by the panel before its first commit.
public struct LayerSurfaceConfig {
    public var layer: ZwlrLayerShellV1Layer
    public var anchor: ZwlrLayerSurfaceV1Anchor
    /// Logical size; 0 on an anchored axis means "span the anchored edges".
    public var width: UInt32
    public var height: UInt32
    /// Reserve this many logical px of work area on the anchored edge.
    /// `-1` ignores other exclusive zones and uses the complete output.
    public var exclusiveZone: Int32
    public var keyboard: ZwlrLayerSurfaceV1KeyboardInteractivity
    public var namespace: String

    public init(
        layer: ZwlrLayerShellV1Layer,
        anchor: ZwlrLayerSurfaceV1Anchor,
        width: UInt32,
        height: UInt32,
        exclusiveZone: Int32,
        keyboard: ZwlrLayerSurfaceV1KeyboardInteractivity = .none,
        namespace: String
    ) {
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

    /// A full-output background which remains behind exclusive shell chrome.
    public static func wallpaper(
        namespace: String = "nucleus-shell.wallpaper"
    ) -> LayerSurfaceConfig {
        LayerSurfaceConfig(
            layer: .background,
            anchor: .all,
            width: 0,
            height: 0,
            exclusiveZone: -1,
            keyboard: .none,
            namespace: namespace)
    }
}

@MainActor
@safe public final class LayerSurface {
    public let wlSurface: WaylandProxy<WlSurfaceClient>
    public let layerSurface:
        WaylandProxy<ZwlrLayerSurfaceV1Client>
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
        guard let layerShell = client.layerShell,
              let surface = try? client.createSurface()
        else {
            return nil
        }
        wlSurface = surface
        self.config = config
        self.output = output

        guard let layerSurface = try? layerShell.getLayerSurface(
            surface: surface,
            output: output?.proxy,
            layer: config.layer,
            namespace: config.namespace)
        else {
            try? surface.destroy()
            return nil
        }
        self.layerSurface = layerSurface

        do {
            try layerSurface.setAnchor(anchor: config.anchor)
            try layerSurface.setSize(
                width: config.width,
                height: config.height)
            try layerSurface.setExclusiveZone(
                zone: config.exclusiveZone)
            try layerSurface.setKeyboardInteractivity(
                keyboard_interactivity: config.keyboard)
            try layerSurface.installListener(self)
            try surface.commit()
        } catch {
            try? layerSurface.destroy()
            try? surface.destroy()
            return nil
        }
    }

    /// Update the reserved work area (e.g. when the bar height changes).
    public func setExclusiveZone(_ zone: Int32) {
        try? layerSurface.setExclusiveZone(zone: zone)
        try? wlSurface.commit()
    }

    public func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        try? layerSurface.destroy()
        try? wlSurface.destroy()
    }

    isolated deinit {
        destroy()
    }
}

extension LayerSurface: ZwlrLayerSurfaceV1Events {
    public func configure(_ proxy: WaylandBorrowedProxy<ZwlrLayerSurfaceV1Client>, serial: UInt32, width: UInt32, height: UInt32) {
        try? layerSurface.ackConfigure(serial: serial)
        acked = true
        configuredWidth = width
        configuredHeight = height
        onConfigure?(width, height)
    }
    public func closed(_ proxy: WaylandBorrowedProxy<ZwlrLayerSurfaceV1Client>) {
        onClosed?()
    }
}
