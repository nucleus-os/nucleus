// Swift DrmOutput aggregate.
//
// The owner that composes the DRM mechanisms into one per-output unit:
// the borrowed DRM device fd, the connector/CRTC/plane pipeline ids + mode blob,
// the discovered atomic property group, VRR/recovery/telemetry policy,
// presentation-timing + frame queues, gamma + cursor, and the page-flip token. It
// owns the atomic commit *assembly* — the property set a scanout/modeset commit
// submits, built through
// AtomicRequestBuilder — plus page-flip arming, explicit retirement, and
// recovery-state orchestration.

import NucleusCompositorDrmC
import Glibc

/// The cursor-plane state one commit programs: the framebuffer to scan out and its
/// placement. A nil placement (or `fbId == 0`) clears the plane — the pointer is off
/// this output or no cursor image is loaded.
struct CursorCommitState: Sendable, Equatable {
    var fbId: UInt32
    var placement: CursorPlacement?
}

/// Complete desired KMS state for one output pipeline. Every modeset, scanout,
/// and retirement request flows through this vocabulary so a transition cannot
/// accidentally omit a connector, CRTC, or plane property that belongs to the
/// state being requested.
enum DrmAtomicOutputState: Sendable, Equatable {
    struct Active: Sendable, Equatable {
        var framebufferID: UInt32
        var inFenceFD: Int32 = -1
        var vrrEnabled: Bool
        var cursor: CursorCommitState?
    }

    case disabled
    case active(Active)
}

/// The complete userspace view of one output's kernel scanout ownership.
///
/// `drainingPageFlip` and `drainingReady` are presentation barriers: once
/// retirement starts, no later render turn can submit another framebuffer for
/// this topology generation. Scanout owners remain retained until a blocking
/// disable succeeds or the DRM device is definitively lost.
enum DrmOutputLifecycleState: Sendable, Equatable {
    case disabled
    case active
    case pageFlipPending
    case drainingPageFlip
    case drainingReady
    case deviceLost

    var admitsScanoutCommit: Bool {
        switch self {
        case .disabled, .active:
            true
        case .pageFlipPending, .drainingPageFlip, .drainingReady, .deviceLost:
            false
        }
    }

    var hasPendingPageFlip: Bool {
        self == .pageFlipPending || self == .drainingPageFlip
    }

    var kernelScanoutActive: Bool {
        switch self {
        case .active, .pageFlipPending, .drainingPageFlip, .drainingReady:
            true
        case .disabled, .deviceLost:
            false
        }
    }
}

enum DrmRetirementCommitResult: Sendable, Equatable {
    case accepted
    case rejected(errno: Int32)
}

final class DrmOutput {
    /// Borrowed primary-node DRM fd (the seat / device owner keeps it).
    let device: DrmDeviceLifetime
    var deviceFd: Int32 { device.fileDescriptor }
    let connectorId: UInt32
    let crtcId: UInt32
    let planeId: UInt32
    /// The cursor plane's object id (0 when the pipeline has no cursor plane). Needed
    /// for the cursor plane's atomic state; the property ids are in `cursorProps`.
    let cursorPlaneId: UInt32
    var modeBlobId: UInt32
    let width: UInt32
    let height: UInt32

