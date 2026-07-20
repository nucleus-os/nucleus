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
protocol PresentationDelegate: AnyObject {
    var presentationClockId: UInt32 { get }
}

final class WpPresentation {
    weak var delegate: PresentationDelegate?
    var clockId: UInt32 {
        delegate?.presentationClockId ?? UInt32(CLOCK_MONOTONIC)
    }

    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            interface: swift_wayland_iface_wp_presentation(), version: 2, impl: self, bind: Self.bind)
    }

    private static let bind: @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32
    ) -> Void = { client, data, version, id in
        guard let client, let me = NucleusWaylandRouter.impl(data, as: WpPresentation.self) else {
            return
        }
        guard let res = WaylandResource.create(
            client: client, interface: swift_wayland_iface_wp_presentation(),
            version: Int32(version), id: id, vtable: WpPresentationServer.vtable, owner: me)
        else { return }
        wp_presentation_send_clock_id(res, me.clockId)
    }
}

extension WpPresentation: WpPresentationRequests {
    // feedback(surface, callback): register a per-commit feedback on the surface.
    func feedback(_ resource: UnsafeMutablePointer<wl_resource>,
                  surface surfaceRes: UnsafeMutablePointer<wl_resource>?, callback: WlNewId) {
        guard let surfaceRes, let surface = WaylandResource.owner(of: surfaceRes, as: WlSurface.self)
        else { return }
        // wp_presentation_feedback has no requests: create it with no implementation,
        // exactly as wl_surface.frame does for wl_callback.
        guard let feedback = callback.createBare() else { return }
        surface.addPresentationFeedback(feedback)
    }
}
