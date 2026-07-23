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
internal import NucleusCompositorServer
internal import NucleusCompositorWindowManager
import WaylandServer
import WaylandServerDispatch

struct PresentedSurfaceCommit: Sendable, Equatable {
    let surfaceID: UInt32
    let commitID: UInt64
}

struct SubmittedOutputFrame: Sendable, Equatable {
    let outputID: UInt64
    let outputGeneration: UInt64
    let submissionID: UInt64
    let sampledCommits: [PresentedSurfaceCommit]
    let targetPresentationNs: UInt64
}

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
        let compositorBits = UInt(
            bitPattern: Unmanaged.passUnretained(compositor).toOpaque())
        let clientBits = UInt(bitPattern: UnsafeRawPointer(id.client))
        let objectID = id.id
        let version = id.version
        MainActor.assumeIsolated {
            guard let compositorPointer = UnsafeRawPointer(
                bitPattern: compositorBits),
                let clientPointer = UnsafeRawPointer(bitPattern: clientBits)
            else { return }
            let compositor = Unmanaged<WlCompositor>
                .fromOpaque(compositorPointer).takeUnretainedValue()
            _ = compositor.makeSurface(
                client: OpaquePointer(clientPointer),
                id: objectID,
                version: version)
        }
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
    /// Current renderer content identity. Mirrored here so a dead weak reference
    /// can still be removed from the presentation-sampling index.
    var renderIOSurfaceID: UInt32
    init(_ surface: WlSurface) {
        self.surface = surface
        self.objectId = surface.objectId
        self.renderIOSurfaceID = surface.renderIosurfaceId
    }
}

final class WlCompositor {
    unowned let host: RouterHost
    private struct SubmittedFrameKey: Hashable {
        let outputID: UInt64
        let outputGeneration: UInt64
        let submissionID: UInt64
    }

    /// Scene/render seam; surfaces report commits and destruction here.
    weak var sceneDelegate: (any SurfaceSceneDelegate)?
    /// Buffer-scale hint sent to each surface on creation (v6+). The per-output
    /// resolution is `updateEnteredOutputs`, which recomputes preferred scale from
    /// the outputs a surface currently overlaps; this is the pre-membership default.
    var preferredBufferScale: Int32 = 1

    private var surfaces: [WeakSurface] = []
    /// `objectId -> WeakSurface` index for O(1) `surface(id:)` — the hot per-input /
    /// per-commit / per-hit-test-candidate lookup. Maintained in
    /// register/removeSurface.
    private var surfacesByObjectId: [UInt32: WeakSurface] = [:]
    private var nextSyntheticSurfaceID: UInt32 = .max
    /// Stable renderer content identity → surface. Frame submission reports these
    /// identities, so exact commit sampling must not scan every live surface once
    /// for every visible scene node.
    private var surfacesByRenderIOSurfaceID: [UInt32: WeakSurface] = [:]
    private var submittedFrames: [SubmittedFrameKey: SubmittedOutputFrame] = [:]
    private struct DeferredBufferRelease {
        let buffer: WaylandResourceReference
        let callback: WaylandResourceReference?
    }
    private var deferredBufferReleases: [UInt32: [DeferredBufferRelease]] = [:]

    init(host: RouterHost) {
        self.host = host
    }

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
    private var preparedOutputRemovals: Set<UInt64> = []

    func addOutput(_ output: WlOutput) { outputs.append(output) }

    /// Emit every output-bound teardown while the output and its bound resources
    /// are still resolvable. The composition root then migrates windows/focus
    /// using the old and fallback geometries before withdrawing the global.
    @discardableResult
    func prepareOutputRemoval(id: UInt64) -> Bool {
        guard output(id: id) != nil else { return false }
        guard preparedOutputRemovals.insert(id).inserted else {
            return true
        }
        discardSubmittedFrames(outputID: id)
        var sawDead = false
        for box in surfaces {
            guard let surface = box.surface else { sawDead = true; continue }
            surface.removeEnteredOutput(id)
            if let layer = surface.role as? ZwlrLayerSurface,
                layer.outputID == id
            {
                layer.outputRemoved()
            }
            if let lock = surface.role as? ExtSessionLockSurface,
                lock.outputID == id
            {
                lock.outputRemoved()
            }
        }
        if sawDead { compactDeadSurfaces() }
        return true
    }

