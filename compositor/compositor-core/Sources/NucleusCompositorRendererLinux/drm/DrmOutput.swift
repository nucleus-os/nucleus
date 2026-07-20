// Swift DrmOutput aggregate.
//
// The owner that composes the DRM mechanisms into one per-output unit:
// the borrowed DRM device fd, the connector/CRTC/plane pipeline ids + mode blob,
// the discovered atomic property group, VRR/recovery/telemetry policy,
// presentation-timing + frame queues, gamma + cursor, and the page-flip token. It
// owns the atomic commit *assembly* — the property set a scanout/modeset commit
// submits, built through
// AtomicRequestBuilder — plus the page-flip arming and the pure lifecycle
// orchestration (cancel-pending, recovery clear).

import NucleusCompositorDrmC

/// The cursor-plane state one commit programs: the framebuffer to scan out and its
/// placement. A nil placement (or `fbId == 0`) clears the plane — the pointer is off
/// this output or no cursor image is loaded.
struct CursorCommitState {
    var fbId: UInt32
    var placement: CursorPlacement?
}

final class DrmOutput {
    /// Borrowed primary-node DRM fd (the seat / device owner keeps it).
    let deviceFd: Int32
    let connectorId: UInt32
    let crtcId: UInt32
    let planeId: UInt32
    /// The cursor plane's object id (0 when the pipeline has no cursor plane). Needed
    /// for the cursor plane's atomic state; the property ids are in `cursorProps`.
    let cursorPlaneId: UInt32
    var modeBlobId: UInt32
    let width: UInt32
    let height: UInt32

    /// Discovered atomic property ids for this pipeline (10a.3).
    let props: AtomicProps
    var supportsInFence: Bool { props.primaryPlaneProps.inFenceFd != 0 }
    let cursorProps: CursorPlaneProps

    // Policy + frame state (10a.7 / 10a.8 / 10a.9).
    var vrr: VrrState
    var recovery = RecoveryState()
    var telemetry = FrameTelemetry()
    var timing = PresentationTiming()
    var mailbox: MailboxQueue
    var rendered = RenderedFrameQueue()
    var gamma = GammaState()

    // A newly discovered pipeline has not yet committed this owner's MODE_ID and
    // framebuffer. The first scanout must be an ALLOW_MODESET commit even if the
    // firmware or previous compositor happened to leave the CRTC active.
    var active = false
    /// One armed out-fence at a time (10a.4); -1 when none in flight.
    private(set) var pageFlipPending = false

    /// Per-output page-flip context handed to the commit's user_data (10a.5).
    let flipToken: DrmPageFlipToken

    /// The scanout buffers the kernel currently owns: `frontScanout` is latched
    /// and displayed, `pendingScanout` was submitted and awaits its page-flip.
    /// Held as opaque references so this DRM layer stays decoupled from the
    /// renderer's slot type — their sole job is to keep the framebuffer (and its
    /// GBM BO / Vulkan image) alive for exactly as long as the CRTC scans it,
    /// independent of the render pool's lifetime. Without this, a buffer rotated
    /// out of the render ring (or a dropped output binding) could destroy a
    /// framebuffer the kernel is still scanning out.
    private var frontScanout: AnyObject?
    private var pendingScanout: AnyObject?

    init(
        deviceFd: Int32,
        connectorId: UInt32,
        crtcId: UInt32,
        planeId: UInt32,
        cursorPlaneId: UInt32 = 0,
        modeBlobId: UInt32,
        width: UInt32,
        height: UInt32,
        props: AtomicProps,
        cursorProps: CursorPlaneProps = CursorPlaneProps(),
        vrrCapable: Bool = false,
        presentPolicy: PresentPolicy = .vsync,
        onPageFlip: @escaping @MainActor @Sendable (DrmPageFlipEvent) -> Void = { _ in }
    ) {
        self.deviceFd = deviceFd
        self.connectorId = connectorId
        self.crtcId = crtcId
        self.planeId = planeId
        self.cursorPlaneId = cursorPlaneId
        self.modeBlobId = modeBlobId
        self.width = width
        self.height = height
        self.props = props
        self.cursorProps = cursorProps
        self.vrr = VrrState(capable: vrrCapable)
        self.mailbox = MailboxQueue(policy: presentPolicy)
        self.flipToken = DrmPageFlipToken(onFlip: onPageFlip)
    }

    /// The KMS MODE_ID property blob (`drmModeCreatePropertyBlob`) is owned for this
    /// output's lifetime and freed when the aggregate is dropped — on binding
    /// teardown/shutdown and on re-enumerate overwrite. Sole owner, so no double-free.
    deinit {
        // Destroy every kernel property blob this output owns: the GAMMA_LUT blob
        // (if a ramp was staged) and the MODE_ID blob. Sole owner of each, so no
        // double-free.
        gamma.destroyBlob(fd: deviceFd)
        if modeBlobId != 0 { _ = drmModeDestroyPropertyBlob(deviceFd, modeBlobId) }
    }

