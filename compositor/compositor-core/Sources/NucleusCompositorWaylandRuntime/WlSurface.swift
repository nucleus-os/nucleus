// wl_surface on the router — the compositor's content-update transaction model
// (boundary plan line 207: "Preserve pending/committed wl_surface transaction
// semantics in Swift. Libwayland owns message/resource mechanics, not compositor
// content-update policy.").
//
// Protocol requests accumulate into double-buffered `pending` state; commit
// latches pending → current atomically, manages wl_buffer release, and snapshots
// the update to the scene delegate. Frame callbacks accumulated across commits
// complete on the next presentation tick.
//
// The scene delegate is the seam to the render/scene system. Today it is a
// libwayland-independent protocol the parity fixtures observe; at go-live (#12)
// the live implementation is the Swift WindowSceneHost owner (surface attach,
// content, layout, damage), so the surface model drives scene authoring directly
// rather than through today's trampoline.

import WaylandServerC
import WaylandServer
import WaylandServerDispatch
import NucleusTypes

/// A rectangle in fractional buffer coordinates (wp_viewport source is fixed-point).
typealias WlFRect = BufferPixelRect

/// An integer size (wp_viewport destination override, in surface-local pixels).
struct WlSize: Equatable, Sendable {
    var width: Int32
    var height: Int32
}

extension WlSize {
    var surfaceLogicalSize: SurfaceLogicalSize {
        SurfaceLogicalSize(width: Double(width), height: Double(height))
    }
}

func resolveSurfaceLogicalSize(
    pixels: BufferPixelSize, bufferScale: Int32, bufferTransform: Int32,
    viewportDestination: WlSize?
) -> SurfaceLogicalSize {
    if let viewportDestination { return viewportDestination.surfaceLogicalSize }
    // wl_output_transform 90/270 variants exchange the buffer axes before the
    // integer buffer scale projects into surface-local coordinates.
    let swapsAxes = bufferTransform == 1 || bufferTransform == 3
        || bufferTransform == 5 || bufferTransform == 7
    let width = swapsAxes ? pixels.height : pixels.width
    let height = swapsAxes ? pixels.width : pixels.height
    let scale = Double(max(1, bufferScale))
    return SurfaceLogicalSize(
        width: Double(width) / scale,
        height: Double(height) / scale)
}

/// Surface-adjacent protocol state resolved at one commit and carried as part of
/// the content-update transaction (boundary plan line 205: the router owns
/// viewport, tearing, and timing). Accumulated into the surface's pending state,
/// latched alongside content on wl_surface.commit.
struct SurfaceAuxState: Equatable, Sendable {
    /// wp_viewport crop rect in buffer coordinates; nil = full buffer. Sticky.
    var viewportSource: WlFRect?
    /// wp_viewport logical-size override; nil = unset (use buffer size). Sticky.
    var viewportDestination: WlSize?
    /// wp_tearing_control_v1.presentation_hint: 0 = vsync, 1 = async. Sticky.
    var presentationHint: UInt32 = 0
    /// wp_commit_timer_v1 target presentation time (ns, presentation clock domain);
    /// nil = none. Per-commit: consumed by each commit, not carried forward.
    var commitTimestampNs: UInt64?
    /// wp_fifo_v1 barrier flags applying to this commit. Per-commit.
    var fifoBarrier = false
    var fifoWaitBarrier = false
    /// wp_linux_drm_syncobj acquire/release points for this content commit.
    /// Per-commit: consumed by the buffer upload/frame execution path.
    var syncAcquire: SyncPoint?
    var syncRelease: SyncPoint?
}

/// The surface-adjacent protocol kinds a surface admits at most one of.
enum SurfaceAuxKind: Hashable {
    case viewport
    case fifo
    case commitTimer
    case tearingControl
    case fractionalScale
    case kdeBlur
    case backgroundEffect
    case syncobj
}

/// A double-buffered protocol object that owns its own pending state and latches
/// it when the surface's content commit applies (ext-background-effect blur
/// region, drm-syncobj acquire/release points). Held weakly — the object is owned
/// by its own wl_resource (Rule 9), never by the surface.
protocol WlSurfaceCommitObserver: AnyObject {
    func surfaceCommitApplied(_ surface: WlSurface)
}

/// A bound wp_fractional_scale_v1 that the surface pushes preferred-scale updates
/// to. Held weakly — the object is owned by its own wl_resource (Rule 9).
protocol PreferredScaleSink: AnyObject {
    func sendPreferredScale(_ scale120: UInt32)
}

/// What changed in one commit, handed to the scene delegate. Buffer is the
/// committed wl_buffer resource (nil = no content / detached).
struct SurfaceCommit: Sendable {
    let surfaceID: UInt32
    /// Monotonic identity of the attached content state. It changes for every
    /// applied attach (including detach), and is stable for this immutable commit.
    let bufferGeneration: UInt64
    let bufferResourceBits: UInt
    let bufferPixelSize: BufferPixelSize
    let logicalContentSize: SurfaceLogicalSize
    let bufferScale: Int32
    let bufferTransform: Int32
    let surfaceDamage: [WlRect]
    let bufferDamage: [WlRect]
    let opaqueRegion: RegionSnapshot?
    let inputRegion: RegionSnapshot?
    let isInitialCommit: Bool
    /// Surface-adjacent protocol state latched with this commit.
    let aux: SurfaceAuxState
}

