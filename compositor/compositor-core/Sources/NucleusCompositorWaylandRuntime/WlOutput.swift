// wl_output on the router. Advertises a compositor output through wl_output: on
// bind it sends geometry + mode, then (v2+) scale + done, then (v4+) name +
// description + done. libwayland owns the
// resource/wire mechanics; this owns the advertisement semantics.
//
// The output description is a value (OutputInfo) the topology reconciler supplies.
// Production constructs one WlOutput per live Display and refreshes it in place on
// output changes; protocol fixtures can supply the same value model synthetically.

import WaylandServerC
import WaylandServer
import WaylandServerDispatch
import NucleusRenderModel

/// A snapshot of one output's advertised state. Fields match wl_output's events.
struct OutputInfo {
    /// The compositor DisplayID this output advertises — the output analog of
    /// `Window.surfaceObjectId`. Output-keyed render crossings (gamma, screencopy)
    /// map a bound wl_output back to its live DRM output through this id. Zero is
    /// reserved for synthetic protocol fixtures.
    var outputId: UInt64 = 0
    var x: Int32 = 0
    var y: Int32 = 0
    var physicalWidthMm: Int32
    var physicalHeightMm: Int32
    var pixelWidth: Int32
    var pixelHeight: Int32
    var refreshMhz: Int32
    /// Integer compatibility scale advertised through wl_output.scale.
    var scale: Int32
    var make: String = "Nucleus"
    var model: String = "Virtual"
    var name: String
    var description: String
    /// Authoritative compositor-space size. Unlike wl_output.scale, this does
    /// not round a fractional output scale up to the next integer.
    var logicalWidth: Int32 = 0
    var logicalHeight: Int32 = 0
    /// Exact output scale advertised through wp_fractional_scale_v1.
    var fractionalScale: Double = 0.0
}

/// Owner bound to each wl_output resource (Rule 9). Back-links to its WlOutput so
/// protocols that take a wl_output argument (layer-shell, xdg-output) resolve the
/// output's geometry from the resource. The binding retains its WlOutput snapshot
/// so a resource already handed to a client stays safe while the global is being
/// withdrawn. On destruction it drops the resource from the output's bound-resource
/// list so `wl_surface.enter`/`leave` never references a freed resource.
@MainActor
@safe final class WlOutputBinding {
    let output: WlOutput
    let resource: WaylandResourceHandle<WlOutputServer>
    init(
        resource: WaylandResourceHandle<WlOutputServer>,
        output: WlOutput
    ) {
        self.resource = resource
        self.output = output
    }
    isolated deinit {
        output.removeResource(resource)
    }
}

extension WaylandBorrowedObject where Interface == WlOutputServer {
    var output: WlOutput? {
        owner(as: WlOutputBinding.self)?.output
    }
}

@MainActor
@safe final class WlOutput {
    private(set) var info: OutputInfo
    private let globalState = OutputGlobalState()

    /// The DisplayID this output advertises. Surfaces report their overlapping
    /// output set by this id; the router maps it back to bound wl_output resources.
    var outputId: UInt64 { info.outputId }

    /// Live wl_output resources bound by clients. `wl_surface.enter`/`leave`
    /// reference one of these for the surface's own client, so the list is kept in
    /// sync as clients bind (append in `bind`) and disconnect (removed by the
    /// binding's deinit).
    var resources: [WaylandResourceHandle<WlOutputServer>] {
        globalState.resources
    }

    func removeResource(_ resource: WaylandResourceHandle<WlOutputServer>) {
        globalState.removeResource(resource)
    }

    /// The bound wl_output resources belonging to one client (a client may bind the
    /// output more than once; `wl_surface.enter` is sent to each, as wlroots does).
    func resources(
        forClient client: WaylandClientID?
    ) -> [WaylandResourceHandle<WlOutputServer>] {
        globalState.resources(forClient: client)
    }

    /// The output's authoritative logical rect in compositor space. Layer-shell
    /// arranges anchored surfaces against it; xdg-output advertises it.
    var logicalRect: WlRect {
        let fractionalScale = info.fractionalScale > 0 ? info.fractionalScale : Double(max(1, info.scale))
        let fallbackWidth = Int32(max(1.0, (Double(info.pixelWidth) / fractionalScale).rounded()))
        let fallbackHeight = Int32(max(1.0, (Double(info.pixelHeight) / fractionalScale).rounded()))
        return WlRect(
            x: info.x, y: info.y,
            width: info.logicalWidth > 0 ? info.logicalWidth : fallbackWidth,
            height: info.logicalHeight > 0 ? info.logicalHeight : fallbackHeight)
    }

    init(info: OutputInfo) {
        self.info = info
    }

    func installGlobal(_ handle: NucleusWaylandRouter.GlobalHandle?) -> Bool {
        globalState.install(handle)
    }

    func resourceInstalled(
        _ handle: WaylandResourceHandle<WlOutputServer>
    ) {
        globalState.addResource(handle)
        sendState(to: handle)
    }

    /// Stop advertising this output. Existing wl_output resources remain valid
    /// until their clients release them and keep this value alive through their
    /// binding owner.
    func removeGlobal() {
        globalState.withdraw()
    }

    /// Apply one complete advertised state and refresh every extant wl_output and
    /// xdg-output binding. XDG v3 synchronizes through the subsequent
    /// wl_output.done emitted by `sendState`.
    func apply(_ newInfo: OutputInfo) {
        info = newInfo
        for xdg in globalState.liveXdgOutputs() {
            xdg.sendDescription()
        }
        let resources = resources
        for resource in resources {
            sendState(to: resource)
        }
    }

    func registerXdgOutput(_ output: XdgOutput) {
        globalState.registerXdgOutput(output)
    }

    /// Emit the full advertisement to one freshly bound resource. Event set is
    /// version-gated exactly as wl_output specifies.
    private func sendState(
        to resource: WaylandResourceHandle<WlOutputServer>
    ) {
        resource.sendGeometry(
            x: info.x, y: info.y,
            physical_width: info.physicalWidthMm,
            physical_height: info.physicalHeightMm,
            subpixel: .none,
            make: info.make,
            model: info.model,
            transform: .normal)
        resource.sendMode(
            flags: [.current, .preferred],
            width: info.pixelWidth,
            height: info.pixelHeight,
            refresh: info.refreshMhz)
        if resource.supportsScale {
            resource.sendScale(factor: info.scale)
        }
        if resource.supportsName {
            resource.sendName(name: info.name)
            resource.sendDescription(description: info.description)
        }
        if resource.supportsDone {
            resource.sendDone()
        }
    }
}
