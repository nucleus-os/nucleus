// A wlr-layer-shell surface — the client role a shell panel (bar, dock, background, overlay)
// assigns to its wl_surface. Owns the configure handshake and the anchor/size/exclusive-zone
// policy; the actual pixels are presented by the render backend's Vulkan swapchain onto the
// wl_surface this wraps.
//
// Lifecycle: create wl_surface → get_layer_surface → set anchor/size/exclusive zone →
// commit with NO buffer (triggers the server's initial configure) → on configure, ack and
// report the size → the render backend sizes its swapchain and presents (the WSI does the
// buffer attach + commit). Resizes re-fire onConfigure.

package import WaylandClientDispatch
import WaylandProtocolTypes

package enum NucleusDesktopLayer: Sendable, Equatable {
    case background
    case bottom
    case top
    case overlay
}

package struct NucleusDesktopLayerAnchors:
    OptionSet, Sendable, Equatable
{
    package let rawValue: UInt32

    package init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    package static let top = Self(rawValue: 1 << 0)
    package static let bottom = Self(rawValue: 1 << 1)
    package static let left = Self(rawValue: 1 << 2)
    package static let right = Self(rawValue: 1 << 3)
    package static let all: Self = [.top, .bottom, .left, .right]
}

package enum NucleusDesktopLayerKeyboardPolicy: Sendable, Equatable {
    case none
    case exclusive
    case onDemand
}

/// Configuration for a layer surface, decided by the panel before its first commit.
package struct NucleusDesktopLayerSurfaceConfiguration {
    package var layer: NucleusDesktopLayer
    package var anchor: NucleusDesktopLayerAnchors
    /// Logical size; 0 on an anchored axis means "span the anchored edges".
    package var width: UInt32
    package var height: UInt32
    /// Reserve this many logical px of work area on the anchored edge.
    /// `-1` ignores other exclusive zones and uses the complete output.
    package var exclusiveZone: Int32
    package var keyboard: NucleusDesktopLayerKeyboardPolicy
    package var namespace: String
    package var marginTop: Int32
    package var marginRight: Int32
    package var marginBottom: Int32
    package var marginLeft: Int32

    package init(
        layer: NucleusDesktopLayer,
        anchor: NucleusDesktopLayerAnchors,
        width: UInt32,
        height: UInt32,
        exclusiveZone: Int32,
        keyboard: NucleusDesktopLayerKeyboardPolicy = .none,
        namespace: String,
        marginTop: Int32 = 0,
        marginRight: Int32 = 0,
        marginBottom: Int32 = 0,
        marginLeft: Int32 = 0
    ) {
        self.layer = layer
        self.anchor = anchor
        self.width = width
        self.height = height
        self.exclusiveZone = exclusiveZone
        self.keyboard = keyboard
        self.namespace = namespace
        self.marginTop = marginTop
        self.marginRight = marginRight
        self.marginBottom = marginBottom
        self.marginLeft = marginLeft
    }

}

@MainActor
@safe public final class NucleusDesktopLayerSurface {
    package let wlSurface: WaylandProxy<WlSurfaceClient>
    package let layerSurface: WaylandProxy<ZwlrLayerSurfaceV1Client>
    package let config: NucleusDesktopLayerSurfaceConfiguration
    /// The output this panel is on (nil = compositor picks).
    package let output: NucleusDesktopOutput?

    /// The last configured pixel size (post-scale is applied by the render backend).
    package private(set) var configuredWidth: UInt32 = 0
    package private(set) var configuredHeight: UInt32 = 0

    /// Fired on each configure with the negotiated logical size. The render backend sizes
    /// its swapchain and presents in response.
    package var onConfigure: ((UInt32, UInt32) -> Void)?
    /// Fired when the compositor destroys the surface (output removed, session end).
    package var onClosed: (() -> Void)?

    private var acked = false
    private var isDestroyed = false

    package init?(
        client: NucleusDesktopConnection, config: NucleusDesktopLayerSurfaceConfiguration,
        output: NucleusDesktopOutput?
    ) {
        guard let layerShell = client.layerShell,
            let surface = try? client.createSurface()
        else {
            return nil
        }
        wlSurface = surface
        self.config = config
        self.output = output

        guard
            let layerSurface = try? layerShell.getLayerSurface(
                surface: surface,
                output: output?.proxy,
                layer: config.layer.protocolValue,
                namespace: config.namespace)
        else {
            try? surface.destroy()
            return nil
        }
        self.layerSurface = layerSurface

        do {
            try layerSurface.setAnchor(anchor: config.anchor.protocolValue)
            try layerSurface.setSize(
                width: config.width,
                height: config.height)
            try layerSurface.setExclusiveZone(
                zone: config.exclusiveZone)
            try layerSurface.setMargin(
                top: config.marginTop,
                right: config.marginRight,
                bottom: config.marginBottom,
                left: config.marginLeft)
            try layerSurface.setKeyboardInteractivity(
                keyboard_interactivity: config.keyboard.protocolValue)
            try layerSurface.installListener(self)
            try surface.commit()
        } catch {
            try? layerSurface.destroy()
            try? surface.destroy()
            return nil
        }
    }

    /// Update the reserved work area (e.g. when the bar height changes).
    package func setExclusiveZone(_ zone: Int32) {
        try? layerSurface.setExclusiveZone(zone: zone)
        try? wlSurface.commit()
    }

    package func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        try? layerSurface.destroy()
        try? wlSurface.destroy()
    }

    isolated deinit {
        destroy()
    }
}

extension NucleusDesktopLayer {
    fileprivate var protocolValue: ZwlrLayerShellV1Layer {
        switch self {
        case .background: .background
        case .bottom: .bottom
        case .top: .top
        case .overlay: .overlay
        }
    }
}

extension NucleusDesktopLayerAnchors {
    fileprivate var protocolValue: ZwlrLayerSurfaceV1Anchor {
        var value: ZwlrLayerSurfaceV1Anchor = []
        if contains(.top) { value.insert(.top) }
        if contains(.bottom) { value.insert(.bottom) }
        if contains(.left) { value.insert(.left) }
        if contains(.right) { value.insert(.right) }
        return value
    }
}

extension NucleusDesktopLayerKeyboardPolicy {
    fileprivate var protocolValue: ZwlrLayerSurfaceV1KeyboardInteractivity {
        switch self {
        case .none: .none
        case .exclusive: .exclusive
        case .onDemand: .onDemand
        }
    }
}

extension NucleusDesktopLayerSurface: ZwlrLayerSurfaceV1Events {
    package func configure(
        _ proxy: WaylandBorrowedProxy<ZwlrLayerSurfaceV1Client>, serial: UInt32, width: UInt32,
        height: UInt32
    ) {
        try? layerSurface.ackConfigure(serial: serial)
        acked = true
        configuredWidth = width
        configuredHeight = height
        onConfigure?(width, height)
    }
    package func closed(_ proxy: WaylandBorrowedProxy<ZwlrLayerSurfaceV1Client>) {
        onClosed?()
    }
}