/// The render/scene seam: the compositor notifies the window driver of each
/// surface commit/destroy, which drives the scene feeder. All calls happen on the
/// compositor turn.
protocol SurfaceSceneDelegate: AnyObject {
    func surfaceCommitted(_ commit: SurfaceCommit)
    func surfaceDestroyed(surfaceID: UInt32, iosurfaceID: UInt32)
}

/// A surface role attached to a wl_surface that drives a configure↔commit
/// handshake (xdg_surface, zwlr_layer_surface). The surface notifies its role at
/// each commit so the role can send its initial configure (first commit) or latch
/// an acked configure and map (later commits), and on destruction so the role
/// drops its surface back-link. The role is held weakly: it is owned by its own
/// wl_resource (Rule 9), never by the surface.
protocol WlSurfaceRole: AnyObject {
    func roleSurfaceCommit(_ surface: WlSurface, isInitial: Bool)
    func roleSurfaceDestroyed(_ surface: WlSurface)
}

/// One field's double-buffered update: `.unchanged` carries the committed value
/// forward; `.set` replaces it on the next commit (`.set(nil)` = explicit clear).
private enum Pending<T> {
    case unchanged
    case set(T?)
}

final class WlSurface {
    // Weak: a surface must not keep its compositor alive (Rule 9 — a surface is
    // owned only by its resource). This is also nil-safe at teardown, where the
    // display (and thus surface-resource destruction) outlives the compositor.
    weak let compositor: WlCompositor?
    let version: Int32
    /// The wl_surface resource. Set right after creation; nil after destruction.
    fileprivate(set) var resource: UnsafeMutablePointer<wl_resource>?

    // Pending (accumulating) state.
    private var pendingBufferAttached = false
    private var pendingBuffer: WaylandResourceReference?
    /// wl_surface v7 get_release: the release callback for the pending buffer (double-buffered).
    private var pendingReleaseCallback: UnsafeMutablePointer<wl_resource>?
    private var pendingOffsetX: Int32 = 0
    private var pendingOffsetY: Int32 = 0
    private var pendingSurfaceDamage: [WlRect] = []
    private var pendingBufferDamage: [WlRect] = []
    private var pendingFrameCallbacks: [UnsafeMutablePointer<wl_resource>] = []
    // wp_presentation_feedback objects (no requests; pure event carriers like
    // wl_callback) registered for this content update, fired on presentation.
    private var pendingPresentationFeedbacks: [UnsafeMutablePointer<wl_resource>] = []
    private var pendingBufferScale: Int32 = 1
    private var pendingBufferTransform: Int32 = 0
    private var pendingOpaque: Pending<RegionSnapshot> = .unchanged
    private var pendingInput: Pending<RegionSnapshot> = .unchanged

    // Current (committed) state.
    private var currentBufferReference: WaylandResourceReference?
    /// The live wire resource for the committed buffer. Clients may destroy a
    /// wl_buffer while its pixels remain current, so this is nil once the wire
    /// object is gone even though `hasCurrentBuffer` remains true.
    var currentBuffer: UnsafeMutablePointer<wl_resource>? { currentBufferReference?.resource }
    /// Whether the surface logically has attached content, independent of the
    /// lifetime of the client-side wl_buffer object used to supply those pixels.
    var hasCurrentBuffer: Bool { currentBufferReference != nil }
    /// The release callback bound to currentBuffer; fired when that buffer is released.
    private var currentReleaseCallback: UnsafeMutablePointer<wl_resource>?
    /// True after the current buffer was rejected before becoming renderer-owned.
    /// A later replacement or surface teardown must not emit a second release.
    private var currentBufferReleased = false
    private(set) var bufferScale: Int32 = 1
    private(set) var bufferTransform: Int32 = 0
    private(set) var opaqueRegion: RegionSnapshot?
    private(set) var inputRegion: RegionSnapshot?
    private(set) var offsetX: Int32 = 0
    private(set) var offsetY: Int32 = 0
    private(set) var committed = false

    /// This surface's committed content extent in surface-local logical pixels
    /// (buffer size / buffer scale). Published each commit by the router window
    /// driver; the router hit-test uses it as the surface's default input bounds
    /// when no `wl_surface.set_input_region` is present. 0 until first content.
    var committedLogicalWidth: Double = 0
    var committedLogicalHeight: Double = 0

    // MARK: render-state
    //
    // The surface owns its render *resource* identity: the IOSurface id, a
    // render-driver-allocated resource value it holds across commits (swapped-with-deferred-
    // release on the render-driver side per upload). The runtime render driver performs the
    // GPU upload on each commit and writes the resulting id back here, then
    // publishes it as the surface's backing-layer content through the scene feeder —
    // the author owns the surface→layer mapping, so the surface holds no layer ids.
    // Released via `RenderRuntime.releaseIOSurface` when the surface tears down.
    var renderIosurfaceId: UInt32 = 0
    /// Revision of the pixels stored under the stable IOSurface id. The id is
    /// intentionally reused across commits, so scene content must carry this
    /// changing value or the retained renderer will treat a new client buffer as
    /// unchanged and withhold both redraw and the next frame callback.
    private(set) var renderContentGeneration: UInt64 = 0
    private var committedBufferGeneration: UInt64 = 0

    func didImportContent(generation: UInt64) {
        renderContentGeneration = generation
    }

