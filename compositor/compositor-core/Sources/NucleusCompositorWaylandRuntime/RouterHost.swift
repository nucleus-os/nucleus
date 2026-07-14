// Process-wide holder for the live Wayland router and its runtime-owned services.
// The compositor reactor drives it on the main actor through `WaylandRuntime`.

import NucleusCompositorServer

@MainActor
final class RouterHost {
    static let shared = RouterHost()

    /// The live router, nil before compositor bring-up constructs it.
    var router: NucleusWaylandRouter?

    /// The per-frame scene feeder (drives `WindowSceneAuthor` from the Swift
    /// window model). nil before router activation constructs it; the compositor
    /// loop's per-output `WaylandRuntime.authorSceneFrame` call forwards here.
    var feeder: SceneFeeder?

    /// The constructed router graph (every protocol impl + driver), held here for
    /// the compositor's lifetime. nil before compositor bring-up.
    var runtime: WaylandRouterRuntime?

    /// The Xwayland integration manager (display sockets + subprocess + in-process
    /// XWM). nil until the reactor loop brings it up; reached by the router's reverse
    /// xwayland crossings (configure, set_serial) to drive the live XWM.
    var xwaylandHost: XwaylandHost?

    /// The Swift input backend (libseat session + libinput + udev + xkb + dispatch).
    /// nil before input bring-up constructs it; the loop's seat/libinput FD
    /// handlers drive it and the DRM bring-up borrows its seat for device opens.
    var inputHost: InputHost?

    private var presentationSequence: UInt64 = 0

    private init() {}

    func nextPresentationSequence() -> UInt64 {
        presentationSequence &+= 1
        return presentationSequence
    }
}

// The public verbs the composition root drives against this holder — activation, per-frame authoring,
// event-loop dispatch, presentation, and the session-lock gate — live on the `WaylandRuntime` facade
// (WaylandRuntime.swift), the module's only public entry point.