    /// Discover the pipeline's atomic + cursor property ids live, then build the
    /// aggregate. Returns nil if the required scanout props are absent.
    static func discover(
        deviceFd: Int32,
        connectorId: UInt32,
        crtcId: UInt32,
        planeId: UInt32,
        cursorPlaneId: UInt32,
        modeBlobId: UInt32,
        width: UInt32,
        height: UInt32,
        vrrCapable: Bool = false,
        presentPolicy: PresentPolicy = .vsync,
        onPageFlip: @escaping @MainActor @Sendable (DrmPageFlipEvent) -> Void = { _ in }
    ) -> DrmOutput? {
        let props = AtomicPropsDiscovery.discover(
            fd: deviceFd, connectorId: connectorId, crtcId: crtcId, planeId: planeId)
        guard props.hasRequired else { return nil }
        let cursor = cursorPlaneId != 0
            ? CursorPlaneProps.discover(fd: deviceFd, planeId: cursorPlaneId)
            : CursorPlaneProps()
        return DrmOutput(
            deviceFd: deviceFd, connectorId: connectorId, crtcId: crtcId, planeId: planeId,
            cursorPlaneId: cursorPlaneId, modeBlobId: modeBlobId, width: width, height: height,
            props: props, cursorProps: cursor, vrrCapable: vrrCapable, presentPolicy: presentPolicy,
            onPageFlip: onPageFlip)
    }

    // MARK: - Commit assembly

    /// Populate the primary-plane state for a full-output scanout. Mirrors
    /// `KmsAtomicState.addPlaneState` (FB/CRTC ids, zeroed source origin, 16.16
    /// source size, full-output CRTC rect, optional COLOR_RANGE).
    private func addFullPlaneState(
        into builder: inout AtomicRequestBuilder, fbId: UInt32, inFenceFd: Int32 = -1
    ) {
        let p = props.primaryPlaneProps
        builder.add(objectId: planeId, propertyId: p.fbId, value: UInt64(fbId), label: "plane.FB_ID")
        builder.add(objectId: planeId, propertyId: p.crtcId, value: UInt64(crtcId), label: "plane.CRTC_ID")
        builder.add(objectId: planeId, propertyId: p.srcX, value: 0, label: "plane.SRC_X")
        builder.add(objectId: planeId, propertyId: p.srcY, value: 0, label: "plane.SRC_Y")
        builder.add(objectId: planeId, propertyId: p.srcW, value: UInt64(width) << 16, label: "plane.SRC_W")
        builder.add(objectId: planeId, propertyId: p.srcH, value: UInt64(height) << 16, label: "plane.SRC_H")
        builder.add(objectId: planeId, propertyId: p.crtcX, value: 0, label: "plane.CRTC_X")
        builder.add(objectId: planeId, propertyId: p.crtcY, value: 0, label: "plane.CRTC_Y")
        builder.add(objectId: planeId, propertyId: p.crtcW, value: UInt64(width), label: "plane.CRTC_W")
        builder.add(objectId: planeId, propertyId: p.crtcH, value: UInt64(height), label: "plane.CRTC_H")
        if p.colorRange != 0 {
            builder.add(objectId: planeId, propertyId: p.colorRange, value: 1, label: "plane.COLOR_RANGE")
        }
        if p.inFenceFd != 0, inFenceFd >= 0 {
            builder.add(
                objectId: planeId, propertyId: p.inFenceFd,
                value: UInt64(UInt32(bitPattern: inFenceFd)), label: "plane.IN_FENCE_FD")
        }
    }

