// The production owner of the live Wayland router: constructs every protocol impl,
// wires each one's delegate to the matching driver, registers all globals, and
// holds the whole graph alive for the compositor's lifetime. It is one object the
// compositor runtime owns, built once.
//
// Lifetime: the router retains each protocol impl (its `impls` array is the bind
// data owner). The protocol impls hold their delegates WEAKLY, so this type
// strong-holds the five drivers + the scene feeder; the window driver in turn
// strong-holds the feeder. `compositor` and `seat` are kept for activation-time
// refresh (live outputs + the xkb keymap fd land on them at activation).
//
// Construction and activation are deliberately separate: construction assembles
// the protocol graph; compositor bring-up then publishes the socket, seeds outputs
// and seat state, and registers the display event-loop fd with the reactor.
//
// SHM is libwayland-owned (WaylandDisplay calls wl_display_init_shm), so there is
// no wl_shm impl here — committed SHM pixels are read back through
// wl_shm_buffer_get at commit time.

internal import NucleusCompositorServer
package import NucleusCompositorWindowScene
import WaylandServer

@MainActor
public final class WaylandRouterRuntime {
    private unowned let host: RouterHost
    let router: NucleusWaylandRouter
    let feeder: SceneFeeder

    // Drivers — strong-held (the protocol impls reference them weakly). The window
    // driver is reachable so the input-bridge crossings can drive imperative window
    // commands (focus/maximize/fullscreen/close) by surface id.
    private let seatDriver: RouterSeatDriver
    let windowDriver: RouterWindowDriver
    /// Drives the Swift window model for router-attached Xwayland windows. Reachable
    /// so the XWm-sink crossings (RouterXwaylandBridge) can drive it by window id.
    let xwaylandDriver: RouterXwaylandDriver
    private let renderDriver: RouterRenderDriver
    private let dataDeviceDriver: RouterDataDeviceDriver
    private let sessionLockDriver: RouterSessionLockDriver

    // Impls needing post-construction access (live outputs refresh on `seat`/outputs;
    // the lock manager emits `locked` from the present path; the rest are retained by
    // the router's `impls` array via register).
    let compositor: WlCompositor
    let xdgShell: XdgShell
    let seat: WlSeat
    let sessionLock: SessionLockManager
    let idle: IdleManager
    let dataDevice: WlDataDeviceManager
    let textInputManager: TextInputManagerV3
    let screencopy: ScreencopyManager
    private let gamma: ZwlrGammaControlManager
    /// The input feed queries this by surface id to clamp/freeze the cursor under an
    /// active pointer constraint (the seat owns the relative/locked motion delivery).
    let pointerConstraints: PointerConstraintsManager

