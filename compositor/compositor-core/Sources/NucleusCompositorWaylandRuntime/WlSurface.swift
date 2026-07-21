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
// The scene delegate is the seam to the live retained scene author. It receives
// immutable commits and drives surface attach, content, layout, and damage.

import WaylandServerC
import WaylandServer
import WaylandServerDispatch
import NucleusTypes

final class WlSurface {
    // Weak: a surface must not keep its compositor alive (Rule 9 — a surface is
    // owned only by its resource). This is also nil-safe at teardown, where the
    // display (and thus surface-resource destruction) outlives the compositor.
    weak let compositor: WlCompositor?
    let version: Int32
    /// Process-unique compositor identity. Wayland object ids are scoped to one
    /// client and routinely collide across clients, so they cannot key focus,
    /// scene, input, or drag state.
    private let stableObjectId: UInt32
    /// The wl_surface resource. Set right after creation; nil after destruction.
    fileprivate(set) var resource: UnsafeMutablePointer<wl_resource>?

    private var pending = SurfacePendingState()
    private var current = SurfaceCurrentState()

    /// The live wire resource for the committed buffer. Clients may destroy a
    /// wl_buffer while its pixels remain current, so this is nil once the wire
    /// object is gone even though `hasCurrentBuffer` remains true.
    var currentBuffer: UnsafeMutablePointer<wl_resource>? {
        current.buffer?.resource
    }
    /// Whether the surface logically has attached content, independent of the
    /// lifetime of the client-side wl_buffer object used to supply those pixels.
    var hasCurrentBuffer: Bool { current.buffer != nil }
    private var currentBufferReference:
        WaylandResourceReference?
    {
        get { current.buffer }
        set { current.buffer = newValue }
    }
    private var currentReleaseCallback:
        UnsafeMutablePointer<wl_resource>?
    {
        get { current.releaseCallback }
        set { current.releaseCallback = newValue }
    }
    private var currentBufferReleased: Bool {
        get { current.bufferReleased }
        set { current.bufferReleased = newValue }
    }
    private(set) var bufferScale: Int32 {
        get { current.bufferScale }
        set { current.bufferScale = newValue }
    }
    private(set) var bufferTransform: Int32 {
        get { current.bufferTransform }
        set { current.bufferTransform = newValue }
    }
    private(set) var opaqueRegion: RegionSnapshot? {
        get { current.opaqueRegion }
        set { current.opaqueRegion = newValue }
    }
    private(set) var inputRegion: RegionSnapshot? {
        get { current.inputRegion }
        set { current.inputRegion = newValue }
    }
    private(set) var offsetX: Int32 {
        get { current.offsetX }
        set { current.offsetX = newValue }
    }
    private(set) var offsetY: Int32 {
        get { current.offsetY }
        set { current.offsetY = newValue }
    }
    private(set) var committed: Bool {
        get { current.committed }
        set { current.committed = newValue }
    }

    /// This surface's committed content extent in surface-local logical pixels
    /// (buffer size / buffer scale). Published each commit by the router window
    /// driver; the router hit-test uses it as the surface's default input bounds
    /// when no `wl_surface.set_input_region` is present. 0 until first content.
    var committedLogicalWidth: Double {
        get { current.logicalWidth }
        set { current.logicalWidth = newValue }
    }
    var committedLogicalHeight: Double {
        get { current.logicalHeight }
        set { current.logicalHeight = newValue }
    }

    // MARK: render-state
    //
    // The surface owns its render *resource* identity: the IOSurface id, a
    // render-driver-allocated resource value it holds across commits (swapped-with-deferred-
    // release on the render-driver side per upload). The runtime render driver performs the
    // GPU upload on each commit and writes the resulting id back here, then
    // publishes it as the surface's backing-layer content through the scene feeder —
    // the author owns the surface→layer mapping, so the surface holds no layer ids.
    // Released through `CompositorRenderService` when the surface tears down.
    var renderIosurfaceId: UInt32 {
        get { current.renderIOSurfaceID }
        set {
            let oldValue = current.renderIOSurfaceID
            guard oldValue != newValue else { return }
            current.renderIOSurfaceID = newValue
            compositor?.surfaceRenderIdentityChanged(
                self, from: oldValue)
        }
    }
    /// Revision of the pixels stored under the stable IOSurface id. The id is
    /// intentionally reused across commits, so scene content must carry this
    /// changing value or the retained renderer will treat a new client buffer as
    /// unchanged and withhold both redraw and the next frame callback.
    private(set) var renderContentGeneration: UInt64 {
        get { current.renderContentGeneration }
        set { current.renderContentGeneration = newValue }
    }
    private var committedBufferGeneration: UInt64 {
        get { current.bufferGeneration }
        set { current.bufferGeneration = newValue }
    }

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