    /// Populate the cursor plane's atomic state, or clear it (FB_ID/CRTC_ID = 0) when
    /// `cursor` is nil / off-output / has no image. No-op when the pipeline has no
    /// cursor plane. The plane presents its full BO extent (image packed top-left);
    /// the placement carries the hotspot-adjusted, scaled CRTC position (signed
    /// CRTC_X/Y when the cursor overhangs the top/left edge).
    private func addCursorPlaneState(into builder: inout AtomicRequestBuilder, cursor: CursorCommitState?) {
        guard cursorPlaneId != 0, cursorProps.fbId != 0 else { return }
        let c = cursorProps
        if let cursor, cursor.fbId != 0, let p = cursor.placement {
            builder.add(objectId: cursorPlaneId, propertyId: c.fbId, value: UInt64(cursor.fbId), label: "cursor.FB_ID")
            builder.add(objectId: cursorPlaneId, propertyId: c.crtcId, value: UInt64(crtcId), label: "cursor.CRTC_ID")
            if c.srcX != 0 { builder.add(objectId: cursorPlaneId, propertyId: c.srcX, value: 0, label: "cursor.SRC_X") }
            if c.srcY != 0 { builder.add(objectId: cursorPlaneId, propertyId: c.srcY, value: 0, label: "cursor.SRC_Y") }
            builder.add(objectId: cursorPlaneId, propertyId: c.srcW, value: p.srcW, label: "cursor.SRC_W")
            builder.add(objectId: cursorPlaneId, propertyId: c.srcH, value: p.srcH, label: "cursor.SRC_H")
            builder.add(objectId: cursorPlaneId, propertyId: c.crtcX, value: UInt64(bitPattern: p.crtcX), label: "cursor.CRTC_X")
            builder.add(objectId: cursorPlaneId, propertyId: c.crtcY, value: UInt64(bitPattern: p.crtcY), label: "cursor.CRTC_Y")
            builder.add(objectId: cursorPlaneId, propertyId: c.crtcW, value: UInt64(p.crtcW), label: "cursor.CRTC_W")
            builder.add(objectId: cursorPlaneId, propertyId: c.crtcH, value: UInt64(p.crtcH), label: "cursor.CRTC_H")
        } else {
            builder.add(objectId: cursorPlaneId, propertyId: c.fbId, value: 0, label: "cursor.FB_ID")
            builder.add(objectId: cursorPlaneId, propertyId: c.crtcId, value: 0, label: "cursor.CRTC_ID")
        }
    }

    /// Assemble a full scanout/modeset commit into `builder`: connector routing,
    /// CRTC active + mode, primary-plane state, the gamma/color pipeline, VRR, and the
    /// cursor plane. Returns false if the required props are absent. COLOR_RANGE is
    /// added once, by the plane state.
    @discardableResult
    func assembleScanoutCommit(
        into builder: inout AtomicRequestBuilder,
        fbId: UInt32,
        requestedVrr: Bool,
        inFenceFd: Int32 = -1,
        cursor: CursorCommitState? = nil
    ) -> Bool {
        guard props.hasRequired else { return false }
        guard gamma.ensureBlob(
            fd: deviceFd, gammaLutProp: props.crtcGammaLut)
        else { return false }
        builder.add(objectId: connectorId, propertyId: props.connCrtcId, value: UInt64(crtcId), label: "connector.CRTC_ID")
        builder.add(objectId: crtcId, propertyId: props.crtcActive, value: 1, label: "crtc.ACTIVE")
        builder.add(objectId: crtcId, propertyId: props.crtcModeId, value: UInt64(modeBlobId), label: "crtc.MODE_ID")
        addFullPlaneState(into: &builder, fbId: fbId, inFenceFd: inFenceFd)
        addCursorPlaneState(into: &builder, cursor: cursor)
        gamma.addToAtomicState(
            into: &builder, connectorId: connectorId, planeId: planeId, crtcId: crtcId,
            props: props, includePlaneState: false)
        if props.crtcVrrEnabled != 0 {
            builder.add(objectId: crtcId, propertyId: props.crtcVrrEnabled,
                        value: requestedVrr ? 1 : 0, label: "crtc.VRR_ENABLED")
        }
        return true
    }

    /// The atomic-commit flags for a scanout: live event-producing flips are
    /// nonblocking, while a modeset is additionally allowed when requested or
    /// when toggling VRR. Teardown uses its own deliberately blocking commit.
    func commitFlags(requestedVrr: Bool, pageFlipEvent: Bool, modeset: Bool) -> UInt32 {
        var flags = vrr.flagsForCommit(requestedVrr: requestedVrr)
        if modeset { flags |= drmModeAtomicAllowModeset }
        if pageFlipEvent {
            flags |= UInt32(DRM_MODE_PAGE_FLIP_EVENT)
            flags |= drmModeAtomicNonblock
        }
        return flags
    }

    /// Whether this frame requests VRR given the per-frame direct-scanout
    /// eligibility (10a.7 policy).
    func requestedVrr(directScanoutEligible: Bool) -> Bool {
        vrr.requestedFor(directScanoutEligible: directScanoutEligible)
    }

    /// Validate a scanout commit against the kernel without changing scanout
    /// (DRM_MODE_ATOMIC_TEST_ONLY). The dormant-stack verification path.
    func testScanoutCommit(fbId: UInt32) -> Bool {
        guard var builder = AtomicRequestBuilder() else { return false }
        guard assembleScanoutCommit(into: &builder, fbId: fbId, requestedVrr: false) else { return false }
        return builder.validates(fd: deviceFd)
    }

