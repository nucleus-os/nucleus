// The window-frame model, shaped after AppKit's NSWindow chrome surface — a
// declarative style mask, a frame view (NSThemeFrame analog), standard window
// buttons, and per-edge insets (NSEdgeInsets analog) — but named in Wayland
// terms (close / minimize / maximize, not close / miniaturize / zoom).
//
// On macOS this chrome is drawn by AppKit's NSThemeFrame inside the application
// process; it only feels server-side because AppKit is universal. Nucleus has no
// AppKit in its Wayland clients, so it draws the chrome server-side — but the
// model and naming read like NSWindow so the geometry is the AppKit geometry.

public import NucleusCompositorServerTypes

/// Window decoration intent, mirroring `NSWindow.StyleMask`. The presence of a
/// titlebar, border, and standard buttons — and therefore the chrome geometry —
/// is *derived* from this mask rather than stored directly. The empty mask is
/// `.borderless`: no server chrome, the client-side-decorated case.
public struct WindowStyleMask: OptionSet, Sendable, Equatable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// The window has a titlebar band (the precondition for any server chrome).
    public static let titled = WindowStyleMask(rawValue: 1 << 0)
    /// The titlebar shows a close button.
    public static let closable = WindowStyleMask(rawValue: 1 << 1)
    /// The titlebar shows a minimize button.
    public static let minimizable = WindowStyleMask(rawValue: 1 << 2)
    /// The titlebar shows a maximize button.
    public static let maximizable = WindowStyleMask(rawValue: 1 << 3)
    /// The window can be resized by dragging its edges.
    public static let resizable = WindowStyleMask(rawValue: 1 << 4)
    /// Content extends under the titlebar — the titlebar floats over the content
    /// rather than reserving a band above it. Mirrors `.fullSizeContentView`.
    public static let fullSizeContentView = WindowStyleMask(rawValue: 1 << 5)

    /// No server chrome — the client-side-decorated / undecorated case.
    public static let borderless: WindowStyleMask = []

    /// The standard managed-app toplevel: a titlebar carrying all three controls,
    /// plus edge resizing.
    public static let titledResizable: WindowStyleMask =
        [.titled, .closable, .minimizable, .maximizable, .resizable]
}

/// Per-edge geometry around a window's content, mirroring `NSEdgeInsets`
/// (top, left, bottom, right ordering). This is the generated `WireChromeInsets`
/// wire type itself; the conveniences relocate here.
public typealias WindowEdgeInsets = WireChromeInsets

extension WireChromeInsets {
    public static let zero = WireChromeInsets(top: 0, left: 0, bottom: 0, right: 0)

    public var horizontal: Double { left + right }
    public var vertical: Double { top + bottom }
    public var isZero: Bool { top == 0 && left == 0 && bottom == 0 && right == 0 }
}

/// Theme metrics for server-drawn chrome — the constants the frame view reads to
/// size the titlebar band and border. The analog of AppKit/CoreUI theme metrics;
/// global for now, per-theme later.
public struct WindowThemeMetrics: Sendable, Equatable {
    public var titlebarHeight: Double
    public var borderThickness: Double

    public init(titlebarHeight: Double, borderThickness: Double) {
        self.titlebarHeight = titlebarHeight
        self.borderThickness = borderThickness
    }

    public static let standard = WindowThemeMetrics(titlebarHeight: 28, borderThickness: 1)
}

/// A standard window control, mirroring `NSWindow.ButtonType` but named in
/// Wayland terms (close / minimize / maximize rather than close / miniaturize /
/// zoom). Resolved to `standardWindowButton(_:)`-style queries on the frame view.
public enum WindowButton: Sendable, Equatable, CaseIterable {
    case close
    case minimize
    case maximize
}

/// Resize edges a point sits on, for an interactive resize. Bit layout matches
/// the packed wire value the compositor decodes.
public struct ResizeEdges: OptionSet, Sendable, Equatable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let left = ResizeEdges(rawValue: 1 << 0)
    public static let right = ResizeEdges(rawValue: 1 << 1)
    public static let top = ResizeEdges(rawValue: 1 << 2)
    public static let bottom = ResizeEdges(rawValue: 1 << 3)
}