    /// Complete the release contract for committed content that has no outstanding
    /// GPU or KMS ownership: copied SHM pixels or a rejected import. Keep the
    /// committed protocol state intact until the client replaces/detaches it, while
    /// recording that its release transition has already occurred.
    func releaseCurrentBufferImmediately() {
        guard hasCurrentBuffer, !currentBufferReleased else { return }
        if let buffer = currentBuffer { wl_buffer_send_release(buffer) }
        if let callback = currentReleaseCallback {
            wl_callback_send_done(callback, 0)
            wl_resource_destroy(callback)
            currentReleaseCallback = nil
        }
        currentBufferReleased = true
    }

    // MARK: surface-adjacent protocol state (viewporter / tearing / timing / fifo)
    //
    // Double-buffered with content: requests write the pending* fields, which
    // latch into `aux` on commit (sticky fields carry forward, per-commit fields
    // reset). The protocol objects (WpViewport, WpTearingControl, WpCommitTimer,
    // WpFifo) own only their resource lifecycle; this surface owns the state.
    private var pendingViewportSource: WlFRect?
    private var pendingViewportSourceSet = false
    private var pendingViewportDestination: WlSize?
    private var pendingViewportDestinationSet = false
    private var pendingPresentationHint: UInt32 = 0
    private var pendingCommitTimestampNs: UInt64?
    private var pendingFifoBarrier = false
    private var pendingFifoWaitBarrier = false
    /// The surface-adjacent state latched at the last commit.
    private(set) var aux = SurfaceAuxState()
    func setSyncobjPoints(acquire: SyncPoint, release: SyncPoint) {
        aux.syncAcquire = acquire
        aux.syncRelease = release
    }

    /// At most one object of each surface-adjacent kind may attach to a surface;
    /// the factories raise the protocol's "<x>_exists" error otherwise.
    private var claimedAux: Set<SurfaceAuxKind> = []

    /// Double-buffered protocol objects notified when this surface's content
    /// commit applies (held weakly; dead boxes are compacted on iteration).
    private var commitObservers: [WeakCommitObserver] = []

    // MARK: fractional scale (wp_fractional_scale_v1) — output-affinity advice
    //
    // Not buffered: the preferred scale tracks output membership and is pushed to
    // the bound object whenever it changes. Held weakly (Rule 9).
    weak var fractionalScaleSink: PreferredScaleSink?
    /// Preferred fractional scale ×120 (120 = 1.0). Recomputed from the surface's
    /// entered-output set in `refreshPreferredScale`; defaults to 1.0.
    private(set) var preferredFractionalScale120: UInt32 = 120

    // MARK: output membership (wl_surface.enter / leave)
    //
    // The set of outputs this surface currently overlaps, in DisplayID space. The
    // presentation walk recomputes overlap each frame and pushes the set through a
    // router crossing; `updateEnteredOutputs` diffs it to emit enter/leave and to
    // drive the preferred buffer + fractional scale. libwayland owns the wire; this
    // owns the membership semantics (boundary plan: the router owns output affinity).
    private var enteredOutputs: Set<UInt64> = []
    /// The last preferred buffer scale advertised (v6+); `bind` sends the default.
    private var sentPreferredBufferScale: Int32 = 1

    /// True once the presentation walk has reported this surface's output set, so
    /// per-output routing (present/feedback/tearing) can prefer precise membership
    /// over the conservative role/window fallback.
    var hasKnownOutputMembership: Bool { !enteredOutputs.isEmpty }
    /// Whether this surface currently overlaps `outputID` (per the last reported set).
    func overlapsOutput(_ outputID: UInt64) -> Bool { enteredOutputs.contains(outputID) }

    // Frame callbacks committed but not yet completed (fire on the next present).
    private var frameCallbacksAwaitingPresent: [UnsafeMutablePointer<wl_resource>] = []
    /// Total frame callbacks completed over this surface's life (fixture probe).
    private(set) var completedFrameCallbacks = 0

    // Presentation feedbacks committed but not yet presented.
    private var presentationFeedbacksAwaitingPresent: [UnsafeMutablePointer<wl_resource>] = []

    // MARK: subsurface role / topology
    //
    // When this surface is a subsurface, `subsurfaceParent` is its parent and
    // `subsurfaceSync`/position carry its role state. When this surface is a
    // parent, `subStack` is its z-order stack — subsurface children plus a marker
    // for the parent's own content, so children can be stacked above OR below it.
    // Children are held weakly (Rule 9: a subsurface is owned by its wl_surface).

    weak var subsurfaceParent: WlSurface?
    private(set) var subsurfaceX: Int32 = 0
    private(set) var subsurfaceY: Int32 = 0
    /// The subsurface's own sync flag. Effective sync also inherits from ancestors.
    var subsurfaceSync = false
    /// Commit cached while effectively-sync; applied when the parent commits (or
    /// when the subsurface transitions to desync).
    private var cachedCommit: LatchedState?
    private var subStack: [SubStackEntry] = []

    /// This surface's wire object id (0 if the resource is gone). Identity probe.
    var objectId: UInt32 { resource.map { wl_resource_get_id($0) } ?? 0 }

    // MARK: role (xdg_surface / layer surface)
    //
    // A surface takes at most one such role; once taken it cannot change (xdg's
    // `role`/`already_constructed` invariants are enforced by the role factory).
    // The role is held weakly — it is owned by its own wl_resource.
    weak var role: WlSurfaceRole?
    private(set) var hasRole = false

