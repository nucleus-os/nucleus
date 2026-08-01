// xdg-output-unstable-v1 on the router — advertises each output's compositor-space
// logical geometry (position, size) and user-facing name/description. The manager
// mints a per-(client, wl_output) zxdg_output_v1 that sources its description from
// the WlOutput model (resolved straight from the wl_output resource — no sink seam)
// and emits it on creation and every topology update. Read-only from the client;
// the compositor owns all output geometry.

import NucleusRenderModel
import WaylandServer
import WaylandServerC
import WaylandServerDispatch

@MainActor
@safe final class XdgOutputManager {
}

extension XdgOutputManager: ZxdgOutputManagerV1Requests {
    func getXdgOutput(
        _ request: WaylandRequest<ZxdgOutputManagerV1Server>,
        id: WlNewId<ZxdgOutputV1Server>,
        output outputRes: WaylandBorrowedObject<WlOutputServer>
    ) {
        guard let output = outputRes.output else { return }
        _ = id.create(
            owner: { handle in
                XdgOutput(resource: handle, output: output)
            },
            installed: { xdgOutput in
                output.registerXdgOutput(xdgOutput)
                xdgOutput.sendDescription()
            })
    }
}

/// One client's view of one output's logical geometry. Sources from the WlOutput.
@MainActor
@safe final class XdgOutput {
    private weak var output: WlOutput?
    private let resource: WaylandResourceHandle<ZxdgOutputV1Server>

    init(resource: WaylandResourceHandle<ZxdgOutputV1Server>, output: WlOutput) {
        self.resource = resource
        self.output = output
    }

    /// Emit logical position + size, then (v≥2) name + description, then done.
    func sendDescription() {
        guard let output else { return }
        let r = output.logicalRect
        resource.sendLogicalPosition(x: r.x, y: r.y)
        resource.sendLogicalSize(width: r.width, height: r.height)
        if resource.supportsName {
            resource.sendName(name: output.info.name)
            resource.sendDescription(description: output.info.description)
        }
        // Version 3 uses wl_output.done as the synchronization point and retires
        // zxdg_output_v1.done.
        if resource.version ?? 0 < 3 {
            resource.sendDone()
        }
    }
}
