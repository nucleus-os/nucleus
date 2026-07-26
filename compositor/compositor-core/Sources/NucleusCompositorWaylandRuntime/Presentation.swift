// wp_presentation on the router. Lets a client request precise presentation
// feedback for a surface's content update: when (and on which output, with what
// timing/flags) the update became visible, or that it was discarded. The clock
// domain is advertised once on bind.
//
// A wp_presentation_feedback object has no requests — it is a pure event carrier
// (like wl_callback), owned by the exact surface commit and completed only by the
// matching submitted output frame.

import WaylandServerC
import WaylandServer
import WaylandServerDispatch
import Glibc

/// The presentation seam. The clock id is the CLOCK_* domain the compositor stamps
/// presentation times in (CLOCK_MONOTONIC by default).
@MainActor
protocol PresentationDelegate: AnyObject {
    var presentationClockId: UInt32 { get }
}

@MainActor
@safe final class WpPresentation {
    weak var delegate: (any PresentationDelegate)?
    var clockId: UInt32 {
        delegate?.presentationClockId ?? UInt32(CLOCK_MONOTONIC)
    }

    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            WpPresentationServer.global(
                implementation: self,
                advertisedVersion: 2,
                installed: { presentation, handle in
                    handle.sendClockId(clk_id: presentation.clockId)
                }))
    }
}

extension WpPresentation: WpPresentationRequests {
    // feedback(surface, callback): register a per-commit feedback on the surface.
    func feedback(_ request: WaylandRequest<WpPresentationServer>,
                  surface surfaceRes: WaylandBorrowedObject<WlSurfaceServer>,
                  callback: WlNewId<WpPresentationFeedbackServer>) {
        guard let surface = surfaceRes.owner(as: WlSurface.self) else { return }
        // wp_presentation_feedback has no requests: create it with no implementation,
        // exactly as wl_surface.frame does for wl_callback.
        guard let feedback = callback.createBare() else { return }
        surface.addPresentationFeedback(feedback)
    }
}
