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

public enum NucleusDesktopLayer: Sendable, Equatable {
    case background
    case bottom
    case top
    case overlay
}

public struct NucleusDesktopLayerAnchors:
    OptionSet, Sendable, Equatable
{
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let top = Self(rawValue: 1 << 0)
    public static let bottom = Self(rawValue: 1 << 1)
    public static let left = Self(rawValue: 1 << 2)
    public static let right = Self(rawValue: 1 << 3)
    public static let all: Self = [.top, .bottom, .left, .right]
}

public enum NucleusDesktopLayerKeyboardPolicy: Sendable, Equatable {
    case none
    case exclusive
    case onDemand
}

/// Configuration for a layer surface, decided by the panel before its first commit.
public struct NucleusDesktopLayerSurfaceConfiguration {
    public var layer: NucleusDesktopLayer
    public var anchor: NucleusDesktopLayerAnchors
    /// Logical size; 0 on an anchored axis means "span the anchored edges".
    public var width: UInt32
    public var height: UInt32
    /// Reserve this many logical px of work area on the anchored edge.
    /// `-1` ignores other exclusive zones and uses the complete output.
    public var exclusiveZone: Int32
    public var keyboard: NucleusDesktopLayerKeyboardPolicy
    public var namespace: String
    public var marginTop: Int32
    public var marginRight: Int32
    public var marginBottom: Int32
    public var marginLeft: Int32

    public init(
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
    @_spi(NucleusWindowClientImplementation)
    public let wlSurface: WaylandProxy<WlSurfaceClient>
    @_spi(NucleusWindowClientImplementation)
    public let layerSurface:
        WaylandProxy<ZwlrLayerSurfaceV1Client>
    public let config: NucleusDesktopLayerSurfaceConfiguration
    /// The output this panel is on (nil = compositor picks).
    public let output: NucleusDesktopOutput?

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

    public init?(client: NucleusDesktopConnection, config: NucleusDesktopLayerSurfaceConfiguration, output: NucleusDesktopOutput?) {
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

private extension NucleusDesktopLayer {
    var protocolValue: ZwlrLayerShellV1Layer {
        switch self {
        case .background: .background
        case .bottom: .bottom
        case .top: .top
        case .overlay: .overlay
        }
    }
}

private extension NucleusDesktopLayerAnchors {
    var protocolValue: ZwlrLayerSurfaceV1Anchor {
        var value: ZwlrLayerSurfaceV1Anchor = []
        if contains(.top) { value.insert(.top) }
        if contains(.bottom) { value.insert(.bottom) }
        if contains(.left) { value.insert(.left) }
        if contains(.right) { value.insert(.right) }
        return value
    }
}

private extension NucleusDesktopLayerKeyboardPolicy {
    var protocolValue: ZwlrLayerSurfaceV1KeyboardInteractivity {
        switch self {
        case .none: .none
        case .exclusive: .exclusive
        case .onDemand: .onDemand
        }
    }
}

extension NucleusDesktopLayerSurface: ZwlrLayerSurfaceV1Events {
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