    /// Submit a real scanout commit (page-flip event delivery, user_data = the
    /// flip token), retaining `buffer` for the duration of the kernel's scanout.
    /// `buffer` is the render-pool slot that owns `fbId`'s framebuffer; holding it
    /// here keeps that framebuffer alive while the CRTC scans it, regardless of
    /// the render ring rotating or the binding being torn down. Returns libdrm's
    /// result; the buffer is only retained on a successful commit.
    func commitScanout(
        retaining buffer: AnyObject, fbId: UInt32, requestedVrr: Bool, modeset: Bool,
        inFenceFd: Int32 = -1,
        cursor: CursorCommitState? = nil
    ) -> Int32 {
        guard var builder = AtomicRequestBuilder() else { return -22 }
        guard assembleScanoutCommit(
            into: &builder, fbId: fbId, requestedVrr: requestedVrr,
            inFenceFd: inFenceFd, cursor: cursor) else { return -22 }
        let flags = commitFlags(requestedVrr: requestedVrr, pageFlipEvent: true, modeset: modeset)
        // The output owns the callback token; the runtime preserves tokens from
        // replaced bindings until the DRM device itself is torn down.
        let userData = flipToken.commitUserData()
        let rc = builder.commit(fd: deviceFd, flags: flags, userData: userData)
        if rc == 0 {
            active = true
            pageFlipPending = true
            pendingScanout = buffer
            vrr.applyAfterCommit(requestedVrr: requestedVrr)
            recovery.resetBusy()
        }
        return rc
    }

    /// Apply a drained page-flip completion (10a.5): clear the in-flight slot and
    /// rotate the retained scanout buffers. The just-flipped `pendingScanout` is
    /// now the latched/displayed front; the previous front is no longer scanned
    /// out and is released here, returning it to the render pool.
    func notePageFlipComplete() {
        pageFlipPending = false
        timing.clearInFlight()
        frontScanout = pendingScanout
        pendingScanout = nil
    }

    /// Add this output's complete disabled state to a device-wide atomic request.
    /// Callers can combine several outputs so a topology generation is retired in
    /// one KMS transaction.
    func addDisableState(into builder: inout AtomicRequestBuilder) {
        let p = props.primaryPlaneProps
        builder.add(
            objectId: connectorId, propertyId: props.connCrtcId,
            value: 0, label: "connector.CRTC_ID")
        builder.add(
            objectId: crtcId, propertyId: props.crtcActive,
            value: 0, label: "crtc.ACTIVE")
        builder.add(
            objectId: planeId, propertyId: p.fbId,
            value: 0, label: "plane.FB_ID")
        builder.add(
            objectId: planeId, propertyId: p.crtcId,
            value: 0, label: "plane.CRTC_ID")
        if cursorPlaneId != 0, cursorProps.fbId != 0 {
            builder.add(
                objectId: cursorPlaneId, propertyId: cursorProps.fbId,
                value: 0, label: "cursor.FB_ID")
            builder.add(
                objectId: cursorPlaneId, propertyId: cursorProps.crtcId,
                value: 0, label: "cursor.CRTC_ID")
        }
    }

    /// Record the successful blocking disable before framebuffer owners are
    /// released.
    func noteScanoutDisabled() {
        active = false
        pageFlipPending = false
        timing.clearInFlight()
        frontScanout = nil
        pendingScanout = nil
    }

    // MARK: - Lifecycle orchestration (pure state)

    /// Clear all in-flight presentation state, returning the queued frames whose
    /// fds the caller must close. Mirrors `cancelPendingPresentation`'s state
    /// reset (the Vulkan drain + reactor cancel are integration).
    @discardableResult
    func cancelPendingPresentation() -> (rendered: [PendingRenderedFrame], mailbox: [PendingMailboxFrame]) {
        // The callback token is binding-owned rather than retained per commit, so
        // cancelling cannot leak or race an ARC balance against a late callback.
        pageFlipPending = false
        timing.clearInFlight()
        // A cancelled flip may already be latched by the kernel, so keep retaining
        // the submitted buffer (fold it into front) rather than freeing one the
        // CRTC might still scan. It is released by the next flip or the
        // device-wide topology retirement commit.
        if pendingScanout != nil {
            frontScanout = pendingScanout
            pendingScanout = nil
        }
        let droppedRendered = rendered.drain()
        var droppedMailbox: [PendingMailboxFrame] = []
        while let frame = mailbox.popPending() { droppedMailbox.append(frame) }
        mailbox.bumpGenerationOnDrain()
        return (droppedRendered, droppedMailbox)
    }

    /// Enter degraded recovery after a commit failure (10a.7 backoff).
    func enterDegradedRecovery(nowNs: UInt64) {
        recovery.enterDegraded(nowNs: nowNs)
    }

    /// Whether the degraded output is due for a recovery attempt and idle.
    func shouldAttemptRecovery(nowNs: UInt64) -> Bool {
        recovery.isRecoveryDue(nowNs: nowNs) && !pageFlipPending &&
            rendered.count == 0 && mailbox.pendingCount == 0
    }

    func clearRecovery() {
        recovery.clear()
    }
}
