// xdg-output-unstable-v1 on the router — advertises each output's compositor-space
// logical geometry (position, size) and user-facing name/description. The manager
// mints a per-(client, wl_output) zxdg_output_v1 that sources its description from
// the WlOutput model (resolved straight from the wl_output resource — no sink seam)
// and emits it on creation. Read-only from the client; the compositor owns all
// output geometry. Re-emit on output layout-change is a #12 concern.

import WaylandServerC
import WaylandServer
import WaylandServerDispatch

final class XdgOutputManagerBinding {
    unowned let manager: XdgOutputManager
    init(_ manager: XdgOutputManager) { self.manager = manager }
}

final class XdgOutputManager {
    // zxdg_output_v1 is destroy-only (no generated dispatch): its vtable stays hand-wired.
    let outputVtable: UnsafeMutableRawPointer

    init() {
        outputVtable = allocVtable(
            MemoryLayout<swift_wayland_zxdg_output_v1_requests>.stride,
            MemoryLayout<swift_wayland_zxdg_output_v1_requests>.alignment)
        let ov = outputVtable.bindMemory(to: swift_wayland_zxdg_output_v1_requests.self, capacity: 1)
        ov.pointee.destroy = Self.objectDestroy
    }

    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            interface: swift_wayland_iface_zxdg_output_manager_v1(), version: 3, impl: self, bind: Self.bind)
    }

    static let objectDestroy: @convention(c) (
        OpaquePointer?, UnsafeMutablePointer<wl_resource>?
    ) -> Void = { _, resource in if let resource { wl_resource_destroy(resource) } }

    private static let bind: @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32
    ) -> Void = { client, data, version, id in
        guard let client, let me = NucleusWaylandRouter.impl(data, as: XdgOutputManager.self) else { return }
        _ = WaylandResource.create(
            client: client, interface: swift_wayland_iface_zxdg_output_manager_v1(), version: Int32(version),
            id: id, vtable: ZxdgOutputManagerV1Server.vtable, owner: XdgOutputManagerBinding(me))
    }

    deinit {
        outputVtable.deallocate()
    }
}

extension XdgOutputManagerBinding: ZxdgOutputManagerV1Requests {
    func getXdgOutput(_ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId,
                      output outputRes: UnsafeMutablePointer<wl_resource>?) {
        guard let output = WlOutput.from(outputRes) else { return }
        let xdgOutput = XdgOutput(output: output)
        guard let xres = id.create(
            vtable: UnsafeRawPointer(manager.outputVtable), owner: xdgOutput
        ) else { return }
        xdgOutput.bind(xres)
        xdgOutput.sendDescription()
    }
}

/// One client's view of one output's logical geometry. Sources from the WlOutput.
final class XdgOutput {
    private unowned let output: WlOutput
    private var resource: UnsafeMutablePointer<wl_resource>?

    init(output: WlOutput) { self.output = output }

    fileprivate func bind(_ resource: UnsafeMutablePointer<wl_resource>) { self.resource = resource }

    /// Emit logical position + size, then (v≥2) name + description, then done.
    func sendDescription() {
        guard let resource else { return }
        let r = output.logicalRect
        zxdg_output_v1_send_logical_position(resource, r.x, r.y)
        zxdg_output_v1_send_logical_size(resource, r.width, r.height)
        if wl_resource_get_version(resource) >= 2 {
            output.info.name.withCString { zxdg_output_v1_send_name(resource, $0) }
            output.info.description.withCString { zxdg_output_v1_send_description(resource, $0) }
        }
        zxdg_output_v1_send_done(resource)
    }
}