    /// Withdraw an output after its surface relationships and shell ownership
    /// have been prepared and window policy has migrated dependent state.
    func finishOutputRemoval(id: UInt64) -> WlOutput? {
        guard let index = outputs.firstIndex(where: { $0.outputId == id }) else {
            return nil
        }
        if !preparedOutputRemovals.contains(id) {
            _ = prepareOutputRemoval(id: id)
        }
        preparedOutputRemovals.remove(id)
        let output = outputs.remove(at: index)
        output.removeGlobal()
        return output
    }

    func removeOutput(id: UInt64) -> WlOutput? {
        guard prepareOutputRemoval(id: id) else { return nil }
        return finishOutputRemoval(id: id)
    }

    /// Reconfigure every role whose geometry is pinned to a changed output.
    /// This runs immediately after WlOutput applies the new logical state, so role
    /// configures and shell geometry observe the same output generation.
    func outputStateChanged(id: UInt64) {
        guard let output = output(id: id) else { return }
        var sawDead = false
        for box in surfaces {
            guard let surface = box.surface else {
                sawDead = true
                continue
            }
            if let layer = surface.role as? ZwlrLayerSurface,
                layer.outputID == id
            {
                layer.outputChanged(rect: output.logicalRect)
            }
            if let lock = surface.role as? ExtSessionLockSurface,
                lock.outputID == id
            {
                lock.outputChanged()
            }
        }
        if sawDead { compactDeadSurfaces() }
    }

    /// Freeze the exact applied commits sampled by an accepted KMS submission.
    /// Page-flip completion consumes this immutable record and never scans mutable
    /// live-surface targeting state.
    func submitFrame(
        outputID: UInt64,
        outputGeneration: UInt64,
        submissionID: UInt64,
        targetPresentationNs: UInt64,
        sampledIOSurfaceIDs: [UInt64]
    ) {
        var sampled: [PresentedSurfaceCommit] = []
        sampled.reserveCapacity(sampledIOSurfaceIDs.count)
        for iosurfaceID in Set(sampledIOSurfaceIDs) where iosurfaceID != 0 {
            guard let renderID = UInt32(exactly: iosurfaceID),
                let surface = surface(renderIOSurfaceID: renderID),
                let commitID = surface.noteSampled(submissionID: submissionID)
            else { continue }
            sampled.append(PresentedSurfaceCommit(
                surfaceID: surface.objectId, commitID: commitID))
        }
        sampled.sort {
            if $0.surfaceID != $1.surfaceID {
                return $0.surfaceID < $1.surfaceID
            }
            return $0.commitID < $1.commitID
        }
        let key = SubmittedFrameKey(
            outputID: outputID,
            outputGeneration: outputGeneration,
            submissionID: submissionID)
        submittedFrames[key] = SubmittedOutputFrame(
            outputID: outputID,
            outputGeneration: outputGeneration,
            submissionID: submissionID,
            sampledCommits: sampled,
            targetPresentationNs: targetPresentationNs)
    }

    func presentSubmittedFrame(
        outputID: UInt64,
        outputGeneration: UInt64,
        submissionID: UInt64,
        timestampNs: UInt64,
        refreshNs: UInt32,
        sequence: UInt64,
        flags: UInt32
    ) {
        let key = SubmittedFrameKey(
            outputID: outputID,
            outputGeneration: outputGeneration,
            submissionID: submissionID)
        guard let frame = submittedFrames.removeValue(forKey: key) else {
            return
        }
        let tvSec = timestampNs / 1_000_000_000
        let output = output(id: outputID)
        for sampled in frame.sampledCommits {
            surface(id: sampled.surfaceID)?.completePresentation(
                commitID: sampled.commitID,
                submissionID: submissionID,
                output: output,
                timeMs: UInt32(truncatingIfNeeded: timestampNs / 1_000_000),
                tvSecHi: UInt32(truncatingIfNeeded: tvSec >> 32),
                tvSecLo: UInt32(truncatingIfNeeded: tvSec),
                tvNsec: UInt32(timestampNs % 1_000_000_000),
                refreshNs: refreshNs,
                seqHi: UInt32(truncatingIfNeeded: sequence >> 32),
                seqLo: UInt32(truncatingIfNeeded: sequence),
                flags: flags)
        }
    }

