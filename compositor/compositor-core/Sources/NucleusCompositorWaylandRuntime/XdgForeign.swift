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

@MainActor
protocol XdgForeignDelegate: AnyObject {
    /// Make `parent` the parent of `child` (cross-process). `parent` is the exported
    /// surface resolved from the imported handle (nil if the handle is unknown/dead).
    func setForeignParent(child: WlSurface, parent: WlSurface?)
}

/// Tags a foreign resource's binding back to the shared manager. Exporter and
/// importer resources share it; their vtables route to the right handlers.
@MainActor
@safe final class XdgForeignBinding {
    unowned let foreign: XdgForeign
    init(_ foreign: XdgForeign) { self.foreign = foreign }
}

// The zxdg_exporter_v2 / zxdg_importer_v2 request handlers, recovered from the
// per-resource XdgForeignBinding owner shared by both globals.
extension XdgForeignBinding: ZxdgExporterV2Requests {
    // Both exporter and importer default `destroy`; conforming to both makes the default ambiguous,
    // so pin it explicitly here (plain teardown — the binding is released with its resource).
    func destroy(_ request: WaylandRequest<ZxdgExporterV2Server>) {
        request.destroy()
    }

    func exportToplevel(
        _ request: WaylandRequest<ZxdgExporterV2Server>,
        id: WlNewId<ZxdgExportedV2Server>,
        surface surfaceRes: WaylandBorrowedObject<WlSurfaceServer>
    ) {
        guard let surface = surfaceRes.owner(as: WlSurface.self) else { return }
        let handle = foreign.mint(surface)
        _ = id.create(
            owner: { resource in
                ZxdgExported(
                    resource: resource,
                    foreign: foreign,
                    handle: handle)
            },
            installed: { exported in
                exported.sendHandle()
            })
    }
}

extension XdgForeignBinding: ZxdgImporterV2Requests {
    func importToplevel(
        _ request: WaylandRequest<ZxdgImporterV2Server>,
        id: WlNewId<ZxdgImportedV2Server>,
        handle handlePtr: String
    ) {
        let parent = foreign.surface(forHandle: handlePtr)
        _ = id.create { resource in
            ZxdgImported(
                resource: resource, foreign: foreign, parent: parent)
        }
    }
}

@MainActor
@safe final class XdgForeign {
    weak var delegate: (any XdgForeignDelegate)?

    private var handles: [String: WeakReference<WlSurface>] = [:]
    private var counter: UInt64 = 0

    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            ZxdgExporterV2Server.global(
                implementation: self,
                owner: { foreign, _ in XdgForeignBinding(foreign) }))
        router.addGlobal(
            ZxdgImporterV2Server.global(
                implementation: self,
                owner: { foreign, _ in XdgForeignBinding(foreign) }))
    }

    fileprivate func mint(_ surface: WlSurface) -> String {
        counter += 1
        let handle = "nucleus-export-\(counter)"
        handles[handle] = WeakReference(surface)
        return handle
    }

    fileprivate func surface(forHandle handle: String) -> WlSurface? {
        handles[handle]?.value
    }
    fileprivate func release(_ handle: String) { handles[handle] = nil }

}

/// An exported surface handle. Carries the handle event; releases the registry
/// entry on teardown.
@MainActor
@safe final class ZxdgExported {
    private unowned let foreign: XdgForeign
    private let handle: String
    private let resource: WaylandResourceHandle<ZxdgExportedV2Server>

    init(
        resource: WaylandResourceHandle<ZxdgExportedV2Server>,
        foreign: XdgForeign,
        handle: String
    ) {
        self.resource = resource
        self.foreign = foreign
        self.handle = handle
    }

    fileprivate func sendHandle() {
        resource.sendHandle(handle: handle)
    }

    isolated deinit { foreign.release(handle) }
}

/// An imported handle. set_parent_of makes the resolved exported surface the parent
/// of the named child surface.
@MainActor
@safe final class ZxdgImported {
    private let resource: WaylandResourceHandle<ZxdgImportedV2Server>
    private unowned let foreign: XdgForeign
    private weak var parent: WlSurface?

    init(
        resource: WaylandResourceHandle<ZxdgImportedV2Server>,
        foreign: XdgForeign,
        parent: WlSurface?
    ) {
        self.resource = resource
        self.foreign = foreign
        self.parent = parent
    }
}

extension ZxdgImported: ZxdgImportedV2Requests {
    func setParentOf(
        _ request: WaylandRequest<ZxdgImportedV2Server>, surface childRes: WaylandBorrowedObject<WlSurfaceServer>
    ) {
        guard let child = childRes.owner(as: WlSurface.self) else { return }
        foreign.delegate?.setForeignParent(child: child, parent: parent)
    }
}
