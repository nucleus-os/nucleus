// wl_compositor on the router. Mints wl_surface and wl_region objects and owns
// the three shared request vtables (compositor/surface/region) plus the scene
// delegate every surface reports commits to. Each bound compositor resource
// carries a CompositorBinding that points back here so the @convention(c) request
// handlers — which cannot capture — can reach the shared state.
//
// The compositor holds weak references to live surfaces only (Rule 9: each
// wl_surface is owned solely by its resource's user_data), used to drive the
// presentation tick across every surface.

import WaylandServerC
import NucleusCompositorWindowManager
import WaylandServer
import WaylandServerDispatch

/// Owner bound to each wl_compositor resource (Rule 9). Routes create_surface /
/// create_region back to the shared WlCompositor.
final class CompositorBinding {
    unowned let compositor: WlCompositor
    init(_ compositor: WlCompositor) { self.compositor = compositor }
}

// The wl_compositor request handlers, recovered by WlCompositorServer.vtable from the
// per-resource CompositorBinding owner and forwarded to the shared WlCompositor factory verbs.
extension CompositorBinding: WlCompositorRequests {
    func createSurface(_ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId) {
        _ = compositor.makeSurface(client: id.client, id: id.id, version: id.version)
    }
    func createRegion(_ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId) {
        _ = compositor.makeRegion(client: id.client, id: id.id, version: id.version)
    }
}

private final class WeakSurface {
    weak var surface: WlSurface?
    /// The surface's wire object id captured at registration, so the id→surface
    /// index can be cleaned up in `removeSurface` even after the resource (and thus
    /// `surface.objectId`) is gone.
    let objectId: UInt32
    init(_ surface: WlSurface) {
        self.surface = surface
        self.objectId = surface.objectId
    }
}

final class WlCompositor {
    /// Scene/render seam; surfaces report commits and destruction here.
    weak var sceneDelegate: SurfaceSceneDelegate?
    /// Buffer-scale hint sent to each surface on creation (v6+). The per-output
    /// resolution is `updateEnteredOutputs`, which recomputes preferred scale from
    /// the outputs a surface currently overlaps; this is the pre-membership default.
    var preferredBufferScale: Int32 = 1

    private var surfaces: [WeakSurface] = []
    /// `objectId -> WeakSurface` index for O(1) `surface(id:)` — the hot per-input /
    /// per-commit / per-hit-test-candidate lookup. The `surfaces` array remains the
    /// authority for the whole-list presentation walks; this mirrors it for keyed
    /// resolution. Maintained in register/removeSurface.
    private var surfacesByObjectId: [UInt32: WeakSurface] = [:]
    private struct DeferredBufferRelease {
        let buffer: WaylandResourceReference
        let callback: WaylandResourceReference?
    }
    private var deferredBufferReleases: [UInt32: [DeferredBufferRelease]] = [:]

    func deferBufferRelease(
        iosurfaceID: UInt32, buffer: WaylandResourceReference,
        callback: UnsafeMutablePointer<wl_resource>?
    ) {
        guard iosurfaceID != 0 else {
            if let resource = buffer.resource { wl_buffer_send_release(resource) }
            if let callback { wl_callback_send_done(callback, 0); wl_resource_destroy(callback) }
            return
        }
        deferredBufferReleases[iosurfaceID, default: []].append(DeferredBufferRelease(
            buffer: buffer,
            callback: callback.flatMap { WaylandResourceReference($0) }))
    }

    /// The renderer retired one imported generation under this stable IOSurface id.
    /// Release entries FIFO because imports and GPU retirement preserve queue order.
    func retireBuffer(iosurfaceID: UInt32) {
        guard var releases = deferredBufferReleases[iosurfaceID], !releases.isEmpty else { return }
        let release = releases.removeFirst()
        if releases.isEmpty { deferredBufferReleases[iosurfaceID] = nil }
        else { deferredBufferReleases[iosurfaceID] = releases }
        if let resource = release.buffer.resource { wl_buffer_send_release(resource) }
        if let callback = release.callback?.resource {
            wl_callback_send_done(callback, 0)
            wl_resource_destroy(callback)
        }
    }