    /// Attach a configure-driving role. Returns false if one is already attached
    /// (the caller raises the protocol's "already has a role" error).
    @discardableResult
    func assignRole(_ role: WlSurfaceRole) -> Bool {
        guard !hasRole else { return false }
        hasRole = true
        self.role = role
        return true
    }

    init(compositor: WlCompositor, version: Int32) {
        self.compositor = compositor
        self.version = version
    }

    fileprivate func bind(resource: UnsafeMutablePointer<wl_resource>) {
        self.resource = resource
        // Seed the v6 preferred scale before the surface enters an output. The
        // entered-output set recomputes and republishes the live per-output value.
        if version >= 6 {
            WlSurfaceServer.sendPreferredBufferScale(resource, factor: compositor?.preferredBufferScale ?? 1)
        }
    }

    // MARK: request application (called from the shared surface vtable)

    func attach(buffer: UnsafeMutablePointer<wl_resource>?, x: Int32, y: Int32) {
        pendingBufferAttached = true
        let dmabufOwner: DmabufBuffer? = buffer.flatMap {
            wl_shm_buffer_get($0) == nil
                ? WaylandResource.owner(of: $0, as: DmabufBuffer.self)
                : nil
        }
        pendingBuffer = WaylandResourceReference(buffer, retaining: dmabufOwner)
        // attach x/y is superseded by the offset request in v5+; record either way.
        pendingOffsetX = x
        pendingOffsetY = y
    }

    func addSurfaceDamage(_ r: WlRect) {
        guard r.width > 0, r.height > 0 else { return }
        pendingSurfaceDamage.append(r)
    }

    func addBufferDamage(_ r: WlRect) {
        guard r.width > 0, r.height > 0 else { return }
        pendingBufferDamage.append(r)
    }

    func addFrameCallback(_ callback: UnsafeMutablePointer<wl_resource>) {
        pendingFrameCallbacks.append(callback)
    }

    func addPresentationFeedback(_ feedback: UnsafeMutablePointer<wl_resource>) {
        pendingPresentationFeedbacks.append(feedback)
    }

    func setOpaqueRegion(_ snapshot: RegionSnapshot?) { pendingOpaque = .set(snapshot) }
    func setInputRegion(_ snapshot: RegionSnapshot?) { pendingInput = .set(snapshot) }
    func setBufferScale(_ scale: Int32) { pendingBufferScale = scale }
    func setBufferTransform(_ transform: Int32) { pendingBufferTransform = transform }
    func setOffset(x: Int32, y: Int32) { pendingOffsetX = x; pendingOffsetY = y }

    // MARK: surface-adjacent protocol setters (write pending; latched on commit)

    func setPendingViewportSource(_ rect: WlFRect?) {
        pendingViewportSource = rect
        pendingViewportSourceSet = true
    }
    func setPendingViewportDestination(_ size: WlSize?) {
        pendingViewportDestination = size
        pendingViewportDestinationSet = true
    }
    func setPendingPresentationHint(_ hint: UInt32) { pendingPresentationHint = hint }
    /// True if a commit timestamp is already pending (wp_commit_timer's
    /// `timestamp_exists` error fires when set_timestamp is called twice per commit).
    var hasPendingCommitTimestamp: Bool { pendingCommitTimestampNs != nil }
    func setPendingCommitTimestamp(_ ns: UInt64) { pendingCommitTimestampNs = ns }
    func markPendingFifoBarrier() { pendingFifoBarrier = true }
    func markPendingFifoWaitBarrier() { pendingFifoWaitBarrier = true }

    // MARK: one-per-surface aux claims

    func hasAux(_ kind: SurfaceAuxKind) -> Bool { claimedAux.contains(kind) }
    /// Claim a surface-adjacent slot; false if already taken (caller posts the error).
    @discardableResult func claimAux(_ kind: SurfaceAuxKind) -> Bool {
        guard !claimedAux.contains(kind) else { return false }
        claimedAux.insert(kind)
        return true
    }
    func releaseAux(_ kind: SurfaceAuxKind) { claimedAux.remove(kind) }

    /// Register a double-buffered protocol object to latch on this surface's commit.
    func addCommitObserver(_ observer: WlSurfaceCommitObserver) {
        commitObservers.append(WeakCommitObserver(observer))
    }

    /// Update the preferred fractional scale (×120) and push it to a bound
    /// wp_fractional_scale_v1, if any.
    func setPreferredFractionalScale(_ scale120: UInt32) {
        preferredFractionalScale120 = scale120
        fractionalScaleSink?.sendPreferredScale(scale120)
    }

    /// Apply the compositor-computed set of outputs this surface overlaps. Sends
    /// `wl_surface.enter` for newly-entered outputs and `wl_surface.leave` for
    /// departed ones (each referencing one of the surface client's bound wl_output
    /// resources), then recomputes preferred scale from the new membership. A no-op
    /// when the set is unchanged, so the presentation walk can call it every frame.
    func updateEnteredOutputs(_ ids: Set<UInt64>) {
        guard let resource, let compositor, ids != enteredOutputs else { return }
        let client = wl_resource_get_client(resource)
        for id in ids where !enteredOutputs.contains(id) {
            guard let output = compositor.output(id: id) else { continue }
            for outputRes in output.resources(forClient: client) {
                WlSurfaceServer.sendEnter(resource, output: outputRes)
            }
        }
        for id in enteredOutputs where !ids.contains(id) {
            guard let output = compositor.output(id: id) else { continue }
            for outputRes in output.resources(forClient: client) {
                WlSurfaceServer.sendLeave(resource, output: outputRes)
            }
        }
        enteredOutputs = ids
        refreshPreferredScale()
    }