    func discardSubmittedFrames(
        outputID: UInt64? = nil,
        outputGeneration: UInt64? = nil,
        submissionID: UInt64? = nil
    ) {
        let keys = submittedFrames.keys.filter {
            (outputID == nil || $0.outputID == outputID)
                && (outputGeneration == nil
                    || $0.outputGeneration == outputGeneration)
                && (submissionID == nil || $0.submissionID == submissionID)
        }
        for key in keys {
            guard let frame = submittedFrames.removeValue(forKey: key) else {
                continue
            }
            for sampled in frame.sampledCommits {
                surface(id: sampled.surfaceID)?.discardPresentation(
                    commitID: sampled.commitID,
                    submissionID: frame.submissionID)
            }
        }
    }

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
        if box.renderIOSurfaceID != 0 {
            surfacesByRenderIOSurfaceID[box.renderIOSurfaceID] = box
        }
    }

    func allocateSurfaceIdentity(preferred wireObjectID: UInt32) -> UInt32 {
        if wireObjectID != 0,
            surfacesByObjectId[wireObjectID]?.surface == nil
        {
            return wireObjectID
        }
        while nextSyntheticSurfaceID == 0
            || surfacesByObjectId[nextSyntheticSurfaceID]?.surface != nil
        {
            nextSyntheticSurfaceID &-= 1
            precondition(
                nextSyntheticSurfaceID != 0,
                "compositor surface identity exhausted")
        }
        let result = nextSyntheticSurfaceID
        nextSyntheticSurfaceID &-= 1
        return result
    }

    var liveSurfaceIDs: Set<UInt32> {
        Set(surfaces.compactMap { $0.surface?.objectId })
    }

    func removeSurface(_ surface: WlSurface) {
        for box in surfaces where box.surface == nil || box.surface === surface {
            // Identity-checked so a reused object id (a new surface already indexed
            // under this id) is never clobbered by the departing one's cleanup.
            if surfacesByObjectId[box.objectId] === box { surfacesByObjectId[box.objectId] = nil }
            if box.renderIOSurfaceID != 0,
                surfacesByRenderIOSurfaceID[box.renderIOSurfaceID] === box
            {
                surfacesByRenderIOSurfaceID[box.renderIOSurfaceID] = nil
            }
        }
        surfaces.removeAll { $0.surface == nil || $0.surface === surface }
    }

    func surfaceRenderIdentityChanged(
        _ surface: WlSurface,
        from oldID: UInt32
    ) {
        guard let box = surfacesByObjectId[surface.objectId],
            box.surface === surface
        else { return }
        if oldID != 0,
            surfacesByRenderIOSurfaceID[oldID] === box
        {
            surfacesByRenderIOSurfaceID[oldID] = nil
        }
        box.renderIOSurfaceID = surface.renderIosurfaceId
        if box.renderIOSurfaceID != 0 {
            surfacesByRenderIOSurfaceID[
                box.renderIOSurfaceID] = box
        }
    }

    /// The live surface with this process-unique compositor identity.
    func surface(id: UInt32) -> WlSurface? {
        guard let box = surfacesByObjectId[id] else { return nil }
        guard let s = box.surface else { surfacesByObjectId[id] = nil; return nil }
        return s
    }

    private func surface(
        renderIOSurfaceID: UInt32
    ) -> WlSurface? {
        guard let box =
            surfacesByRenderIOSurfaceID[renderIOSurfaceID]
        else { return nil }
        guard let surface = box.surface else {
            surfacesByRenderIOSurfaceID[
                renderIOSurfaceID] = nil
            return nil
        }
        return surface
    }

    /// Compact dead-surface boxes from the list and the id index. Called by the
    /// surface-list walks only when a dead box was actually observed, so the common
    /// (nothing-died) presentation-tick / query path does not reallocate `surfaces`.
    private func compactDeadSurfaces() {
        surfaces.removeAll { box in
            guard box.surface == nil else { return false }
            if surfacesByObjectId[box.objectId] === box { surfacesByObjectId[box.objectId] = nil }
            if box.renderIOSurfaceID != 0,
                surfacesByRenderIOSurfaceID[box.renderIOSurfaceID] === box
            {
                surfacesByRenderIOSurfaceID[
                    box.renderIOSurfaceID] = nil
            }
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
        if let window = host.server.windows.window(bySurfaceObjectId: surface.objectId),
            let currentOutputID = window.currentOutputID
        {
            return currentOutputID == outputID
        }
        // No membership reported yet and no owning window: keep the callback
        // conservative (deliver everywhere) rather than dropping it.
        return true
    }

    /// Complete frame callbacks on every live surface (presentation tick).
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