    // MARK: surface-adjacent protocol state
    //
    // Double-buffered with content: requests write the pending* fields, which
    // latch into `aux` on commit. Protocol objects own only their resource
    // lifecycle; this surface owns the state.
    weak var viewport: WpViewport?
    /// The surface-adjacent state latched at the last commit.
    private(set) var aux: SurfaceAuxState {
        get { current.auxiliary }
        set { current.auxiliary = newValue }
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
    var enteredOutputIDs: Set<UInt64> { enteredOutputs }

    private let presentation = SurfacePresentationState()
    private var nextCommitID: UInt64 = 1
    var currentCommitID: UInt64 { presentation.currentCommitID }
    var completedFrameCallbacks: Int {
        presentation.completedFrameCallbacks
    }

    let subsurfaceTopology = SubsurfaceTopology()

    var objectId: UInt32 {
        stableObjectId != 0
            ? stableObjectId
            : resource.map { wl_resource_get_id($0) } ?? 0
    }

    /// The client-scoped protocol object id. Use only for wire diagnostics;
    /// compositor state must use `objectId`.
    var wireObjectId: UInt32 {
        resource.map { wl_resource_get_id($0) } ?? 0
    }

    // MARK: role (xdg_surface / layer surface)
    //
    // A surface takes at most one such role; once taken it cannot change (xdg's
    // `role`/`already_constructed` invariants are enforced by the role factory).
    // The role is held weakly — it is owned by its own wl_resource.
    weak var role: WlSurfaceRole?
    private(set) var roleIdentity: SurfaceRoleIdentity?
    private var hasXdgConstructionClaim = false
    var hasRole: Bool { roleIdentity != nil }

    /// Attach a configure-driving role. Returns false if one is already attached
    /// (the caller raises the protocol's "already has a role" error).
    @discardableResult
    func assignRole(_ role: WlSurfaceRole) -> Bool {
        let identity: SurfaceRoleIdentity
        switch role {
        case is XdgSurface: identity = .xdg
        case is ZwlrLayerSurface: identity = .layerShell
        case is ExtSessionLockSurface: identity = .sessionLock
        case is XwaylandSurfaceRole: identity = .xwayland
        default: return false
        }
        guard roleIdentity == nil else { return false }
        roleIdentity = identity
        self.role = role
        return true
    }

    func claimSubsurfaceRole() -> Bool {
        guard roleIdentity == nil else { return false }
        roleIdentity = .subsurface
        return true
    }

    /// `wl_pointer.set_cursor` gives a surface the permanent cursor role. Reusing
    /// the same surface as a cursor is valid; assigning any other role is not.
    func claimCursorRole() -> Bool {
        if roleIdentity == .cursor { return true }
        guard roleIdentity == nil else { return false }
        roleIdentity = .cursor
        return true
    }

    func claimDragIconRole() -> Bool {
        if roleIdentity == .dragIcon { return true }
        guard roleIdentity == nil else { return false }
        roleIdentity = .dragIcon
        return true
    }

    func releaseSubsurfaceRole() {
        guard roleIdentity == .subsurface else { return }
        roleIdentity = nil
    }

    func claimXdgConstruction() -> Bool {
        guard !hasXdgConstructionClaim, roleIdentity == nil,
            !hasCurrentBuffer, !committed
        else { return false }
        hasXdgConstructionClaim = true
        return true
    }

    func releaseXdgConstruction() {
        hasXdgConstructionClaim = false
        if roleIdentity == nil { role = nil }
    }

    func bindXdgConstructionRole(_ role: XdgSurface) {
        guard hasXdgConstructionClaim, roleIdentity == nil else { return }
        self.role = role
    }

    init(
        compositor: WlCompositor,
        version: Int32,
        stableObjectId: UInt32 = 0
    ) {
        self.compositor = compositor
        self.version = version
        self.stableObjectId = stableObjectId
    }

    func bind(resource: UnsafeMutablePointer<wl_resource>) {
        self.resource = resource
        // Seed the v6 preferred scale before the surface enters an output. The
        // entered-output set recomputes and republishes the live per-output value.
        if version >= 6 {
            WlSurfaceServer.sendPreferredBufferScale(resource, factor: compositor?.preferredBufferScale ?? 1)
        }
    }

    // MARK: request application (called from the shared surface vtable)

    func attach(buffer: UnsafeMutablePointer<wl_resource>?, x: Int32, y: Int32) {
        pending.bufferAttached = true
        let dmabufOwner: DmabufBuffer? = buffer.flatMap {
            wl_shm_buffer_get($0) == nil
                ? WaylandResource.owner(of: $0, as: DmabufBuffer.self)
                : nil
        }
        pending.buffer = WaylandResourceReference(buffer, retaining: dmabufOwner)
        // attach x/y is superseded by the offset request in v5+; record either way.
        pending.offsetX = x
        pending.offsetY = y
    }

    func addSurfaceDamage(_ r: WlRect) {
        guard Self.hasSafeExtent(r) else { return }
        pending.surfaceDamage.append(r)
    }

    func addBufferDamage(_ r: WlRect) {
        guard Self.hasSafeExtent(r) else { return }
        pending.bufferDamage.append(r)
    }

    private static func hasSafeExtent(_ rect: WlRect) -> Bool {
        guard rect.width > 0, rect.height > 0 else { return false }
        return !rect.x.addingReportingOverflow(rect.width).overflow
            && !rect.y.addingReportingOverflow(rect.height).overflow
    }

    func addFrameCallback(_ callback: UnsafeMutablePointer<wl_resource>) {
        pending.frameCallbacks.append(callback)
    }

    func addPresentationFeedback(_ feedback: UnsafeMutablePointer<wl_resource>) {
        pending.presentationFeedbacks.append(feedback)
    }

    func setOpaqueRegion(_ snapshot: RegionSnapshot?) { pending.opaque = .set(snapshot) }
    func setInputRegion(_ snapshot: RegionSnapshot?) { pending.input = .set(snapshot) }
    func setBufferScale(_ scale: Int32) { pending.bufferScale = scale }
    func setBufferTransform(_ transform: Int32) { pending.bufferTransform = transform }
    func setOffset(x: Int32, y: Int32) {
        pending.offsetX = x
        pending.offsetY = y
    }

    func installPendingReleaseCallback(
        _ callback: WlNewId,
        postingErrorsTo resource: UnsafeMutablePointer<wl_resource>
    ) {
        guard pending.bufferAttached, pending.buffer != nil else {
            swift_wayland_resource_post_error(
                resource, 5, "get_release without an attached buffer")
            return
        }
        if let stale = pending.releaseCallback {
            wl_resource_destroy(stale)
        }
        pending.releaseCallback = callback.createBare()
    }

    // MARK: surface-adjacent protocol setters (write pending; latched on commit)

    func setPendingViewportSource(_ rect: WlFRect?) {
        pending.viewportSource = rect
        pending.viewportSourceSet = true
    }
    func setPendingViewportDestination(_ size: WlSize?) {
        pending.viewportDestination = size
        pending.viewportDestinationSet = true
    }
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

    func removeCommitObserver(_ observer: WlSurfaceCommitObserver) {
        commitObservers.removeAll {
            $0.observer == nil || $0.observer === observer
        }
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

    func removeEnteredOutput(_ outputID: UInt64) {
        guard enteredOutputs.contains(outputID) else { return }
        var remaining = enteredOutputs
        remaining.remove(outputID)
        updateEnteredOutputs(remaining)
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

    /// Capture pending state into a latch and reset pending. In sync mode the
    /// latch is cached for the parent commit; otherwise it applies immediately.
    @discardableResult
    func commit() -> UInt64 {
        let isInitial = !committed
        committed = true
        let commitID = nextCommitID
        nextCommitID &+= 1
        if nextCommitID == 0 { nextCommitID = 1 }
        let attachedBufferIsNonNull = pending.bufferAttached
            && pending.buffer?.resource != nil
        let attachedBufferSupportsExplicitSync =
            attachedBufferIsNonNull
            && pending.buffer?.semanticOwner is DmabufBuffer
        var capturedAux = SurfaceAuxState()
        var effects: [() -> Void] = []
        var observerStateValid = true
        if !commitObservers.isEmpty {
            commitObservers.removeAll { $0.observer == nil }
            for box in commitObservers {
                guard let observer = box.observer else { continue }
                if !observer.captureSurfaceCommit(
                    self,
                    bufferAttached: pending.bufferAttached,
                    attachedBufferIsNonNull: attachedBufferIsNonNull,
                    attachedBufferSupportsExplicitSync:
                        attachedBufferSupportsExplicitSync,
                    aux: &capturedAux,
                    effects: &effects)
                {
                    observerStateValid = false
                }
            }
        }
        let latch = pending.capture(
            commitID: commitID,
            isInitial: isInitial,
            syncAcquire: capturedAux.syncAcquire,
            syncRelease: capturedAux.syncRelease,
            effects: effects
        )

        guard observerStateValid else {
            discardUnapplied(latch)
            return commitID
        }

        if isEffectivelySync {
            var next = latch
            // A superseded cached commit is dropped: release its never-applied new
            // buffer, and roll its frame callbacks into the new latch so none leak.
            if let prev = subsurfaceTopology.cachedCommit {
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
            subsurfaceTopology.cachedCommit = next
        } else {
            applyLatch(latch)
        }
        return commitID
    }

    /// Apply a latched commit to current state, snapshot it to the scene, then —
    /// per parent-commit semantics — apply the cached commits of sync children.
    private func applyLatch(_ latch: SurfaceTransaction) {
        guard validateViewport(latch) else {
            discardUnapplied(latch)
            return
        }
        let willHaveBuffer = latch.bufferAttached
            ? latch.buffer?.resource != nil
            : hasCurrentBuffer
        let roleBufferPixelSize = latch.bufferAttached
            ? bufferPixelSize(latch.buffer?.resource)
            : committedBufferPixelSize()
        guard role?.validateSurfaceCommit(
            self,
            context: SurfaceRoleCommitContext(
                bufferAttached: latch.bufferAttached,
                willHaveBuffer: willHaveBuffer,
                bufferPixelSize: roleBufferPixelSize,
                bufferScale: latch.bufferScale)) ?? true
        else {
            discardUnapplied(latch)
            return
        }
        if latch.bufferAttached {
            committedBufferGeneration &+= 1
            if committedBufferGeneration == 0 { committedBufferGeneration = 1 }
            let oldReference = currentBufferReference
            let old = oldReference?.resource
            let new = latch.buffer?.resource
            let oldWasReleased = currentBufferReleased
            currentBufferReference = latch.buffer
            current.bufferPixelSize = latch.buffer == nil
                ? BufferPixelSize()
                : roleBufferPixelSize
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
            if roleIdentity == .cursor {
                let surfaceID = objectId
                let offsetX = latch.offsetX
                let offsetY = latch.offsetY
                MainActor.assumeIsolated {
                    PointerCursorSurface.applyCommittedOffset(
                        surfaceID: surfaceID,
                        x: offsetX,
                        y: offsetY)
                }
            }
        }
        bufferScale = latch.bufferScale
        bufferTransform = latch.bufferTransform
        if case .set(let s) = latch.opaque { opaqueRegion = s }
        if case .set(let s) = latch.input { inputRegion = s }
        presentation.install(
            commitID: latch.commitID,
            frameCallbacks: latch.frameCallbacks,
            feedbacks: latch.presentationFeedbacks)

        // Latch surface-adjacent state: sticky fields update only when set this
        // commit.
        if latch.auxViewportSourceSet { aux.viewportSource = latch.auxViewportSource }
        if latch.auxViewportDestinationSet { aux.viewportDestination = latch.auxViewportDestination }
        aux.syncAcquire = latch.syncAcquire
        aux.syncRelease = latch.syncRelease

        // Transaction-owned adjacent effects become observable before the scene
        // snapshot, exactly alongside the content state they were captured with.
        for effect in latch.effects { effect() }

        let pixels = committedBufferPixelSize()
        let logical = resolveSurfaceLogicalSize(
            pixels: pixels, bufferScale: bufferScale,
            bufferTransform: bufferTransform,
            viewportDestination: aux.viewportDestination)
        let info = SurfaceCommit(
            surfaceID: objectId,
            commitID: latch.commitID,
            bufferAttached: latch.bufferAttached,
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

        role?.roleSurfaceCommit(self, isInitial: latch.isInitial)
        applyPendingSubsurfaceTopology()
        for child in subsurfaceChildren where child.isEffectivelySync {
            if let cached = child.subsurfaceTopology.cachedCommit {
                child.subsurfaceTopology.cachedCommit = nil
                child.applyLatch(cached)
            }
        }
    }

    func applyCachedSubsurfaceCommit(_ transaction: SurfaceTransaction) {
        applyLatch(transaction)
    }

    private func discardUnapplied(_ latch: SurfaceTransaction) {
        if latch.bufferAttached, let buffer = latch.buffer?.resource {
            wl_buffer_send_release(buffer)
        }
        if let callback = latch.releaseCallback {
            wl_resource_destroy(callback)
        }
        for callback in latch.frameCallbacks {
            wl_resource_destroy(callback)
        }
        for feedback in latch.presentationFeedbacks {
            wp_presentation_feedback_send_discarded(feedback)
            wl_resource_destroy(feedback)
        }
    }

    private func validateViewport(_ latch: SurfaceTransaction) -> Bool {
        let source = latch.auxViewportSourceSet
            ? latch.auxViewportSource
            : aux.viewportSource
        let destination = latch.auxViewportDestinationSet
            ? latch.auxViewportDestination
            : aux.viewportDestination
        guard let source else { return true }
        if destination == nil,
            source.width.rounded(.towardZero) != source.width
                || source.height.rounded(.towardZero) != source.height
        {
            viewport?.postError(
                1 /* bad_size */,
                "fractional viewport source requires a destination size")
            return false
        }
        let pixels = latch.bufferAttached
            ? bufferPixelSize(latch.buffer?.resource)
            : committedBufferPixelSize()
        guard pixels.width != 0, pixels.height != 0 else { return true }
        let unviewported = resolveSurfaceLogicalSize(
            pixels: pixels,
            bufferScale: latch.bufferScale,
            bufferTransform: latch.bufferTransform,
            viewportDestination: nil)
        let maxX = source.x + source.width
        let maxY = source.y + source.height
        guard maxX.isFinite, maxY.isFinite,
            source.x >= 0, source.y >= 0,
            maxX <= unviewported.width,
            maxY <= unviewported.height
        else {
            viewport?.postError(
                2 /* out_of_buffer */,
                "viewport source lies outside the transformed, scaled buffer")
            return false
        }
        return true
    }

    private func committedBufferPixelSize() -> BufferPixelSize {
        current.bufferPixelSize
    }

    private func bufferPixelSize(
        _ buffer: UnsafeMutablePointer<wl_resource>?
    ) -> BufferPixelSize {
        guard let buffer else { return BufferPixelSize() }
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

    /// Snapshot the exact current commit into an accepted output submission.
    func noteSampled(submissionID: UInt64) -> UInt64? {
        presentation.noteSampled(submissionID: submissionID)
    }

    /// Complete only the resources owned by the commit carried through the
    /// matching KMS submission.
    func completePresentation(
        commitID: UInt64,
        submissionID: UInt64,
        output: WlOutput?,
        timeMs: UInt32,
        tvSecHi: UInt32, tvSecLo: UInt32, tvNsec: UInt32,
        refreshNs: UInt32, seqHi: UInt32, seqLo: UInt32, flags: UInt32
    ) {
        presentation.complete(
            commitID: commitID,
            submissionID: submissionID,
            output: output,
            timeMs: timeMs,
            tvSecHi: tvSecHi,
            tvSecLo: tvSecLo,
            tvNsec: tvNsec,
            refreshNs: refreshNs,
            seqHi: seqHi,
            seqLo: seqLo,
            flags: flags)
    }

    /// An accepted frame will never present. Feedback is exact-content and is
    /// discarded; frame callbacks remain eligible for a later redraw when this is
    /// still the current commit, or move to the newer current commit.
    func discardPresentation(commitID: UInt64, submissionID: UInt64) {
        presentation.discard(
            commitID: commitID, submissionID: submissionID)
    }

    deinit {
        // Outstanding frame callbacks never presented: destroy their resources so
        // they don't dangle. (Their wl_resources belong to the client and would
        // otherwise be cleaned up only at client teardown.)
        presentation.destroyAll()
        for cb in pending.frameCallbacks { wl_resource_destroy(cb) }
        if let latch = subsurfaceTopology.cachedCommit {
            for cb in latch.frameCallbacks { wl_resource_destroy(cb) }
        }
        // Presentation feedbacks for never-presented content are discarded.
        for fb in pending.presentationFeedbacks {
            wp_presentation_feedback_send_discarded(fb)
            wl_resource_destroy(fb)
        }
        if let latch = subsurfaceTopology.cachedCommit {
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
        if let cb = pending.releaseCallback { wl_resource_destroy(cb) }
        if let latch = subsurfaceTopology.cachedCommit,
            let cb = latch.releaseCallback
        {
            wl_resource_destroy(cb)
        }
        role?.roleSurfaceDestroyed(self)
        detachFromParent()
        detachSubsurfaceChildren()
        let destroyedSurfaceID = objectId
        MainActor.assumeIsolated {
            PointerCursorSurface.unbind(surfaceID: destroyedSurfaceID)
        }
        compositor?.removeSurface(self)
        compositor?.sceneDelegate?.surfaceDestroyed(
            surfaceID: objectId, iosurfaceID: renderIosurfaceId)
    }
}

/// Weak box for the surface's commit-observer list (Rule 9).
private final class WeakCommitObserver {
    weak var observer: WlSurfaceCommitObserver?
    init(_ observer: WlSurfaceCommitObserver) { self.observer = observer }
}