/// What a point in (or just outside) a window's frame falls on. The compositor
/// classifies pointer hits against this so chrome regions are handled
/// server-side and only `content` reaches the client.
public enum ChromeRegion: UInt32, Sendable, Equatable {
    case content = 0
    case titlebar = 1
    case resize = 2
    case closeButton = 3
    case minimizeButton = 4
    case maximizeButton = 5
}

/// A classified chrome hit: the region plus, for `resize`, which edges.
public struct ChromeHit: Sendable, Equatable {
    public var region: ChromeRegion
    public var edges: ResizeEdges

    public init(region: ChromeRegion, edges: ResizeEdges = []) {
        self.region = region
        self.edges = edges
    }

    public static let content = ChromeHit(region: .content)

    /// Region in the low byte, edges in the next byte — the wire form the
    /// compositor decodes during hit-testing.
    public var packed: UInt64 { UInt64(region.rawValue) | (UInt64(edges.rawValue) << 8) }
}

/// A rectangle in frame-local coordinates (origin at the frame's top-left),
/// used for chrome-element layout (the titlebar band, the standard buttons).
public struct FrameLocalRect: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// The server-side window frame, shaped after AppKit's `NSThemeFrame`: the view
/// that wraps the content and owns the titlebar, border, and standard window
/// buttons. Here it is a pure-geometry value derived from the style mask and
/// theme metrics; the renderer arrives with chrome drawing. Organized like the
/// AppKit frame view even though Nucleus draws it server-side.
public struct WindowFrameView: Sendable, Equatable {
    public var styleMask: WindowStyleMask
    public var metrics: WindowThemeMetrics
    /// Fullscreen suppresses all chrome regardless of the style mask.
    public var fullscreen: Bool

    public init(
        styleMask: WindowStyleMask,
        metrics: WindowThemeMetrics = .standard,
        fullscreen: Bool = false
    ) {
        self.styleMask = styleMask
        self.metrics = metrics
        self.fullscreen = fullscreen
    }

    /// Whether a titlebar band is presented — the precondition for drawing chrome.
    public var hasTitlebar: Bool { !fullscreen && styleMask.contains(.titled) }

    /// Height of the titlebar band, or zero when no titlebar is shown.
    public var titlebarHeight: Double { hasTitlebar ? metrics.titlebarHeight : 0 }

    /// The chrome reservation between the frame rect and the content rect: only
    /// the titlebar band at the top. The content runs edge-to-edge to the left,
    /// right, and bottom (the macOS model — the titlebar spans the full window
    /// width and the content fills below it); the window outline is a 1px stroke
    /// drawn *over* the edge, not a reserved inset, so it never shrinks the content
    /// or makes the titlebar overhang it. Zero when no titlebar is shown
    /// (borderless / fullscreen); with `.fullSizeContentView` the content runs
    /// under the titlebar too, so even the top inset drops to zero.
    public var contentInsets: WindowEdgeInsets {
        guard hasTitlebar else { return .zero }
        let top = styleMask.contains(.fullSizeContentView) ? 0 : metrics.titlebarHeight
        return WindowEdgeInsets(top: top, left: 0, bottom: 0, right: 0)
    }

    /// The window-menu capability bitfield this style presents, in the bit layout
    /// the overlay's `WindowMenuCapabilities` decodes (closable = 1<<0, minimizable
    /// = 1<<1, zoomable = 1<<2, fullScreenable = 1<<3, movable = 1<<4, resizable =
    /// 1<<5). Derived from the style mask: the three standard buttons gate close /
    /// minimize / zoom, a resizable window can enter full screen (the macOS rule
    /// that full-screen capability tracks resizability) and offers the interactive
    /// Resize verb, and any titled window offers the interactive Move verb. The
    /// compositor crosses this value into the overlay so the window menu dims the
    /// verbs the window cannot perform.
    public var windowMenuCapabilities: UInt32 {
        var caps: UInt32 = 0
        if styleMask.contains(.closable) { caps |= 1 << 0 }
        if styleMask.contains(.minimizable) { caps |= 1 << 1 }
        if styleMask.contains(.maximizable) { caps |= 1 << 2 }
        if styleMask.contains(.resizable) { caps |= 1 << 3 }
        if styleMask.contains(.titled) { caps |= 1 << 4 }
        if styleMask.contains(.resizable) { caps |= 1 << 5 }
        return caps
    }