    /// Recompute the preferred buffer + fractional scale as the max scale among the
    /// outputs the surface overlaps, and advertise it if it changed. With no live
    /// outputs the last advertised scale is kept (sending scale 0 is invalid).
    private func refreshPreferredScale() {
        guard let resource, let compositor else { return }
        var maxScale: Int32 = 0
        var maxFractionalScale = 0.0
        for id in enteredOutputs {
            if let output = compositor.output(id: id) {
                maxScale = max(maxScale, output.info.scale)
                maxFractionalScale = max(maxFractionalScale, output.info.fractionalScale)
            }
        }
        guard maxScale > 0 else { return }
        if version >= 6, maxScale != sentPreferredBufferScale {
            WlSurfaceServer.sendPreferredBufferScale(resource, factor: maxScale)
            sentPreferredBufferScale = maxScale
        }
        let resolvedFractionalScale = maxFractionalScale > 0 ? maxFractionalScale : Double(maxScale)
        let frac120 = UInt32(max(1.0, (resolvedFractionalScale * 120.0).rounded()))
        if frac120 != preferredFractionalScale120 { setPreferredFractionalScale(frac120) }
    }

    /// All double-buffered state captured at one commit. Held as `cachedCommit`
    /// while effectively-sync, applied to current state when the parent commits.
    private struct LatchedState {
        var bufferAttached: Bool
        var buffer: WaylandResourceReference?
        var releaseCallback: UnsafeMutablePointer<wl_resource>?
        var offsetX: Int32
        var offsetY: Int32
        var bufferScale: Int32
        var bufferTransform: Int32
        var opaque: Pending<RegionSnapshot>
        var input: Pending<RegionSnapshot>
        var surfaceDamage: [WlRect]
        var bufferDamage: [WlRect]
        var frameCallbacks: [UnsafeMutablePointer<wl_resource>]
        var presentationFeedbacks: [UnsafeMutablePointer<wl_resource>]
        var isInitial: Bool
        // Surface-adjacent protocol state captured at this commit.
        var auxViewportSource: WlFRect?
        var auxViewportSourceSet: Bool
        var auxViewportDestination: WlSize?
        var auxViewportDestinationSet: Bool
        var auxPresentationHint: UInt32
        var auxCommitTimestampNs: UInt64?
        var auxFifoBarrier: Bool
        var auxFifoWaitBarrier: Bool
    }

    /// Capture pending state into a latch and reset pending. In sync mode the
    /// latch is cached for the parent commit; otherwise it applies immediately.
    func commit() {
        let isInitial = !committed
        committed = true
        let latch = LatchedState(
            bufferAttached: pendingBufferAttached, buffer: pendingBuffer,
            releaseCallback: pendingReleaseCallback,
            offsetX: pendingOffsetX, offsetY: pendingOffsetY,
            bufferScale: pendingBufferScale, bufferTransform: pendingBufferTransform,
            opaque: pendingOpaque, input: pendingInput,
            surfaceDamage: pendingSurfaceDamage, bufferDamage: pendingBufferDamage,
            frameCallbacks: pendingFrameCallbacks,
            presentationFeedbacks: pendingPresentationFeedbacks, isInitial: isInitial,
            auxViewportSource: pendingViewportSource,
            auxViewportSourceSet: pendingViewportSourceSet,
            auxViewportDestination: pendingViewportDestination,
            auxViewportDestinationSet: pendingViewportDestinationSet,
            auxPresentationHint: pendingPresentationHint,
            auxCommitTimestampNs: pendingCommitTimestampNs,
            auxFifoBarrier: pendingFifoBarrier,
            auxFifoWaitBarrier: pendingFifoWaitBarrier
        )
        pendingBufferAttached = false
        pendingBuffer = nil
        pendingReleaseCallback = nil
        pendingOpaque = .unchanged
        pendingInput = .unchanged
        pendingSurfaceDamage = []
        pendingBufferDamage = []
        pendingFrameCallbacks = []
        pendingPresentationFeedbacks = []
        // Sticky aux values (viewport, hint) carry forward; only their set-flags
        // and the per-commit aux fields reset.
        pendingViewportSourceSet = false
        pendingViewportDestinationSet = false
        pendingCommitTimestampNs = nil
        pendingFifoBarrier = false
        pendingFifoWaitBarrier = false

        if isEffectivelySync {
            var next = latch
            // A superseded cached commit is dropped: release its never-applied new
            // buffer, and roll its frame callbacks into the new latch so none leak.
            if let prev = cachedCommit {
                if prev.bufferAttached, let b = prev.buffer?.resource {
                    wl_buffer_send_release(b)
                    if let cb = prev.releaseCallback { wl_callback_send_done(cb, 0); wl_resource_destroy(cb) }
                }
                next.frameCallbacks = prev.frameCallbacks + next.frameCallbacks
                // A superseded content update is never presented: discard its feedbacks.
                for fb in prev.presentationFeedbacks {
                    wp_presentation_feedback_send_discarded(fb)
                    wl_resource_destroy(fb)
                }
            }
            cachedCommit = next
        } else {
            applyLatch(latch)
        }

        // Drive the surface role's configure↔commit handshake. On the first commit
        // (an xdg/layer surface commits bufferless to elicit its initial configure)
        // the role sends that configure; later commits latch the acked configure and
        // map. Roots are never effectively-sync, so the role observes applied state.
        role?.roleSurfaceCommit(self, isInitial: isInitial)
    }

