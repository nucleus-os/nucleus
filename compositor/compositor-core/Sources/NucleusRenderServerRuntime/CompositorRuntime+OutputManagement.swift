import NucleusCompositorWaylandRuntime
import NucleusConfig

// Applying a display configuration that arrived over the wire.
//
// The protocol object has already rejected anything unachievable, so what
// reaches here is only scale and position. Applying is a full reconcile with a
// forced re-attach: storing the values alone would defer the visible change to
// the next hotplug, which to a user looks like the tool silently failed.

extension CompositorRuntime: OutputManagementDelegate {
    func applyOutputConfiguration(
        _ requests: [OutputConfigurationRequest]
    ) -> Bool {
        for request in requests {
            let position: OutputPosition?
            if let x = request.positionX, let y = request.positionY {
                position = OutputPosition(x: Double(x), y: Double(y))
            } else {
                position = nil
            }
            // The name is unused on this path — the reconciler keys protocol
            // overrides by output id, which is stable across a rename.
            outputTopology.protocolOverrides[request.outputID] = OutputConfig(
                name: "",
                scale: request.scale,
                position: position)
        }
        return outputTopology.reconcile(forceReattach: true)
    }
}
