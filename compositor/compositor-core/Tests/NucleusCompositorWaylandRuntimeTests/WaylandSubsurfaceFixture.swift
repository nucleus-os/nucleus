// Parity fixture for wl_subcompositor / wl_subsurface topology. Builds a parent
// with two subsurfaces, reorders one below the parent, sets a position, and
// exercises synchronized-commit semantics — a sync child's commit is cached and
// applied only when the parent commits. Subsurface requests emit no wire events,
// so the in-process scene delegate observes the result.

import Glibc
import WaylandServerC

private func fail(_ msg: String) -> Never {
    print("FAIL: \(msg)")
    exit(1)
}

/// Records commit order (by object id) and keeps a handle to each surface seen.
private final class RecordingScene: SurfaceSceneDelegate {
    var order: [UInt32] = []
    var byId: [UInt32: WlSurface] = [:]
    func surfaceCommitted(_ surface: WlSurface, _ commit: SurfaceCommit) {
        order.append(surface.objectId)
        byId[surface.objectId] = surface
    }
    func surfaceDestroyed(_ surface: WlSurface) {}
}

@main
enum WaylandSubsurfaceFixture {
    static func main() {
        guard let router = NucleusWaylandRouter() else { fail("router") }
        let compositor = WlCompositor()
        let scene = RecordingScene()
        compositor.sceneDelegate = scene
        compositor.register(in: router)
        let subcompositor = WlSubcompositor()
        subcompositor.register(in: router)

        guard let client = WaylandTestClient(display: router.display) else { fail("client") }
        let globals = client.globals()
        func name(_ iface: String) -> (name: UInt32, version: UInt32) {
            guard let g = globals.first(where: { $0.interface == iface }) else { fail("no \(iface)") }
            return (g.name, g.version)
        }
        let comp = name("wl_compositor")
        let subc = name("wl_subcompositor")

        // ids: compositor 3, subcompositor 4, parent 5, childA 6, childB 7,
        // subA 8, subB 9.
        let compId: UInt32 = 3, subcId: UInt32 = 4
        let parent: UInt32 = 5, childA: UInt32 = 6, childB: UInt32 = 7
        let subA: UInt32 = 8, subB: UInt32 = 9

        var b1 = WireBuilder()
        b1.message(object: 2, opcode: 0) {  // bind wl_compositor
            $0.uint(comp.name); $0.string("wl_compositor"); $0.uint(comp.version); $0.newId(compId)
        }
        b1.message(object: 2, opcode: 0) {  // bind wl_subcompositor
            $0.uint(subc.name); $0.string("wl_subcompositor"); $0.uint(subc.version); $0.newId(subcId)
        }
        b1.message(object: compId, opcode: 0) { $0.newId(parent) }  // create_surface
        b1.message(object: compId, opcode: 0) { $0.newId(childA) }
        b1.message(object: compId, opcode: 0) { $0.newId(childB) }
        b1.message(object: subcId, opcode: 1) {                      // get_subsurface(childA, parent)
            $0.newId(subA); $0.object(childA); $0.object(parent)
        }
        b1.message(object: subcId, opcode: 1) {                      // get_subsurface(childB, parent)
            $0.newId(subB); $0.object(childB); $0.object(parent)
        }
        b1.message(object: subA, opcode: 1) { $0.int(10); $0.int(20) }   // set_position
        b1.message(object: subB, opcode: 3) { $0.object(parent) }        // place_below(parent)
        b1.message(object: childA, opcode: 6) { _ in }                   // childA.commit (sync → cached)
        guard client.send(b1) else { fail("send b1") }
        client.pump()

        // childA is synchronized; its commit is cached and the parent has not
        // committed, so nothing has reached the scene yet.
        guard scene.order.isEmpty else { fail("premature commits \(scene.order)") }

        var b2 = WireBuilder()
        b2.message(object: parent, opcode: 6) { _ in }  // parent.commit → applies + cascades childA
        guard client.send(b2) else { fail("send b2") }
        client.pump()

        // Parent applied first, then the cached sync child.
        guard scene.order == [parent, childA] else { fail("sync apply order \(scene.order)") }

        guard let parentSurface = scene.byId[parent] else { fail("parent not seen") }
        let order = parentSurface.subsurfaceOrder
        // childB placed below the parent's own content; childA remains above it.
        guard order == [childB, parent, childA] else { fail("z-order \(order)") }

        guard let childASurface = scene.byId[childA] else { fail("childA not seen") }
        guard childASurface.subsurfaceX == 10, childASurface.subsurfaceY == 20 else {
            fail("position \(childASurface.subsurfaceX),\(childASurface.subsurfaceY)")
        }

        let orderStr = order.map(String.init).joined(separator: ",")
        let applyStr = scene.order.map(String.init).joined(separator: ",")
        print("OK wayland subsurface order=\(orderStr) sync_apply=\(applyStr) "
            + "pos=\(childASurface.subsurfaceX),\(childASurface.subsurfaceY)")
    }
}