    /// Apply a latched commit to current state, snapshot it to the scene, then —
    /// per parent-commit semantics — apply the cached commits of sync children.
    private func applyLatch(_ latch: LatchedState) {
        if latch.bufferAttached {
            committedBufferGeneration &+= 1
            if committedBufferGeneration == 0 { committedBufferGeneration = 1 }
            let oldReference = currentBufferReference
            let old = oldReference?.resource
            let new = latch.buffer?.resource
            let oldWasReleased = currentBufferReleased
            currentBufferReference = latch.buffer
            // A replaced buffer is no longer referenced; release it for client reuse.
            let replaced = oldReference != nil && (latch.buffer == nil || old == nil || old != new)
            if replaced && !oldWasReleased {
                if let oldReference,
                   oldReference.semanticOwner is DmabufBuffer,
                   renderIosurfaceId != 0 {
                    // The imported VkImage aliases client memory. Renderer retirement,
                    // not the next commit, determines when reuse is legal.
                    compositor?.deferBufferRelease(
                        iosurfaceID: renderIosurfaceId, buffer: oldReference,
                        callback: currentReleaseCallback)
                } else {
                    // SHM pixels were copied during commit and can be released now.
                    if let old { wl_buffer_send_release(old) }
                    if let cb = currentReleaseCallback {
                        wl_callback_send_done(cb, 0)
                        wl_resource_destroy(cb)
                    }
                }
            }
            currentReleaseCallback = latch.releaseCallback
            currentBufferReleased = false
            offsetX = latch.offsetX
            offsetY = latch.offsetY
        }
        bufferScale = latch.bufferScale
        bufferTransform = latch.bufferTransform
        if case .set(let s) = latch.opaque { opaqueRegion = s }
        if case .set(let s) = latch.input { inputRegion = s }
        frameCallbacksAwaitingPresent.append(contentsOf: latch.frameCallbacks)
        presentationFeedbacksAwaitingPresent.append(contentsOf: latch.presentationFeedbacks)

        // Latch surface-adjacent state: sticky fields update only when set this
        // commit; per-commit fields take the commit's value (defaulting to clear).
        if latch.auxViewportSourceSet { aux.viewportSource = latch.auxViewportSource }
        if latch.auxViewportDestinationSet { aux.viewportDestination = latch.auxViewportDestination }
        aux.presentationHint = latch.auxPresentationHint
        aux.commitTimestampNs = latch.auxCommitTimestampNs
        aux.fifoBarrier = latch.auxFifoBarrier
        aux.fifoWaitBarrier = latch.auxFifoWaitBarrier
        aux.syncAcquire = nil
        aux.syncRelease = nil

        // Double-buffered protocol objects latch with the content commit before
        // the scene delegate observes it, so upload/presentation sees the same
        // adjacent state the commit validated.
        if !commitObservers.isEmpty {
            commitObservers.removeAll { $0.observer == nil }
            for box in commitObservers { box.observer?.surfaceCommitApplied(self) }
        }

        let pixels = committedBufferPixelSize()
        let logical = resolveSurfaceLogicalSize(
            pixels: pixels, bufferScale: bufferScale,
            bufferTransform: bufferTransform,
            viewportDestination: aux.viewportDestination)
        let info = SurfaceCommit(
            surfaceID: objectId,
            bufferGeneration: committedBufferGeneration,
            bufferResourceBits: UInt(bitPattern: currentBuffer),
            bufferPixelSize: pixels,
            logicalContentSize: logical,
            bufferScale: bufferScale, bufferTransform: bufferTransform,
            surfaceDamage: latch.surfaceDamage, bufferDamage: latch.bufferDamage,
            opaqueRegion: opaqueRegion, inputRegion: inputRegion, isInitialCommit: latch.isInitial,
            aux: aux
        )
        compositor?.sceneDelegate?.surfaceCommitted(info)

        for child in subsurfaceChildren where child.isEffectivelySync {
            if let cached = child.cachedCommit {
                child.cachedCommit = nil
                child.applyLatch(cached)
            }
        }
    }

    private func committedBufferPixelSize() -> BufferPixelSize {
        guard let buffer = currentBuffer else { return BufferPixelSize() }
        if let shm = wl_shm_buffer_get(buffer) {
            return BufferPixelSize(
                width: UInt32(max(0, wl_shm_buffer_get_width(shm))),
                height: UInt32(max(0, wl_shm_buffer_get_height(shm))))
        }
        if let dmabuf = WaylandResource.owner(of: buffer, as: DmabufBuffer.self) {
            return BufferPixelSize(
                width: UInt32(max(0, dmabuf.attrs.width)),
                height: UInt32(max(0, dmabuf.attrs.height)))
        }
        return BufferPixelSize()
    }

    /// Complete all frame callbacks accumulated since the last present, sending
    /// wl_callback.done(timeMs) and destroying each callback resource. Driven by
    /// the presentation path; in #8 fixtures the test triggers it directly.
    func present(timeMs: UInt32) {
        let callbacks = frameCallbacksAwaitingPresent
        frameCallbacksAwaitingPresent.removeAll(keepingCapacity: true)
        for cb in callbacks {
            wl_callback_send_done(cb, timeMs)
            wl_resource_destroy(cb)
            completedFrameCallbacks += 1
        }
    }