    /// Live wl_output advertisements, retained for the compositor's lifetime (the
    /// router also retains them as global bind data). A surface maps an overlapping
    /// DisplayID to a bound wl_output resource for `wl_surface.enter`/`leave`.
    private(set) var outputs: [WlOutput] = []

    func addOutput(_ output: WlOutput) { outputs.append(output) }

    /// The advertised output with this DisplayID, if any.
    func output(id: UInt64) -> WlOutput? {
        for output in outputs where output.outputId == id { return output }
        return nil
    }

    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            interface: swift_wayland_iface_wl_compositor(), version: 6, impl: self, bind: Self.bind
        )
    }

    // MARK: surface registry (weak; for the presentation tick)

    func registerSurface(_ surface: WlSurface) {
        let box = WeakSurface(surface)
        surfaces.append(box)
        surfacesByObjectId[box.objectId] = box
    }

    func removeSurface(_ surface: WlSurface) {
        for box in surfaces where box.surface == nil || box.surface === surface {
            // Identity-checked so a reused object id (a new surface already indexed
            // under this id) is never clobbered by the departing one's cleanup.
            if surfacesByObjectId[box.objectId] === box { surfacesByObjectId[box.objectId] = nil }
        }
        surfaces.removeAll { $0.surface == nil || $0.surface === surface }
    }

    /// The live surface with this wire object id, if any. Maps a focus target
    /// (arriving as a wl_resource id) to its surface model; also a fixture probe.
    func surface(id: UInt32) -> WlSurface? {
        guard let box = surfacesByObjectId[id] else { return nil }
        guard let s = box.surface else { surfacesByObjectId[id] = nil; return nil }
        return s
    }

    /// Compact dead-surface boxes from the list and the id index. Called by the
    /// surface-list walks only when a dead box was actually observed, so the common
    /// (nothing-died) presentation-tick / query path does not reallocate `surfaces`.
    private func compactDeadSurfaces() {
        surfaces.removeAll { box in
            guard box.surface == nil else { return false }
            if surfacesByObjectId[box.objectId] === box { surfacesByObjectId[box.objectId] = nil }
            return true
        }
    }

    /// Count of live xdg popups whose parent is the surface with this wire id. The
    /// scanout planner reads this to disqualify a fullscreen surface from plane
    /// promotion when it has popups, replacing the `WLSurface.popups` read. Prunes
    /// dead surfaces on the walk, mirroring the other surface-list queries.
    func popupCount(forParentSurfaceId id: UInt32) -> UInt32 {
        guard let parent = surface(id: id) else { return 0 }
        var count: UInt32 = 0
        var sawDead = false
        for box in surfaces {
            guard let s = box.surface else { sawDead = true; continue }
            if let xdg = s.role as? XdgSurface, let popup = xdg.popup,
                popup.parent?.surface === parent
            {
                count += 1
            }
        }
        if sawDead { compactDeadSurfaces() }
        return count
    }

    func hasMappedLayerSurface(on outputID: UInt64) -> Bool {
        var found = false
        var sawDead = false
        for box in surfaces {
            guard let surface = box.surface else { sawDead = true; continue }
            if let layer = surface.role as? ZwlrLayerSurface,
                layer.mapped,
                layer.outputID == outputID
            {
                found = true
            }
        }
        if sawDead { compactDeadSurfaces() }
        return found
    }

    @MainActor
    func hasAsyncPresentationRequest(on outputID: UInt64) -> Bool {
        var found = false
        var sawDead = false
        for box in surfaces {
            guard let surface = box.surface else { sawDead = true; continue }
            if surface.aux.presentationHint == 1,
                surfaceTargetsOutput(surface, outputID: outputID)
            {
                found = true
            }
        }
        if sawDead { compactDeadSurfaces() }
        return found
    }

    @MainActor
    private func surfaceTargetsOutput(_ surface: WlSurface, outputID: UInt64) -> Bool {
        if outputID == 0 { return true }
        // Role pins are authoritative: a layer/lock surface is bound to one output
        // regardless of geometric overlap.
        if let layer = surface.role as? ZwlrLayerSurface {
            return layer.outputID == outputID
        }
        if let lock = surface.role as? ExtSessionLockSurface {
            return lock.outputID == outputID
        }
        // Precise membership when the presentation walk has reported it — this covers
        // toplevels (including multi-output spans), popups, and subsurfaces, which the
        // window-id lookup below resolves only to a single dominant output.
        if surface.hasKnownOutputMembership {
            return surface.overlapsOutput(outputID)
        }
        if let window = WindowManager.shared.server.windows.window(bySurfaceObjectId: surface.objectId),
            let currentOutputID = window.currentOutputID
        {
            return currentOutputID == outputID
        }
        // No membership reported yet and no owning window: keep the callback
        // conservative (deliver everywhere) rather than dropping it.
        return true
    }

    /// Complete frame callbacks on every live surface (presentation tick).
    func present(timeMs: UInt32) {
        var sawDead = false
        for box in surfaces {
            if let s = box.surface { s.present(timeMs: timeMs) } else { sawDead = true }
        }
        if sawDead { compactDeadSurfaces() }
    }

    @MainActor
    func present(forOutput outputID: UInt64, timeMs: UInt32) {
        var sawDead = false
        for box in surfaces {
            guard let s = box.surface else { sawDead = true; continue }
            if surfaceTargetsOutput(s, outputID: outputID) {
                s.present(timeMs: timeMs)
            }
        }
        if sawDead { compactDeadSurfaces() }
    }

    /// Deliver wp_presentation_feedback.presented to every live surface's
    /// awaiting feedbacks (the page-flip tick). Prunes dead surfaces, mirroring
    /// `present`. Kept for all-output fixture paths and offscreen fallback.
    func presentFeedbackAll(
        tvSecHi: UInt32, tvSecLo: UInt32, tvNsec: UInt32,
        refreshNs: UInt32, seqHi: UInt32, seqLo: UInt32, flags: UInt32
    ) {
        var sawDead = false
        for box in surfaces {
            guard let s = box.surface else { sawDead = true; continue }
            s.presentFeedback(
                tvSecHi: tvSecHi, tvSecLo: tvSecLo, tvNsec: tvNsec,
                refreshNs: refreshNs, seqHi: seqHi, seqLo: seqLo, flags: flags)
        }
        if sawDead { compactDeadSurfaces() }
    }

    @MainActor
    func presentFeedback(
        forOutput outputID: UInt64,
        tvSecHi: UInt32, tvSecLo: UInt32, tvNsec: UInt32,
        refreshNs: UInt32, seqHi: UInt32, seqLo: UInt32, flags: UInt32
    ) {
        var sawDead = false
        for box in surfaces {
            guard let s = box.surface else { sawDead = true; continue }
            if surfaceTargetsOutput(s, outputID: outputID) {
                s.presentFeedback(
                    tvSecHi: tvSecHi, tvSecLo: tvSecLo, tvNsec: tvNsec,
                    refreshNs: refreshNs, seqHi: seqHi, seqLo: seqLo, flags: flags)
            }
        }
        if sawDead { compactDeadSurfaces() }
    }

    func makeRegion(
        client: OpaquePointer, id: UInt32, version: Int32
    ) -> UnsafeMutablePointer<wl_resource>? {
        WaylandResource.create(
            client: client, interface: swift_wayland_iface_wl_region(),
            version: version, id: id, vtable: WlRegionServer.vtable, owner: WlRegion()
        )
    }

    // MARK: bind

    private static let bind: @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32
    ) -> Void = { client, data, version, id in
        guard let client, let me = NucleusWaylandRouter.impl(data, as: WlCompositor.self) else {
            return
        }
        _ = WaylandResource.create(
            client: client, interface: swift_wayland_iface_wl_compositor(),
            version: Int32(version), id: id, vtable: WlCompositorServer.vtable,
            owner: CompositorBinding(me)
        )
    }
}
