// The public control surface of the compositor's Wayland-runtime module: the narrow set of verbs the
// composition root (the exe's CompositorRuntime / CompositorBringup) drives to bring the router live,
// pump it, author scene frames, and report presentation. These are ordinary Swift calls, NOT C-ABI
// entry points — the genuine native crossings are separate @_cdecl symbols elsewhere. The router
// graph (RouterHost, NucleusWaylandRouter, the protocol impls) stays internal to this module; this
// facade is the only way in, so the exe never touches the runtime's internals. Every entry runs on
// the compositor's main actor (the loop drives them on that thread) and crosses only Sendable values.

import Glibc
import WaylandServerC
import NucleusCompositorServer

public enum WaylandRuntime {
    // MARK: - Router lifecycle

    /// Construct the router graph. Idempotent.
    @MainActor public static func activateRouter() {
        guard RouterHost.shared.runtime == nil, let runtime = WaylandRouterRuntime() else { return }
        RouterHost.shared.runtime = runtime
        RouterHost.shared.router = runtime.router
        RouterHost.shared.feeder = runtime.feeder
    }

    /// Add a live wl_output global from a DRM output snapshot. `name`/`description` are NUL-terminated
    /// UTF-8 (or null for the defaults).
    @MainActor public static func addOutput(
        _ outputId: UInt64, _ x: Int32, _ y: Int32,
        _ physicalWidthMm: Int32, _ physicalHeightMm: Int32,
        _ pixelWidth: Int32, _ pixelHeight: Int32, _ refreshMhz: Int32, _ scale: Int32,
        _ logicalWidth: Int32, _ logicalHeight: Int32, _ fractionalScale: Double,
        _ name: UnsafePointer<CChar>?, _ description: UnsafePointer<CChar>?
    ) {
        let nm = name.map { String(cString: $0) } ?? "Nucleus"
        let desc = description.map { String(cString: $0) } ?? nm
        guard let runtime = RouterHost.shared.runtime else { return }
        runtime.addOutput(OutputInfo(
            outputId: outputId, x: x, y: y,
            physicalWidthMm: physicalWidthMm, physicalHeightMm: physicalHeightMm,
            pixelWidth: pixelWidth, pixelHeight: pixelHeight, refreshMhz: refreshMhz, scale: scale,
            name: nm, description: desc,
            logicalWidth: logicalWidth, logicalHeight: logicalHeight,
            fractionalScale: fractionalScale))
    }

    /// Add the listen socket and export WAYLAND_DISPLAY/XDG_SESSION_TYPE. Returns true on success.
    /// (Xwayland's parent socket fd is adopted directly through `router.display.createClient(fd:)`.)
    @MainActor public static func addSocket() -> Bool {
        guard let runtime = RouterHost.shared.runtime,
            let name = runtime.router.display.addSocketAuto()
        else { return false }
        setenv("WAYLAND_DISPLAY", name, 1)
        setenv("XDG_SESSION_TYPE", "wayland", 1)
        return true
    }

    // MARK: - Event loop

    /// The router's aggregate event-loop epoll fd, for the reactor's one multishot poll registration
    /// (the `wayland_loop` token). -1 before the router exists.
    @MainActor public static func eventLoopFd() -> Int32 {
        RouterHost.shared.router?.eventLoopFd ?? -1
    }

    /// The router's aggregate `wl_event_loop` epoll fd became readable: dispatch queued client requests
    /// into the Swift protocol impls, project window-model changes to the external-shell observers, and
    /// flush the resulting events back.
    @MainActor public static func dispatch() {
        guard let router = RouterHost.shared.router else { return }
        router.dispatch()
        NucleusCompositorServer.shared.drainChanges()
        router.flushClients()
    }

    // MARK: - Per-frame authoring + presentation

    /// One presentation frame for `outputId` (predicted to present at `predictedPresentNs`): advance +
    /// author each scene-visible window's eased tiling layout, model z-stack, output membership, and
    /// session-lock blank into the retained tree, ahead of the render pass. Returns whether any tile
    /// animation is still in flight, so the loop keeps requesting frames. No-op (false) until the
    /// feeder is constructed at router activation.
    @MainActor public static func authorSceneFrame(outputId: UInt64, predictedPresentNs: UInt64) -> Bool {
        RouterHost.shared.feeder?.authorFrame(
            outputID: outputId, predictedPresentNs: predictedPresentNs) ?? false
    }

    /// A page flip completed on `outputId`: fire the presented surfaces' wl_surface.frame callbacks and
    /// deliver wp_presentation_feedback.presented with the kernel flip time (`presentationNs`, ns), the
    /// `refreshNs` interval, and the vblank `sequence` (MSC). The frame-callback clock is milliseconds
    /// (undefined base, per wl_surface.frame); the feedback timestamp/MSC split into protocol hi/lo.
    @MainActor public static func notePresented(
        _ outputId: UInt64, _ presentationNs: UInt64, _ refreshNs: UInt32, _ sequence: UInt64
    ) {
        guard let router = RouterHost.shared.router else { return }
        RouterHost.shared.feeder?.outputPresented(outputId)
        router.completeFrameCallbacks(forOutput: outputId,
                                      timeMs: UInt32(truncatingIfNeeded: presentationNs / 1_000_000))
        router.completePresentedFrame(outputId: outputId, timestampNs: presentationNs,
                                      refreshNs: refreshNs, sequence: sequence, flags: 0)
    }

    /// A renderer-imported client generation is no longer referenced by Vulkan or
    /// KMS. Complete the corresponding wl_buffer and wl_surface.get_release events.
    @MainActor public static func noteSurfaceBufferRetired(_ iosurfaceID: UInt32) {
        RouterHost.shared.runtime?.compositor.retireBuffer(iosurfaceID: iosurfaceID)
    }

    // MARK: - Session lock (the security gate)

    /// A page flip completed on `outputId`: advance the session-lock present ack. Once every awaited
    /// output has presented a frame authored *after* the lock began (the begin-time present-id
    /// threshold), the gate emits `locked` — the security invariant confirmed by a real present, not
    /// asserted at author time. No-op unless a lock is active. Called after the DisplayLink ack.
    @MainActor public static func noteSessionLockPresented(_ outputId: UInt64) {
        SessionLockGate.noteOutputPresented(outputID: outputId)
    }

    /// The session-lock composition the render core enforces this frame: per output, the layer-context
    /// ids of the mapped ext-session-lock surfaces to composite over the opaque ground. `nil` when no
    /// lock is active (the render core composes normally); a locked output with no lock surface yet
    /// maps to an empty set (fully blank). Recomputed each frame from the authoritative window model.
    @MainActor public static func sessionLockComposition() -> [UInt64: Set<UInt32>]? {
        guard SessionLockGate.isActive(), let feeder = RouterHost.shared.feeder else { return nil }
        var perOutput: [UInt64: Set<UInt32>] = [:]
        for display in NucleusCompositorServer.shared.layout.displays {
            perOutput[display.id] = feeder.lockSurfaceContexts(outputID: display.id)
        }
        return perOutput
    }
}