    /// Deliver wp_presentation_feedback.presented to every feedback committed since
    /// the last presentation, then destroy each (presented is a destructor event).
    /// Timestamp is in the presentation clock; refresh is ns to the next vblank;
    /// seq is the output MSC; flags is wp_presentation_feedback.kind. The render
    /// path drives this at #12; the fixture calls it directly.
    func presentFeedback(
        tvSecHi: UInt32, tvSecLo: UInt32, tvNsec: UInt32,
        refreshNs: UInt32, seqHi: UInt32, seqLo: UInt32, flags: UInt32
    ) {
        let feedbacks = presentationFeedbacksAwaitingPresent
        presentationFeedbacksAwaitingPresent.removeAll(keepingCapacity: true)
        for fb in feedbacks {
            wp_presentation_feedback_send_presented(
                fb, tvSecHi, tvSecLo, tvNsec, refreshNs, seqHi, seqLo, flags)
            wl_resource_destroy(fb)
        }
    }

    deinit {
        // Outstanding frame callbacks never presented: destroy their resources so
        // they don't dangle. (Their wl_resources belong to the client and would
        // otherwise be cleaned up only at client teardown.)
        for cb in frameCallbacksAwaitingPresent { wl_resource_destroy(cb) }
        for cb in pendingFrameCallbacks { wl_resource_destroy(cb) }
        if let latch = cachedCommit { for cb in latch.frameCallbacks { wl_resource_destroy(cb) } }
        // Presentation feedbacks for never-presented content are discarded.
        for fb in presentationFeedbacksAwaitingPresent {
            wp_presentation_feedback_send_discarded(fb)
            wl_resource_destroy(fb)
        }
        for fb in pendingPresentationFeedbacks {
            wp_presentation_feedback_send_discarded(fb)
            wl_resource_destroy(fb)
        }
        if let latch = cachedCommit {
            for fb in latch.presentationFeedbacks {
                wp_presentation_feedback_send_discarded(fb)
                wl_resource_destroy(fb)
            }
        }
        // Retire the current buffer under the same GPU-lifetime contract as a
        // replacement. The compositor outlives this surface and owns the deferred
        // queue, so a destroyed wl_surface cannot orphan its wl_buffer release.
        if !currentBufferReleased,
           let currentBufferReference,
           currentBufferReference.semanticOwner is DmabufBuffer,
           renderIosurfaceId != 0 {
            compositor?.deferBufferRelease(
                iosurfaceID: renderIosurfaceId, buffer: currentBufferReference,
                callback: currentReleaseCallback)
        } else {
            if let cb = currentReleaseCallback {
                wl_callback_send_done(cb, 0)
                wl_resource_destroy(cb)
            }
        }
        if let cb = pendingReleaseCallback { wl_resource_destroy(cb) }
        if let latch = cachedCommit, let cb = latch.releaseCallback { wl_resource_destroy(cb) }
        role?.roleSurfaceDestroyed(self)
        detachFromParent()
        compositor?.removeSurface(self)
        compositor?.sceneDelegate?.surfaceDestroyed(
            surfaceID: objectId, iosurfaceID: renderIosurfaceId)
    }
}

// MARK: - WlSurfaceRequests conformance
//
// The request vtable + trampolines now live in swift-wayland's WaylandServerDispatch. WlSurface
// (attach/commit/setBufferScale/setBufferTransform already match the request names) conforms; the
// remaining requests forward to the model. Region resolution stays here — it is compositor policy.
extension WlSurface: WlSurfaceRequests {
    func attach(_ resource: UnsafeMutablePointer<wl_resource>, buffer: UnsafeMutablePointer<wl_resource>?, x: Int32, y: Int32) {
        attach(buffer: buffer, x: x, y: y)
    }
    func damage(_ resource: UnsafeMutablePointer<wl_resource>, x: Int32, y: Int32, width: Int32, height: Int32) {
        addSurfaceDamage(WlRect(x: x, y: y, width: width, height: height))
    }
    func damageBuffer(_ resource: UnsafeMutablePointer<wl_resource>, x: Int32, y: Int32, width: Int32, height: Int32) {
        addBufferDamage(WlRect(x: x, y: y, width: width, height: height))
    }
    func frame(_ resource: UnsafeMutablePointer<wl_resource>, callback: WlNewId) {
        guard let cb = callback.createBare() else { return }
        addFrameCallback(cb)
    }
    func setOpaqueRegion(_ resource: UnsafeMutablePointer<wl_resource>, region: UnsafeMutablePointer<wl_resource>?) {
        setOpaqueRegion(Self.regionSnapshot(region))
    }
    func setInputRegion(_ resource: UnsafeMutablePointer<wl_resource>, region: UnsafeMutablePointer<wl_resource>?) {
        setInputRegion(Self.regionSnapshot(region))
    }
    func commit(_ resource: UnsafeMutablePointer<wl_resource>) { commit() }
    func offset(_ resource: UnsafeMutablePointer<wl_resource>, x: Int32, y: Int32) { setOffset(x: x, y: y) }
    func getRelease(_ resource: UnsafeMutablePointer<wl_resource>, callback: WlNewId) {
        // Requires a non-null buffer attached this content update (protocol: no_buffer = 5). On the
        // error path the callback is simply never created — the protocol error disconnects the client.
        guard pendingBufferAttached, pendingBuffer != nil else {
            swift_wayland_resource_post_error(resource, 5, "get_release without an attached buffer")
            return
        }
        if let stale = pendingReleaseCallback { wl_resource_destroy(stale) }
        pendingReleaseCallback = callback.createBare()
    }
    func setBufferScale(_ resource: UnsafeMutablePointer<wl_resource>, scale: Int32) { setBufferScale(scale) }
    func setBufferTransform(_ resource: UnsafeMutablePointer<wl_resource>, transform: Int32) { setBufferTransform(transform) }

