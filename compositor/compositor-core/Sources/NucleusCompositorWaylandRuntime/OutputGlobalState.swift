import WaylandServerC

/// Independently removable output-global registration plus the live resources
/// that continue to outlive global withdrawal. This keeps hotplug lifetime state
/// separate from the output's advertised value snapshot.
final class OutputGlobalState {
    private var global: NucleusWaylandRouter.GlobalHandle?
    private(set) var resources: [UnsafeMutablePointer<wl_resource>] = []
    private var xdgOutputs: [WeakXdgOutput] = []

    func install(_ global: NucleusWaylandRouter.GlobalHandle?) -> Bool {
        self.global = global
        return global != nil
    }

    func withdraw() {
        global?.remove()
        global = nil
    }

    func addResource(_ resource: UnsafeMutablePointer<wl_resource>) {
        resources.append(resource)
    }

    func removeResource(_ resource: UnsafeMutablePointer<wl_resource>) {
        resources.removeAll { $0 == resource }
    }

    func resources(
        forClient client: OpaquePointer?
    ) -> [UnsafeMutablePointer<wl_resource>] {
        resources.filter { wl_resource_get_client($0) == client }
    }

    func registerXdgOutput(_ output: XdgOutput) {
        xdgOutputs.removeAll { $0.output == nil }
        xdgOutputs.append(WeakXdgOutput(output))
    }

    func liveXdgOutputs() -> [XdgOutput] {
        xdgOutputs.removeAll { $0.output == nil }
        return xdgOutputs.compactMap(\.output)
    }
}
