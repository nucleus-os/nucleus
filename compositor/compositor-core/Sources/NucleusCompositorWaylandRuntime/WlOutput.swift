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
final class WlOutputBinding {
    let output: WlOutput
    var resource: UnsafeMutablePointer<wl_resource>?
    init(_ output: WlOutput) { self.output = output }
    deinit {
        if let resource { output.removeResource(resource) }
    }
}

final class WlOutput {
    private(set) var info: OutputInfo
    private let vtable: UnsafeMutableRawPointer
    private let globalState = OutputGlobalState()

    /// The DisplayID this output advertises. Surfaces report their overlapping
    /// output set by this id; the router maps it back to bound wl_output resources.
    var outputId: UInt64 { info.outputId }

    /// Live wl_output resources bound by clients. `wl_surface.enter`/`leave`
    /// reference one of these for the surface's own client, so the list is kept in
    /// sync as clients bind (append in `bind`) and disconnect (removed by the
    /// binding's deinit).
    var resources: [UnsafeMutablePointer<wl_resource>] {
        globalState.resources
    }

    func removeResource(_ resource: UnsafeMutablePointer<wl_resource>) {
        globalState.removeResource(resource)
    }

    /// The bound wl_output resources belonging to one client (a client may bind the
    /// output more than once; `wl_surface.enter` is sent to each, as wlroots does).
    func resources(forClient client: OpaquePointer?) -> [UnsafeMutablePointer<wl_resource>] {
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

    /// Resolve the WlOutput backing a wl_output resource, or nil.
    static func from(_ resource: UnsafeMutablePointer<wl_resource>?) -> WlOutput? {
        guard let resource, let b = WaylandResource.owner(of: resource, as: WlOutputBinding.self)
        else { return nil }
        return b.output
    }

    init(info: OutputInfo) {
        self.info = info
        let size = MemoryLayout<swift_wayland_wl_output_requests>.stride
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: size, alignment: MemoryLayout<swift_wayland_wl_output_requests>.alignment
        )
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        let vt = raw.bindMemory(to: swift_wayland_wl_output_requests.self, capacity: 1)
        // release (v3+) is a destructor request: libwayland will not free the
        // resource on its own, so the handler must.
        vt.pointee.release = Self.release
        self.vtable = raw
    }

    @discardableResult
    func register(in router: NucleusWaylandRouter) -> Bool {
        globalState.install(router.addGlobal(
            interface: swift_wayland_iface_wl_output(),
            version: 4,
            impl: self,
            bind: Self.bind))
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
        for resource in resources {
            sendState(
                to: resource,
                version: UInt32(wl_resource_get_version(resource)))
        }
    }

    func registerXdgOutput(_ output: XdgOutput) {
        globalState.registerXdgOutput(output)
    }

    private static let bind: @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32
    ) -> Void = { client, data, version, id in
        guard let client, let me = NucleusWaylandRouter.impl(data, as: WlOutput.self) else {
            return
        }
        let binding = WlOutputBinding(me)
        guard let resource = WaylandResource.create(
            client: client, interface: swift_wayland_iface_wl_output(),
            version: Int32(version), id: id, vtable: UnsafeRawPointer(me.vtable),
            owner: binding
        ) else { return }
        binding.resource = resource
        me.globalState.addResource(resource)
        me.sendState(to: resource, version: version)
    }

    private static let release: @convention(c) (
        OpaquePointer?, UnsafeMutablePointer<wl_resource>?
    ) -> Void = { _, resource in
        if let resource { wl_resource_destroy(resource) }
    }

    /// Emit the full advertisement to one freshly bound resource. Event set is
    /// version-gated exactly as wl_output specifies.
    private func sendState(to resource: UnsafeMutablePointer<wl_resource>, version: UInt32) {
        wl_output_send_geometry(
            resource, info.x, info.y, info.physicalWidthMm, info.physicalHeightMm,
            1 /* WL_OUTPUT_SUBPIXEL_NONE */, info.make, info.model,
            0 /* WL_OUTPUT_TRANSFORM_NORMAL */
        )
        wl_output_send_mode(
            resource,
            UInt32(0x1 | 0x2) /* WL_OUTPUT_MODE_CURRENT | WL_OUTPUT_MODE_PREFERRED */,
            info.pixelWidth, info.pixelHeight, info.refreshMhz
        )
        if version >= 2 { wl_output_send_scale(resource, info.scale) }
        if version >= 4 {
            wl_output_send_name(resource, info.name)
            wl_output_send_description(resource, info.description)
        }
        if version >= 2 {
            wl_output_send_done(resource)
        }
    }

    deinit { vtable.deallocate() }
}