    private static func regionSnapshot(_ res: UnsafeMutablePointer<wl_resource>?) -> RegionSnapshot? {
        guard let res, let r = WaylandResource.owner(of: res, as: WlRegion.self) else { return nil }
        return r.snapshot()
    }
}

extension WlCompositor {
    /// Create a wl_surface resource bound to a new WlSurface owner.
    func makeSurface(
        client: OpaquePointer, id: UInt32, version: Int32
    ) -> UnsafeMutablePointer<wl_resource>? {
        let surface = WlSurface(compositor: self, version: version)
        guard let resource = WaylandResource.create(
            client: client, interface: swift_wayland_iface_wl_surface(),
            version: version, id: id, vtable: WlSurfaceServer.vtable, owner: surface
        ) else { return nil }
        surface.bind(resource: resource)
        registerSurface(surface)
        return resource
    }
}

// MARK: - subsurface topology

/// Weak reference to a surface, for parent→child links (Rule 9: a surface is
/// owned only by its resource, never by its parent).
final class WeakSurfaceBox {
    weak var surface: WlSurface?
    init(_ surface: WlSurface) { self.surface = surface }
}

/// Weak box for the surface's commit-observer list (Rule 9).
private final class WeakCommitObserver {
    weak var observer: WlSurfaceCommitObserver?
    init(_ observer: WlSurfaceCommitObserver) { self.observer = observer }
}

/// One slot in a parent's z-order: a subsurface child, or the marker for the
/// parent's own content (so children can stack above or below the parent).
enum SubStackEntry {
    case selfContent
    case child(WeakSurfaceBox)
}

extension WlSurface {
    /// A subsurface is effectively synchronized if its own flag is set or any
    /// ancestor is. A non-subsurface (root) is never sync — its commits apply now.
    var isEffectivelySync: Bool {
        guard let parent = subsurfaceParent else { return false }
        return subsurfaceSync || parent.isEffectivelySync
    }

    /// Live subsurface children in bottom-to-top z-order.
    var subsurfaceChildren: [WlSurface] {
        subStack.compactMap { if case .child(let box) = $0 { return box.surface } else { return nil } }
    }

    /// The full stack as object ids — parent's own content included — bottom to
    /// top. Identity probe for fixtures.
    var subsurfaceOrder: [UInt32] {
        subStack.compactMap {
            switch $0 {
            case .selfContent: return objectId
            case .child(let box): return box.surface?.objectId
            }
        }
    }

    func attachAsSubsurface(to parent: WlSurface) {
        subsurfaceParent = parent
        subsurfaceSync = true  // subsurfaces start synchronized
        parent.addChildOnTop(self)
    }

    func detachFromParent() {
        subsurfaceParent?.removeChild(self)
        subsurfaceParent = nil
    }

    fileprivate func addChildOnTop(_ child: WlSurface) {
        if subStack.isEmpty { subStack = [.selfContent] }
        subStack.append(.child(WeakSurfaceBox(child)))
    }

    fileprivate func removeChild(_ child: WlSurface) {
        subStack.removeAll {
            if case .child(let box) = $0 { return box.surface == nil || box.surface === child }
            return false
        }
    }

    func setSubsurfacePosition(x: Int32, y: Int32) {
        subsurfaceX = x
        subsurfaceY = y
    }

    func setSubsurfaceSync(_ sync: Bool) {
        let wasSync = isEffectivelySync
        subsurfaceSync = sync
        // sync → desync with a commit cached while sync: apply it immediately.
        if wasSync, !isEffectivelySync, let cached = cachedCommit {
            cachedCommit = nil
            applyLatch(cached)
        }
    }

    enum PlaceDir { case above, below }

    /// Move `child` directly above/below `sibling` in this parent's stack;
    /// `sibling === self` targets the parent's own content marker.
    func placeChild(_ child: WlSurface, relativeTo sibling: WlSurface, _ dir: PlaceDir) {
        guard child !== sibling, let from = childIndex(child) else { return }
        let entry = subStack.remove(at: from)
        let target = (sibling === self) ? selfContentIndex() : childIndex(sibling)
        guard let sibIdx = target else {
            subStack.append(entry)  // sibling gone: leave child on top
            return
        }
        let insertAt = (dir == .above) ? sibIdx + 1 : sibIdx
        subStack.insert(entry, at: min(max(insertAt, 0), subStack.count))
    }

    private func childIndex(_ child: WlSurface) -> Int? {
        subStack.firstIndex {
            if case .child(let box) = $0 { return box.surface === child }
            return false
        }
    }

    private func selfContentIndex() -> Int? {
        subStack.firstIndex { if case .selfContent = $0 { return true }; return false }
    }
}
