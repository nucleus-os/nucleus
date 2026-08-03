public import NucleusWindowClientContracts
package import WaylandClientDispatch

@MainActor
public final class NucleusDesktopWindow {
    let surface: WaylandProxy<WlSurfaceClient>
    fileprivate let xdgSurface: WaylandProxy<XdgSurfaceClient>
    private let toplevel: WaylandProxy<XdgToplevelClient>
    private var alpha: WaylandProxy<WpAlphaModifierSurfaceV1Client>?
    private var pendingWidth: Int32 = 0
    private var pendingHeight: Int32 = 0
    private var closed = false

    public var onEvent: ((NucleusDesktopWindowEvent) -> Void)?

    init(
        client: NucleusDesktopConnection,
        configuration: NucleusDesktopWindowConfiguration
    ) throws(NucleusDesktopWindowError) {
        guard let windowManagement = client.windowManagement else {
            throw .capabilityUnavailable
        }
        do {
            let surface = try client.createSurface()
            let xdgSurface = try windowManagement.getXdgSurface(
                surface: surface)
            let toplevel = try xdgSurface.getToplevel()
            self.surface = surface
            self.xdgSurface = xdgSurface
            self.toplevel = toplevel
            if let alphaModifier = client.alphaModifier {
                alpha = try alphaModifier.getSurface(
                    surface: surface)
            }
            try xdgSurface.installListener(self)
            try toplevel.installListener(self)
            try toplevel.setTitle(title: configuration.title)
            try toplevel.setAppId(app_id: configuration.applicationID)
            try surface.commit()
        } catch {
            throw .protocolFailure
        }
    }

    isolated deinit {}

    public func close() {
        guard !closed else { return }
        closed = true
        if let alpha {
            try? alpha.destroy()
            self.alpha = nil
        }
        try? toplevel.destroy()
        try? xdgSurface.destroy()
        try? surface.destroy()
    }

    public func setContentGeometry(
        width: Int32,
        height: Int32
    ) throws(NucleusDesktopWindowError) {
        guard width > 0, height > 0 else {
            throw .protocolFailure
        }
        do {
            try xdgSurface.setWindowGeometry(
                x: 0,
                y: 0,
                width: width,
                height: height)
            try surface.commit()
        } catch {
            throw .protocolFailure
        }
    }

    /// Queue a standard compositor-side alpha multiplier. Call `commit()` to
    /// latch it with the root surface and every synchronized descendant.
    public func setOpacity(
        _ value: Double
    ) throws(NucleusDesktopWindowError) {
        guard value.isFinite, value >= 0, value <= 1 else {
            throw .protocolFailure
        }
        guard let alpha else {
            throw .capabilityUnavailable
        }
        let factor =
            value == 1
            ? UInt32.max
            : UInt32(
                (value * Double(UInt32.max)).rounded())
        do {
            try alpha.setMultiplier(factor: factor)
        } catch {
            throw .protocolFailure
        }
    }

    /// Apply this root's pending state and every cached synchronized child
    /// transaction as one standard Wayland subtree commit.
    public func commit() throws(NucleusDesktopWindowError) {
        do {
            try surface.commit()
        } catch {
            throw .protocolFailure
        }
    }

    package func withUnsafeNativeSurface<Result>(
        _ body: (OpaquePointer) throws -> Result
    ) throws -> Result {
        try unsafe surface.withUnsafeNativeProxy(body)
    }

    package func configure(
        _ proxy: WaylandBorrowedProxy<XdgSurfaceClient>,
        serial: UInt32
    ) {
        try? xdgSurface.ackConfigure(serial: serial)
        onEvent?(
            .configured(
                width: pendingWidth,
                height: pendingHeight,
                serial: serial))
    }

    package func configure(
        _ proxy: WaylandBorrowedProxy<XdgToplevelClient>,
        width: Int32,
        height: Int32,
        states: WaylandClientArrayView
    ) {
        pendingWidth = max(0, width)
        pendingHeight = max(0, height)
    }

    package func close(
        _ proxy: WaylandBorrowedProxy<XdgToplevelClient>
    ) {
        onEvent?(.closeRequested)
    }

    package func configureBounds(
        _ proxy: WaylandBorrowedProxy<XdgToplevelClient>,
        width: Int32,
        height: Int32
    ) {}

    package func wmCapabilities(
        _ proxy: WaylandBorrowedProxy<XdgToplevelClient>,
        capabilities: WaylandClientArrayView
    ) {}
}

