// xdg-foreign-unstable-v2 on the router — cross-process surface parenting. An
// exporter mints an opaque handle for one of its surfaces; another client imports
// that handle and set_parent_of's its own surface, making the exported window the
// parent (e.g. a portal dialog declaring the app it belongs to).
//
// One XdgForeign owns both globals and the process-wide handle→surface registry.
// libwayland hands surfaces as live resources; the surface→window resolution and
// the parent apply use the RouterWindowDriver delegate seam. (v2, not v1: v1's
// export/import request names are C++ keywords the importer cannot parse.)

import WaylandServerC
import WaylandServer
import WaylandServerDispatch

protocol XdgForeignDelegate: AnyObject {
    /// Make `parent` the parent of `child` (cross-process). `parent` is the exported
    /// surface resolved from the imported handle (nil if the handle is unknown/dead).
    func setForeignParent(child: WlSurface, parent: WlSurface?)
}

/// Tags a foreign resource's binding back to the shared manager. Exporter and
/// importer resources share it; their vtables route to the right handlers.
final class XdgForeignBinding {
    unowned let foreign: XdgForeign
    init(_ foreign: XdgForeign) { self.foreign = foreign }
}

// The zxdg_exporter_v2 / zxdg_importer_v2 request handlers, recovered from the
// per-resource XdgForeignBinding owner shared by both globals.
extension XdgForeignBinding: ZxdgExporterV2Requests {
    // Both exporter and importer default `destroy`; conforming to both makes the default ambiguous,
    // so pin it explicitly here (plain teardown — the binding is released with its resource).
    func destroy(_ resource: UnsafeMutablePointer<wl_resource>) { wl_resource_destroy(resource) }

    func exportToplevel(
        _ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId,
        surface surfaceRes: UnsafeMutablePointer<wl_resource>?
    ) {
        guard let surfaceRes,
            let surface = WaylandResource.owner(of: surfaceRes, as: WlSurface.self)
        else { return }
        let handle = foreign.mint(surface)
        let exported = ZxdgExported(foreign: foreign, handle: handle)
        // zxdg_exported_v2 is destroy-only (no generated dispatch); its hand-wired
        // vtable still lives on XdgForeign.
        guard let xres = id.create(vtable: UnsafeRawPointer(foreign.exportedVtable), owner: exported)
        else { return }
        exported.bind(xres)
        exported.sendHandle()
    }
}

extension XdgForeignBinding: ZxdgImporterV2Requests {
    func importToplevel(
        _ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId, handle handlePtr: UnsafePointer<CChar>?
    ) {
        let handle = handlePtr.map { String(cString: $0) } ?? ""
        let parent = foreign.surface(forHandle: handle)
        _ = id.create(
            vtable: ZxdgImportedV2Server.vtable, owner: ZxdgImported(foreign: foreign, parent: parent))
    }
}

final class XdgForeign {
    /// zxdg_exported_v2 is destroy-only — no generated dispatch — so its request
    /// vtable stays hand-wired here.
    let exportedVtable: UnsafeMutableRawPointer
    weak var delegate: (any XdgForeignDelegate)?

    private var handles: [String: WeakSurfaceBox] = [:]
    private var counter: UInt64 = 0

    init() {
        exportedVtable = allocVtable(
            MemoryLayout<swift_wayland_zxdg_exported_v2_requests>.stride,
            MemoryLayout<swift_wayland_zxdg_exported_v2_requests>.alignment)
        let xv = exportedVtable.bindMemory(to: swift_wayland_zxdg_exported_v2_requests.self, capacity: 1)
        xv.pointee.destroy = Self.objectDestroy
    }

    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            interface: swift_wayland_iface_zxdg_exporter_v2(), version: 1, impl: self, bind: Self.bindExporter)
        router.addGlobal(
            interface: swift_wayland_iface_zxdg_importer_v2(), version: 1, impl: self, bind: Self.bindImporter)
    }

    fileprivate func mint(_ surface: WlSurface) -> String {
        counter += 1
        let handle = "nucleus-export-\(counter)"
        handles[handle] = WeakSurfaceBox(surface)
        return handle
    }

    fileprivate func surface(forHandle handle: String) -> WlSurface? { handles[handle]?.surface }
    fileprivate func release(_ handle: String) { handles[handle] = nil }

    static let objectDestroy: @convention(c) (
        OpaquePointer?, UnsafeMutablePointer<wl_resource>?
    ) -> Void = { _, resource in if let resource { wl_resource_destroy(resource) } }

    private static let bindExporter: @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32
    ) -> Void = { client, data, version, id in
        guard let client, let me = NucleusWaylandRouter.impl(data, as: XdgForeign.self) else { return }
        _ = WaylandResource.create(
            client: client, interface: swift_wayland_iface_zxdg_exporter_v2(), version: Int32(version),
            id: id, vtable: ZxdgExporterV2Server.vtable, owner: XdgForeignBinding(me))
    }

    private static let bindImporter: @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32
    ) -> Void = { client, data, version, id in
        guard let client, let me = NucleusWaylandRouter.impl(data, as: XdgForeign.self) else { return }
        _ = WaylandResource.create(
            client: client, interface: swift_wayland_iface_zxdg_importer_v2(), version: Int32(version),
            id: id, vtable: ZxdgImporterV2Server.vtable, owner: XdgForeignBinding(me))
    }

    deinit {
        exportedVtable.deallocate()
    }
}

/// An exported surface handle. Carries the handle event; releases the registry
/// entry on teardown.
final class ZxdgExported {
    private unowned let foreign: XdgForeign
    private let handle: String
    private var resource: UnsafeMutablePointer<wl_resource>?

    init(foreign: XdgForeign, handle: String) {
        self.foreign = foreign
        self.handle = handle
    }

    fileprivate func bind(_ resource: UnsafeMutablePointer<wl_resource>) { self.resource = resource }

    fileprivate func sendHandle() {
        guard let resource else { return }
        handle.withCString { zxdg_exported_v2_send_handle(resource, $0) }
    }

    deinit { foreign.release(handle) }
}

/// An imported handle. set_parent_of makes the resolved exported surface the parent
/// of the named child surface.
final class ZxdgImported {
    private unowned let foreign: XdgForeign
    private weak var parent: WlSurface?

    init(foreign: XdgForeign, parent: WlSurface?) {
        self.foreign = foreign
        self.parent = parent
    }
}

extension ZxdgImported: ZxdgImportedV2Requests {
    func setParentOf(
        _ resource: UnsafeMutablePointer<wl_resource>, surface childRes: UnsafeMutablePointer<wl_resource>?
    ) {
        guard let childRes, let child = WaylandResource.owner(of: childRes, as: WlSurface.self)
        else { return }
        foreign.delegate?.setForeignParent(child: child, parent: parent)
    }
}