    /// The standard window controls this style presents, leading to trailing
    /// (macOS places the traffic-light cluster at the leading edge).
    public var standardButtons: [WindowButton] {
        guard hasTitlebar else { return [] }
        var buttons: [WindowButton] = []
        if styleMask.contains(.closable) { buttons.append(.close) }
        if styleMask.contains(.minimizable) { buttons.append(.minimize) }
        if styleMask.contains(.maximizable) { buttons.append(.maximize) }
        return buttons
    }

    /// Layout metrics for the leading traffic-light control cluster.
    public enum ButtonLayout {
        public static let diameter: Double = 12
        /// Center-to-center spacing between adjacent controls.
        public static let spacing: Double = 20
        /// Cluster start, measured from the frame's leading edge to the first
        /// control's center.
        public static let leadingInset: Double = 20
    }

    /// Frame-local rect of a standard window button, or nil when this style does
    /// not present it. The controls form a leading-aligned, vertically-centered
    /// cluster within the titlebar band — the analog of `standardWindowButton(_:)`.
    public func rect(for button: WindowButton) -> FrameLocalRect? {
        let buttons = standardButtons
        guard let index = buttons.firstIndex(of: button) else { return nil }
        let d = ButtonLayout.diameter
        let centerX = ButtonLayout.leadingInset + Double(index) * ButtonLayout.spacing
        let centerY = titlebarHeight / 2
        return FrameLocalRect(x: centerX - d / 2, y: centerY - d / 2, width: d, height: d)
    }

    /// The button whose hit area contains a frame-local point, or nil. Hit areas
    /// are square cells around each control so near-misses still register, like
    /// the AppKit traffic-light hit targets.
    public func button(atFrameLocal point: FrameLocalRect) -> WindowButton? {
        for button in standardButtons {
            guard let rect = rect(for: button) else { continue }
            let pad = (ButtonLayout.spacing - ButtonLayout.diameter) / 2
            if point.x >= rect.x - pad, point.x <= rect.x + rect.width + pad,
               point.y >= 0, point.y <= titlebarHeight {
                return button
            }
        }
        return nil
    }

    /// Invisible resize-grab geometry — the macOS all-edge resize border, a band
    /// straddling the frame edge (a little inside, a little outside).
    public enum ResizeGrab {
        public static let border: Double = 6
        public static let outset: Double = 4
    }

    /// Classify a frame-local point (origin at the frame top-left; may be slightly
    /// negative or past the size when inside the resize-grab band) into a chrome
    /// region. This is the single owner of chrome hit geometry — render geometry in
    /// the scene author mirrors it. Resize edges win at the frame boundary, then
    /// the standard buttons, then the titlebar; everything else is content.
    public func classify(x: Double, y: Double, frameWidth: Double, frameHeight: Double) -> ChromeHit {
        if styleMask.contains(.resizable) && !fullscreen {
            var edges: ResizeEdges = []
            let b = ResizeGrab.border
            if x <= b { edges.insert(.left) }
            if x >= frameWidth - b { edges.insert(.right) }
            if y <= b { edges.insert(.top) }
            if y >= frameHeight - b { edges.insert(.bottom) }
            if !edges.isEmpty { return ChromeHit(region: .resize, edges: edges) }
        }
        if hasTitlebar, y >= 0, y < titlebarHeight {
            if let button = button(atFrameLocal: FrameLocalRect(x: x, y: y, width: 0, height: 0)) {
                switch button {
                case .close: return ChromeHit(region: .closeButton)
                case .minimize: return ChromeHit(region: .minimizeButton)
                case .maximize: return ChromeHit(region: .maximizeButton)
                }
            }
            return ChromeHit(region: .titlebar)
        }
        return .content
    }
}
