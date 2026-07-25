import WaylandServerC
import WaylandServer
import WaylandServerDispatch

/// Independently removable output-global registration plus the live resources
/// that continue to outlive global withdrawal. This keeps hotplug lifetime state
/// separate from the output's advertised value snapshot.
@MainActor
@safe final class OutputGlobalState {
    private var global: NucleusWaylandRouter.GlobalHandle?
    private(set) var resources: [WaylandResourceHandle<WlOutputServer>] = []
    private var xdgOutputs: [WeakReference<XdgOutput>] = []

    func install(_ global: NucleusWaylandRouter.GlobalHandle?) -> Bool {
        self.global = global
        return global != nil
    }

    func withdraw() {
        global?.remove()
        global = nil
    }

    func addResource(_ resource: WaylandResourceHandle<WlOutputServer>) {
        resources.append(resource)
    }

    func removeResource(_ resource: WaylandResourceHandle<WlOutputServer>) {
        resources.removeAll { $0 === resource }
    }

    func resources(
        forClient client: WaylandClientID?
    ) -> [WaylandResourceHandle<WlOutputServer>] {
        resources.filter {
            $0.clientID == client
        }
    }

    func registerXdgOutput(_ output: XdgOutput) {
        xdgOutputs.removeAll { $0.value == nil }
        xdgOutputs.append(WeakReference(output))
    }

    func liveXdgOutputs() -> [XdgOutput] {
        xdgOutputs.removeAll { $0.value == nil }
        return xdgOutputs.compactMap(\.value)
    }
}