    package init?(author: WindowSceneAuthor, host: RouterHost) {
        guard let router = NucleusWaylandRouter() else { return nil }
        let feeder = SceneFeeder(author: author, host: host)

        // Protocol impls.
        let compositor = WlCompositor(host: host)
        let subcompositor = WlSubcompositor()
        let seat = WlSeat(host: host)
        let xdgShell = XdgShell()
        let layerShell = ZwlrLayerShell()
        let xdgOutput = XdgOutputManager()
        let cursorShape = CursorShapeManager()
        let decoration = XdgDecorationManager()
        let xdgActivation = XdgActivationManager()
        let xdgForeign = XdgForeign()
        let viewporter = WpViewporter()
        let fractionalScale = WpFractionalScaleManager()
        let idle = IdleManager()
        let blur = OrgKdeKwinBlurManager()
        let backgroundEffect = ExtBackgroundEffectManager()
        let presentation = WpPresentation()
        let dmabuf = ZwpLinuxDmabuf()
        let syncobj = WpLinuxDrmSyncobjManager()
        let screencopy = ScreencopyManager()
        let gamma = ZwlrGammaControlManager()
        let dataDevice = WlDataDeviceManager(
            compositor: compositor,
            host: host,
            dataExchange: host.server.dataExchange)
        seat.dataDeviceManager = dataDevice
        let textInputManager = TextInputManagerV3(seat: seat)
        seat.textInputManager = textInputManager
        let sessionLock = SessionLockManager()
        let relativePointer = RelativePointerManager()
        let pointerConstraints = PointerConstraintsManager()
        // Xwayland surface association. Dormant until Xwayland attaches to the
        // router at the socket handover; reports pairings to the Swift XWM directly.
        let xwaylandShell = XwaylandShellManager(host: host)
        // Taskbar / window-list projection of the Swift window model.
        let foreignToplevel = ZwlrForeignToplevelManager(
            compositor: compositor, server: host.server)
        // Workspace / virtual-desktop pager projection of the Spaces model.
        let extWorkspace = ExtWorkspaceManager(
            compositor: compositor, server: host.server)
        // Privileged clipboard manager — shares the wl_data_device selection.
        let extDataControl = ExtDataControlManager(dataDevice: dataDevice)

        // Drivers.
        let seatDriver = RouterSeatDriver(
            seat: seat, compositor: compositor, server: host.server)
        let windowDriver = RouterWindowDriver(
            seatDriver: seatDriver, compositor: compositor, feeder: feeder,
            host: host)
        let xwaylandDriver = RouterXwaylandDriver(
            seatDriver: seatDriver, compositor: compositor, feeder: feeder,
            sceneDriver: windowDriver.sceneDriver,
            host: host)
        let renderDriver = RouterRenderDriver(server: host.server)
        let dataDeviceDriver = RouterDataDeviceDriver(
            compositor: compositor, server: host.server)
        let sessionLockDriver = RouterSessionLockDriver(
            gate: host.sessionLockGate)

        // Wire delegates. The window driver answers every shell/scene/decoration/
        // activation/foreign/cursor seam; the render driver every render/DRM seam.
        compositor.sceneDelegate = windowDriver
        // The taskbar funnels its control verbs through the window driver.
        foreignToplevel.actions = windowDriver
        xdgShell.delegate = windowDriver
        layerShell.delegate = windowDriver
        cursorShape.delegate = windowDriver
        decoration.delegate = windowDriver
        xdgActivation.delegate = windowDriver
        xdgActivation.seat = seat
        xdgForeign.delegate = windowDriver
        presentation.delegate = renderDriver
        dmabuf.delegate = renderDriver
        syncobj.delegate = renderDriver
        screencopy.delegate = renderDriver
        gamma.delegate = renderDriver
        dataDevice.delegate = dataDeviceDriver
        sessionLock.delegate = sessionLockDriver
        backgroundEffect.delegate = feeder
        blur.delegate = feeder
        // The seat owns relative-pointer emission + pointer-constraint application on
        // the motion path; hand it the two managers (retained by the router globals).
        seat.relativePointer = relativePointer
        seat.pointerConstraints = pointerConstraints
        // The feeder resolves router surfaces to push per-frame output membership.
        feeder.compositor = compositor
        // Register every global. wl_output globals are added at activation, one per
        // live Display; wl_shm is libwayland's (WaylandDisplay.init_shm).
        compositor.register(in: router)
        subcompositor.register(in: router)
        seat.register(in: router)
        xdgShell.register(in: router)
        layerShell.register(in: router)
        xdgOutput.register(in: router)
        cursorShape.register(in: router)
        decoration.register(in: router)
        xdgActivation.register(in: router)
        xdgForeign.register(in: router)
        viewporter.register(in: router)
        fractionalScale.register(in: router)
        idle.register(in: router)
        blur.register(in: router)
        backgroundEffect.register(in: router)
        presentation.register(in: router)
        dmabuf.register(in: router)
        syncobj.register(in: router)
        screencopy.register(in: router)
        gamma.register(in: router)
        dataDevice.register(in: router)
        sessionLock.register(in: router)
        relativePointer.register(in: router)
        pointerConstraints.register(in: router)
        xwaylandShell.register(in: router)
        foreignToplevel.register(in: router)
        extWorkspace.register(in: router)
        extDataControl.register(in: router)
        textInputManager.register(in: router)

        // The compositor impl owns the live-surface registry the frame/presentation
        // completion crossings iterate.
        router.compositor = compositor

        self.host = host
        self.router = router
        self.feeder = feeder
        self.seatDriver = seatDriver
        self.windowDriver = windowDriver
        self.xwaylandDriver = xwaylandDriver
        self.renderDriver = renderDriver
        self.dataDeviceDriver = dataDeviceDriver
        self.sessionLockDriver = sessionLockDriver
        self.compositor = compositor
        self.xdgShell = xdgShell
        self.seat = seat
        self.sessionLock = sessionLock
        self.idle = idle
        self.dataDevice = dataDevice
        self.textInputManager = textInputManager
        self.screencopy = screencopy
        self.gamma = gamma
        self.pointerConstraints = pointerConstraints
    }

    /// Adopt one already-connected Wayland client endpoint.
    ///
    /// The runtime owns the descriptor after this succeeds. This is also the
    /// deterministic connection seam used by in-process protocol fixtures.
    public func attachClient(fileDescriptor: Int32) -> Bool {
        router.display.createClient(fd: fileDescriptor) != nil
    }

    /// Process all currently-ready client requests and flush queued events
    /// without waiting for new work.
    public func dispatchClientsNonBlocking() {
        router.display.dispatch()
        router.display.flushClients()
    }

    func setFixtureKeyboardFocus(surfaceID: UInt32) {
        seatDriver.setKeyboardFocus(toSurfaceId: surfaceID)
    }

    /// Add or update one stable connector identity.
    func applyOutput(_ info: OutputInfo) {
        if let output = compositor.output(id: info.outputId) {
            output.apply(info)
            compositor.outputStateChanged(id: info.outputId)
            gamma.outputRestored(output)
            xdgShell.outputTopologyChanged()
            outputTopologyChangedForXwayland()
            return
        }
        let output = WlOutput(info: info)
        guard output.register(in: router) else { return }
        // The compositor also retains the output so surfaces can resolve their
        // overlapping DisplayIDs to bound wl_output resources for enter/leave.
        compositor.addOutput(output)
        xdgShell.outputTopologyChanged()
        outputTopologyChangedForXwayland()
    }

    @discardableResult
    func prepareOutputRemoval(_ outputID: UInt64) -> Bool {
        guard let output = compositor.output(id: outputID)
        else { return false }
        feeder.outputRemoved(outputID)
        screencopy.outputRemoved(outputID)
        gamma.outputRemoved(output)
        return compositor.prepareOutputRemoval(id: outputID)
    }

    func finishOutputRemoval(_ outputID: UInt64) {
        guard compositor.finishOutputRemoval(id: outputID) != nil
        else { return }
        xdgShell.outputTopologyChanged()
        outputTopologyChangedForXwayland()
    }

    func removeOutput(_ outputID: UInt64) {
        guard prepareOutputRemoval(outputID) else { return }
        finishOutputRemoval(outputID)
    }

    private func outputTopologyChangedForXwayland() {
        xwaylandDriver.outputTopologyChanged()
        host.xwaylandHost?.updateScale()
    }
}
