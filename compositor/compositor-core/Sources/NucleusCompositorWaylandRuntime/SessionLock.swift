// ext_session_lock_manager_v1 on the router. A privileged client locks the session
// (screen locker): the compositor blanks all outputs and routes input only to the
// client's per-output lock surfaces until it unlocks. The router owns the protocol
// mechanics — granting at most one lock, the lock-surface configure↔ack↔commit
// handshake, and the locked/finished signalling — while the actual security gate
// (blanking presentation, gating input, fail-closed on client death) lives in
// Swift `SessionLockGate` behind the SessionLockDelegate. `locked` is emitted
// only once the gate reports every output has presented a locked frame.

import WaylandServerC
import WaylandServer
import WaylandServerDispatch
import WaylandProtocolTypes
import NucleusRenderModel
import NucleusTypes

/// The security-gate seam. begin arms the gate (false denies the lock → finished);
/// end disarms it on unlock; surfaceMapped
/// reports a mapped lock surface so the gate can focus/blank.
@MainActor
protocol SessionLockDelegate: AnyObject {
    func sessionLockBegin() -> Bool
    func sessionLockEnd()
    func sessionLockSurfaceMapped(_ surface: WlSurface, output: WlOutput?)
}
@MainActor
@safe final class SessionLockManager {
    weak var delegate: (any SessionLockDelegate)?
    private let display: WaylandDisplay

    /// At most one lock is live at a time (the gate is single-owner). The reactor
    /// calls `currentLock?.emitLocked()` once every output presents a locked frame.
    private(set) weak var currentLock: ExtSessionLock?

    init(display: WaylandDisplay) {
        self.display = display
    }

    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            ExtSessionLockManagerV1Server.global(
                implementation: self))
    }

    func nextSerial() -> UInt32 {
        display.nextSerial()
    }

    fileprivate func begin() -> Bool { delegate?.sessionLockBegin() ?? false }
    fileprivate func end() { delegate?.sessionLockEnd() }
    fileprivate func surfaceMapped(_ surface: WlSurface, output: WlOutput?) {
        delegate?.sessionLockSurfaceMapped(surface, output: output)
    }
    fileprivate func clearLock(_ lock: ExtSessionLock) {
        if currentLock === lock { currentLock = nil }
    }

}

extension SessionLockManager: ExtSessionLockManagerV1Requests {
    // lock(id): grant (await locked) or deny (finished immediately).
    func lock(
        _ request: WaylandRequest<ExtSessionLockManagerV1Server>,
        id: WlNewId<ExtSessionLockV1Server>
    ) {
        _ = id.create(
            owner: { handle in
                ExtSessionLock(resource: handle, manager: self)
            },
            installed: { lock in
                if self.currentLock != nil || !self.begin() {
                    lock.markInert()
                    lock.resource.sendFinished()
                    return
                }
                self.currentLock = lock
            })
    }
}

/// ext_session_lock_v1 owner (Rule 9): one granted lock session.
@MainActor
@safe final class ExtSessionLock {
    private weak var manager: SessionLockManager?
    fileprivate let resource: WaylandResourceHandle<ExtSessionLockV1Server>
    private(set) var locked = false
    /// Set on the deny path (a second concurrent locker): the object is finished and
    /// every request except `destroy` is ignored.
    private(set) var inert = false
    private var lockedOutputs: Set<ObjectIdentifier> = []

    init(
        resource: WaylandResourceHandle<ExtSessionLockV1Server>,
        manager: SessionLockManager
    ) {
        self.resource = resource
        self.manager = manager
    }
    fileprivate func markInert() { inert = true }

    /// The reactor calls this once every output has presented a locked frame.
    func emitLocked() {
        guard !locked else { return }
        locked = true
        resource.sendLocked()
    }

    isolated deinit { manager?.clearLock(self) }
}

extension ExtSessionLock: ExtSessionLockV1Requests {
    // unlock_and_destroy: only valid after `locked`. This is the actual session unlock —
    // manager.end() disarms the lock gate; without this override the default auto-destroy would
    // leave the session locked forever. (clearLock also runs in deinit; it is idempotent.)
    func unlockAndDestroy(_ request: WaylandRequest<ExtSessionLockV1Server>) {
        guard locked else {
            request.postError(.invalidUnlock, message: "unlock before locked")  // invalid_unlock
            return
        }
        manager?.end()
        manager?.clearLock(self)
        request.destroy()
    }

    // destroy: only valid before `locked` (the deny path); destroying a live lock is a protocol error.
    func destroy(_ request: WaylandRequest<ExtSessionLockV1Server>) {
        guard !locked else {
            request.postError(.invalidDestroy, message: "destroy after locked")  // invalid_destroy
            return
        }
        manager?.clearLock(self)
        request.destroy()
    }