    let props: AtomicProps
    var supportsInFence: Bool { props.primaryPlaneProps.inFenceFd != 0 }
    let cursorProps: CursorPlaneProps

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
    private(set) var lifecycleState: DrmOutputLifecycleState = .disabled
    var active: Bool { lifecycleState.kernelScanoutActive }
    var pageFlipPending: Bool { lifecycleState.hasPendingPageFlip }

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
        device: DrmDeviceLifetime,
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
        presentPolicy: RendererPresentPolicy = .vsync,
        onPageFlip: @escaping @MainActor @Sendable (DrmPageFlipEvent) -> Void = { _ in }
    ) {
        self.device = device
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
        guard let deviceFd = device.availableFileDescriptor else { return }
        gamma.destroyBlob(fd: deviceFd)
        if modeBlobId != 0 { _ = drmModeDestroyPropertyBlob(deviceFd, modeBlobId) }
    }

    /// Discover the pipeline's atomic + cursor property ids live, then build the
    /// aggregate. Returns nil if the required scanout props are absent.
    static func discover(
        device: DrmDeviceLifetime,
        connectorId: UInt32,
        crtcId: UInt32,
        planeId: UInt32,
        cursorPlaneId: UInt32,
        modeBlobId: UInt32,
        width: UInt32,
        height: UInt32,
        vrrCapable: Bool = false,
        presentPolicy: RendererPresentPolicy = .vsync,
        onPageFlip: @escaping @MainActor @Sendable (DrmPageFlipEvent) -> Void = { _ in }
    ) -> DrmOutput? {
        let props = AtomicPropsDiscovery.discover(
            fd: device.fileDescriptor, connectorId: connectorId, crtcId: crtcId, planeId: planeId)
        guard props.hasRequired else { return nil }
        let cursor = cursorPlaneId != 0
            ? CursorPlaneProps.discover(fd: device.fileDescriptor, planeId: cursorPlaneId)
            : CursorPlaneProps()
        return DrmOutput(
            device: device, connectorId: connectorId, crtcId: crtcId, planeId: planeId,
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

    /// Emit one complete desired output state. This is the sole connector/CRTC/
    /// plane property assembly path for presentation and retirement.
    @discardableResult
    func addAtomicState(
        _ state: DrmAtomicOutputState,
        into builder: inout AtomicRequestBuilder
    ) -> Bool {
        guard props.hasRequired else { return false }
        switch state {
        case .disabled:
            builder.add(
                objectId: connectorId, propertyId: props.connCrtcId,
                value: 0, label: "connector.CRTC_ID")
            builder.add(
                objectId: crtcId, propertyId: props.crtcActive,
                value: 0, label: "crtc.ACTIVE")
            builder.add(
                objectId: crtcId, propertyId: props.crtcModeId,
                value: 0, label: "crtc.MODE_ID")
            let plane = props.primaryPlaneProps
            builder.add(
                objectId: planeId, propertyId: plane.fbId,
                value: 0, label: "plane.FB_ID")
            builder.add(
                objectId: planeId, propertyId: plane.crtcId,
                value: 0, label: "plane.CRTC_ID")
            addCursorPlaneState(into: &builder, cursor: nil)
            addOptionalAtomicProperty(
                into: &builder, objectId: crtcId,
                propertyId: props.crtcVrrEnabled,
                value: 0, label: "crtc.VRR_ENABLED")
            addOptionalAtomicProperty(
                into: &builder, objectId: crtcId,
                propertyId: props.crtcGammaLut,
                value: 0, label: "crtc.GAMMA_LUT")
            addOptionalAtomicProperty(
                into: &builder, objectId: crtcId,
                propertyId: props.crtcDegammaLut,
                value: 0, label: "crtc.DEGAMMA_LUT")
            addOptionalAtomicProperty(
                into: &builder, objectId: crtcId,
                propertyId: props.crtcCtm,
                value: 0, label: "crtc.CTM")
        case .active(let active):
            guard gamma.ensureBlob(
                fd: deviceFd, gammaLutProp: props.crtcGammaLut)
            else { return false }
            builder.add(
                objectId: connectorId, propertyId: props.connCrtcId,
                value: UInt64(crtcId), label: "connector.CRTC_ID")
            builder.add(
                objectId: crtcId, propertyId: props.crtcActive,
                value: 1, label: "crtc.ACTIVE")
            builder.add(
                objectId: crtcId, propertyId: props.crtcModeId,
                value: UInt64(modeBlobId), label: "crtc.MODE_ID")
            addFullPlaneState(
                into: &builder,
                fbId: active.framebufferID,
                inFenceFd: active.inFenceFD)
            addCursorPlaneState(into: &builder, cursor: active.cursor)
            gamma.addToAtomicState(
                into: &builder,
                connectorId: connectorId,
                planeId: planeId,
                crtcId: crtcId,
                props: props,
                includePlaneState: false)
            addOptionalAtomicProperty(
                into: &builder, objectId: crtcId,
                propertyId: props.crtcVrrEnabled,
                value: active.vrrEnabled ? 1 : 0,
                label: "crtc.VRR_ENABLED")
        }
        return true
    }

    private func addOptionalAtomicProperty(
        into builder: inout AtomicRequestBuilder,
        objectId: UInt32,
        propertyId: UInt32,
        value: UInt64,
        label: String
    ) {
        guard propertyId != 0 else { return }
        builder.add(
            objectId: objectId,
            propertyId: propertyId,
            value: value,
            label: label)
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

    /// Whether this frame requests VRR given per-frame direct-scanout eligibility.
    func requestedVrr(directScanoutEligible: Bool) -> Bool {
        vrr.requestedFor(directScanoutEligible: directScanoutEligible)
    }

    /// Validate a scanout commit against the kernel without changing scanout
    /// (DRM_MODE_ATOMIC_TEST_ONLY). The dormant-stack verification path.
    func testScanoutCommit(fbId: UInt32) -> Bool {
        guard var builder = AtomicRequestBuilder() else { return false }
        guard addAtomicState(
            .active(DrmAtomicOutputState.Active(
                framebufferID: fbId,
                vrrEnabled: false,
                cursor: nil)),
            into: &builder)
        else { return false }
        return builder.validates(
            fd: deviceFd,
            flags: drmModeAtomicAllowModeset)
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
        guard lifecycleState.admitsScanoutCommit else { return -EBUSY }
        guard var builder = AtomicRequestBuilder() else { return -22 }
        guard addAtomicState(
            .active(DrmAtomicOutputState.Active(
                framebufferID: fbId,
                inFenceFD: inFenceFd,
                vrrEnabled: requestedVrr,
                cursor: cursor)),
            into: &builder)
        else { return -EINVAL }
        if modeset,
           !builder.validates(
               fd: deviceFd,
               flags: drmModeAtomicAllowModeset)
        {
            let code = rendererErrno()
            return -(code == 0 ? EINVAL : code)
        }
        let flags = commitFlags(requestedVrr: requestedVrr, pageFlipEvent: true, modeset: modeset)
        // The output owns the callback token; the runtime preserves tokens from
        // replaced bindings until the DRM device itself is torn down.
        let userData = flipToken.commitUserData()
        let rc = builder.commit(fd: deviceFd, flags: flags, userData: userData)
        if rc == 0 {
            noteScanoutCommitAccepted(
                retaining: buffer,
                requestedVrr: requestedVrr)
        }
        return rc
    }

    /// Record the kernel borrow created by a successful page-flip commit. Kept
    /// separate from the syscall so the lifecycle and owner retention can be
    /// exercised without DRM hardware.
    func noteScanoutCommitAccepted(
        retaining buffer: AnyObject,
        requestedVrr: Bool = false
    ) {
        precondition(lifecycleState.admitsScanoutCommit)
        lifecycleState = .pageFlipPending
        pendingScanout = buffer
        vrr.applyAfterCommit(requestedVrr: requestedVrr)
        recovery.resetBusy()
    }

    /// Apply a drained page-flip completion and rotate the retained scanout buffers.
    /// The just-flipped `pendingScanout` is
    /// now the latched/displayed front; the previous front is no longer scanned
    /// out and is released here, returning it to the render pool.
    @discardableResult
    func notePageFlipComplete() -> Bool {
        switch lifecycleState {
        case .pageFlipPending:
            lifecycleState = .active
        case .drainingPageFlip:
            lifecycleState = .drainingReady
        case .disabled, .active, .drainingReady, .deviceLost:
            return false
        }
        timing.clearInFlight()
        frontScanout = pendingScanout
        pendingScanout = nil
        return true
    }

    /// Close the presentation gate and report whether a blocking disable can be
    /// attempted now. Repeated calls are idempotent and never release owners.
    @discardableResult
    func beginRetirement() -> Bool {
        switch lifecycleState {
        case .disabled, .deviceLost, .drainingReady:
            return true
        case .active:
            lifecycleState = .drainingReady
            return true
        case .pageFlipPending:
            lifecycleState = .drainingPageFlip
            return false
        case .drainingPageFlip:
            return false
        }
    }

    /// Record the successful blocking disable before framebuffer owners are
    /// released.
    func noteScanoutDisabled() {
        precondition(
            lifecycleState == .disabled
                || lifecycleState == .drainingReady)
        lifecycleState = .disabled
        timing.clearInFlight()
        frontScanout = nil
        pendingScanout = nil
    }

    /// A closed/removed DRM device can no longer hold a userspace framebuffer
    /// reference. This is the only non-disable transition allowed to release the
    /// retained scanout owners.
    func noteDeviceLost() {
        lifecycleState = .deviceLost
        timing.clearInFlight()
        frontScanout = nil
        pendingScanout = nil
    }

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

/// Run one retryable, device-wide retirement transaction. The commit closure is
/// invoked only after every output has crossed its presentation barrier. `EBUSY`
/// keeps the outputs in `drainingReady` with all owners retained so a later loop
/// turn can retry the exact disable.
func retireDrmOutputs(
    _ outputs: [DrmOutput],
    commit: (_ outputsRequiringDisable: [DrmOutput]) -> DrmRetirementCommitResult
) -> RendererRetirementResult {
    guard !outputs.isEmpty else { return .complete }
    var ready = true
    for output in outputs {
        if !output.beginRetirement() { ready = false }
    }
    guard ready else { return .draining }

    // Disabled outputs and outputs whose device is already gone have no live
    // kernel CRTC ownership to clear. Excluding the latter is essential: issuing
    // an atomic commit on a lost device would convert a safely released lifetime
    // into a spurious retirement failure.
    let requiringDisable = outputs.filter {
        $0.lifecycleState == .drainingReady
    }
    guard !requiringDisable.isEmpty else { return .complete }

    switch commit(requiringDisable) {
    case .accepted:
        for output in requiringDisable { output.noteScanoutDisabled() }
        return .complete
    case .rejected(let code) where code == EBUSY:
        return .draining
    case .rejected:
        return .failed
    }
}