extension NucleusDesktopWindow: XdgSurfaceEvents, XdgToplevelEvents {}

@MainActor
public final class NucleusDesktopPopup {
    private let surface: WaylandProxy<WlSurfaceClient>
    private let xdgSurface: WaylandProxy<XdgSurfaceClient>
    private let popup: WaylandProxy<XdgPopupClient>
    private var pendingGeometry:
        (
            x: Int32, y: Int32, width: Int32, height: Int32
        ) = (0, 0, 0, 0)
    private var closed = false

    public var onEvent: ((NucleusDesktopPopupEvent) -> Void)?

    init(
        client: NucleusDesktopConnection,
        parent: NucleusDesktopWindow,
        configuration: NucleusDesktopPopupConfiguration
    ) throws(NucleusDesktopWindowError) {
        guard let windowManagement = client.windowManagement else {
            throw .capabilityUnavailable
        }
        do {
            let positioner = try windowManagement.createPositioner()
            try positioner.setSize(
                width: configuration.width,
                height: configuration.height)
            try positioner.setAnchorRect(
                x: configuration.anchorX,
                y: configuration.anchorY,
                width: configuration.anchorWidth,
                height: configuration.anchorHeight)
            let surface = try client.createSurface()
            let xdgSurface = try windowManagement.getXdgSurface(
                surface: surface)
            let popup = try xdgSurface.getPopup(
                parent: parent.xdgSurface,
                positioner: positioner)
            try positioner.destroy()
            self.surface = surface
            self.xdgSurface = xdgSurface
            self.popup = popup
            try xdgSurface.installListener(self)
            try popup.installListener(self)
            try surface.commit()
        } catch {
            throw .protocolFailure
        }
    }

    isolated deinit {}

    public func close() {
        guard !closed else { return }
        closed = true
        try? popup.destroy()
        try? xdgSurface.destroy()
        try? surface.destroy()
    }

    package func withUnsafeNativeSurface<Result>(
        _ body: (OpaquePointer) throws -> Result
    ) throws -> Result {
        try unsafe surface.withUnsafeNativeProxy(body)
    }

    package func configure(
        _ proxy: WaylandBorrowedProxy<XdgSurfaceClient>,
        serial: UInt32
    ) {
        try? xdgSurface.ackConfigure(serial: serial)
        onEvent?(
            .configured(
                x: pendingGeometry.x,
                y: pendingGeometry.y,
                width: pendingGeometry.width,
                height: pendingGeometry.height,
                serial: serial))
    }

    package func configure(
        _ proxy: WaylandBorrowedProxy<XdgPopupClient>,
        x: Int32,
        y: Int32,
        width: Int32,
        height: Int32
    ) {
        pendingGeometry = (x, y, max(0, width), max(0, height))
    }

    package func popupDone(
        _ proxy: WaylandBorrowedProxy<XdgPopupClient>
    ) {
        onEvent?(.dismissed)
    }

    package func repositioned(
        _ proxy: WaylandBorrowedProxy<XdgPopupClient>,
        token: UInt32
    ) {}
}

extension NucleusDesktopPopup: XdgSurfaceEvents, XdgPopupEvents {}

extension NucleusDesktopConnection {
    package func createWindow(
        configuration: NucleusDesktopWindowConfiguration
    ) throws(NucleusDesktopWindowError) -> NucleusDesktopWindow {
        try NucleusDesktopWindow(
            client: self,
            configuration: configuration)
    }

    package func createPopup(
        parent: NucleusDesktopWindow,
        configuration: NucleusDesktopPopupConfiguration
    ) throws(NucleusDesktopWindowError) -> NucleusDesktopPopup {
        try NucleusDesktopPopup(
            client: self,
            parent: parent,
            configuration: configuration)
    }

    package func createSubsurface(
        parent: NucleusDesktopWindow,
        configuration: NucleusDesktopSubsurfaceConfiguration = .init()
    ) throws(NucleusDesktopWindowError) -> NucleusDesktopSubsurface {
        try NucleusDesktopSubsurface(
            client: self,
            parentSurface: parent.surface,
            configuration: configuration)
    }

    package func createSubsurface(
        parent: NucleusDesktopSubsurface,
        configuration: NucleusDesktopSubsurfaceConfiguration = .init()
    ) throws(NucleusDesktopWindowError) -> NucleusDesktopSubsurface {
        try NucleusDesktopSubsurface(
            client: self,
            parentSurface: parent.surface,
            configuration: configuration)
    }
}