    // get_lock_surface(id, surface, output)
    func getLockSurface(
        _ request: WaylandRequest<ExtSessionLockV1Server>,
        id: WlNewId<ExtSessionLockSurfaceV1Server>,
                        surface surfaceRes: WaylandBorrowedObject<WlSurfaceServer>,
                        output outputRes: WaylandBorrowedObject<WlOutputServer>) {
        guard let manager,
            let surface = surfaceRes.owner(as: WlSurface.self)
        else { return }
        // An inert (finished) lock ignores every request except destroy — a denied
        // second locker must not be able to create lock surfaces.
        guard !inert else { return }
        let output = outputRes.output
        guard !surface.hasRole else {
            request.postError(.role, message: "surface already has a role")  // role
            return
        }
        guard !surface.committed, !surface.hasCurrentBuffer else {
            request.postError(.alreadyConstructed, message: "surface already committed a buffer")  // already_constructed
            return
        }
        if let output {
            let key = ObjectIdentifier(output)
            guard !lockedOutputs.contains(key) else {
                request.postError(.duplicateOutput, message: "output already has a lock surface")  // duplicate_output
                return
            }
        }
        _ = id.create(
            owner: { handle in
                ExtSessionLockSurface(
                    resource: handle,
                    lock: self,
                    manager: manager,
                    surface: surface,
                    output: output)
            },
            installed: { lockSurface in
                if let output {
                    self.lockedOutputs.insert(ObjectIdentifier(output))
                }
                precondition(surface.assignRole(lockSurface))
                lockSurface.sendConfigure()
            })
    }
}

/// ext_session_lock_surface_v1 owner (Rule 9): the per-output lock surface and its
/// configure↔ack↔commit handshake (WlSurfaceRole).
@MainActor
@safe final class ExtSessionLockSurface: WlSurfaceRole {
    private weak var lock: ExtSessionLock?
    private weak var manager: SessionLockManager?
    private weak var surface: WlSurface?
    private weak var output: WlOutput?
    var outputID: UInt64 { output?.info.outputId ?? 0 }
    private let resource:
        WaylandResourceHandle<ExtSessionLockSurfaceV1Server>
    private var lastConfigureSerial: UInt32 = 0
    private var ackedSerial: UInt32?
    /// The most recently configured surface-local (logical) size — the buffer a client
    /// commits must match it (scaled by buffer_scale), else dimensions_mismatch.
    private var configuredWidth: UInt32 = 0
    private var configuredHeight: UInt32 = 0

    init(
        resource:
            WaylandResourceHandle<ExtSessionLockSurfaceV1Server>,
        lock: ExtSessionLock,
        manager: SessionLockManager,
        surface: WlSurface,
        output: WlOutput?
    ) {
        self.resource = resource
        self.lock = lock
        self.manager = manager
        self.surface = surface
        self.output = output
    }
    /// A lock surface cannot be retargeted to a different wl_output. Destroy its
    /// server-side role resource when that output is withdrawn; the security gate
    /// remains fail-closed and the locker may create a surface for a new output.
    func outputRemoved() {
        output = nil
        resource.destroy()
    }

    /// Configure the lock surface to its output's size (surface-local).
    fileprivate func sendConfigure() {
        guard let manager else { return }
        let rect = output?.logicalRect ?? WlRect(x: 0, y: 0, width: 1, height: 1)
        let serial = manager.nextSerial()
        lastConfigureSerial = serial
        ackedSerial = nil
        configuredWidth = UInt32(max(0, rect.width))
        configuredHeight = UInt32(max(0, rect.height))
        resource.sendConfigure(
            serial: serial,
            width: configuredWidth,
            height: configuredHeight)
    }

    func validateSurfaceCommit(
        _ surface: WlSurface,
        context: SurfaceRoleCommitContext
    ) -> Bool {
        guard ackedSerial != nil else {
            resource.postError(
                .commitBeforeFirstAck,
                message: "commit before first ack_configure")
            return false
        }
        guard context.willHaveBuffer else {
            resource.postError(
                .nullBuffer,
                message: "commit with null buffer")
            return false
        }
        if configuredWidth > 0, configuredHeight > 0 {
            let scale = UInt32(max(1, context.bufferScale))
            guard
                context.bufferPixelSize.width
                    == configuredWidth * scale,
                context.bufferPixelSize.height
                    == configuredHeight * scale
            else {
                resource.postError(
                    .dimensionsMismatch,
                    message: "buffer size does not match configure")
                return false
            }
        }
        return true
    }

    func roleSurfaceCommit(_ surface: WlSurface, isInitial: Bool) {
        manager?.surfaceMapped(surface, output: output)
    }

    func outputChanged() {
        sendConfigure()
    }

    func roleSurfaceDestroyed(_ surface: WlSurface) { self.surface = nil }
}

extension ExtSessionLockSurface: ExtSessionLockSurfaceV1Requests {
    // ack_configure(serial)
    func ackConfigure(_ request: WaylandRequest<ExtSessionLockSurfaceV1Server>, serial: UInt32) {
        guard serial == lastConfigureSerial else {
            request.postError(.invalidSerial, message: "invalid configure serial")  // invalid_serial
            return
        }
        ackedSerial = serial
    }
}
