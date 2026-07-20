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

/// The security-gate seam. begin arms the gate (false denies the lock → finished);
/// end disarms it on unlock; surfaceMapped
/// reports a mapped lock surface so the gate can focus/blank.
protocol SessionLockDelegate: AnyObject {
    func sessionLockBegin() -> Bool
    func sessionLockEnd()
    func sessionLockSurfaceMapped(_ surface: WlSurface, output: WlOutput?)
}
final class SessionLockManager {
    weak var delegate: SessionLockDelegate?
    private var display: OpaquePointer?

    /// At most one lock is live at a time (the gate is single-owner). The reactor
    /// calls `currentLock?.emitLocked()` once every output presents a locked frame.
    private(set) weak var currentLock: ExtSessionLock?

    func register(in router: NucleusWaylandRouter) {
        display = router.display.display
        router.addGlobal(
            interface: swift_wayland_iface_ext_session_lock_manager_v1(), version: 1,
            impl: self, bind: Self.bind)
    }

    func nextSerial() -> UInt32 {
        guard let display else { return 0 }
        return wl_display_next_serial(display)
    }

    fileprivate func begin() -> Bool { delegate?.sessionLockBegin() ?? false }
    fileprivate func end() { delegate?.sessionLockEnd() }
    fileprivate func surfaceMapped(_ surface: WlSurface, output: WlOutput?) {
        delegate?.sessionLockSurfaceMapped(surface, output: output)
    }
    fileprivate func clearLock(_ lock: ExtSessionLock) {
        if currentLock === lock { currentLock = nil }
    }

    private static let bind: @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32
    ) -> Void = { client, data, version, id in
        guard let client, let me = NucleusWaylandRouter.impl(data, as: SessionLockManager.self)
        else { return }
        _ = WaylandResource.create(
            client: client, interface: swift_wayland_iface_ext_session_lock_manager_v1(),
            version: Int32(version), id: id, vtable: ExtSessionLockManagerV1Server.vtable, owner: me)
    }
}

extension SessionLockManager: ExtSessionLockManagerV1Requests {
    // lock(id): grant (await locked) or deny (finished immediately).
    func lock(_ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId) {
        let lock = ExtSessionLock(manager: self)
        guard let lres = id.create(vtable: ExtSessionLockV1Server.vtable, owner: lock) else { return }
        lock.bind(lres)
        // Deny if a lock is already live or the gate refuses. A denied lock is made
        // inert: it stays a live wire object (the client will `destroy` it) but every
        // request except `destroy` is ignored, so a second locker cannot map lock
        // surfaces or grab focus behind the granted lock.
        if currentLock != nil || !begin() {
            lock.markInert()
            ext_session_lock_v1_send_finished(lres)
            return
        }
        currentLock = lock
    }
}

/// ext_session_lock_v1 owner (Rule 9): one granted lock session.
final class ExtSessionLock {
    private weak var manager: SessionLockManager?
    private var resource: UnsafeMutablePointer<wl_resource>?
    private(set) var locked = false
    /// Set on the deny path (a second concurrent locker): the object is finished and
    /// every request except `destroy` is ignored.
    private(set) var inert = false
    private var lockedOutputs: Set<ObjectIdentifier> = []

    init(manager: SessionLockManager) { self.manager = manager }
    fileprivate func bind(_ resource: UnsafeMutablePointer<wl_resource>) { self.resource = resource }
    fileprivate func markInert() { inert = true }

    /// The reactor calls this once every output has presented a locked frame.
    func emitLocked() {
        guard let resource, !locked else { return }
        locked = true
        ext_session_lock_v1_send_locked(resource)
    }

    deinit { manager?.clearLock(self) }
}

extension ExtSessionLock: ExtSessionLockV1Requests {
    // unlock_and_destroy: only valid after `locked`. This is the actual session unlock —
    // manager.end() disarms the lock gate; without this override the default auto-destroy would
    // leave the session locked forever. (clearLock also runs in deinit; it is idempotent.)
    func unlockAndDestroy(_ resource: UnsafeMutablePointer<wl_resource>) {
        guard locked else {
            swift_wayland_resource_post_error(resource, 1, "unlock before locked")  // invalid_unlock
            return
        }
        manager?.end()
        manager?.clearLock(self)
        wl_resource_destroy(resource)
    }

    // destroy: only valid before `locked` (the deny path); destroying a live lock is a protocol error.
    func destroy(_ resource: UnsafeMutablePointer<wl_resource>) {
        guard !locked else {
            swift_wayland_resource_post_error(resource, 0, "destroy after locked")  // invalid_destroy
            return
        }
        manager?.clearLock(self)
        wl_resource_destroy(resource)
    }

    // get_lock_surface(id, surface, output)
    func getLockSurface(_ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId,
                        surface surfaceRes: UnsafeMutablePointer<wl_resource>?,
                        output outputRes: UnsafeMutablePointer<wl_resource>?) {
        guard let manager,
            let surfaceRes, let surface = WaylandResource.owner(of: surfaceRes, as: WlSurface.self)
        else { return }
        // An inert (finished) lock ignores every request except destroy — a denied
        // second locker must not be able to create lock surfaces.
        guard !inert else { return }
        let output = WlOutput.from(outputRes)
        guard !surface.hasRole else {
            swift_wayland_resource_post_error(resource, 2, "surface already has a role")  // role
            return
        }
        guard !surface.committed, !surface.hasCurrentBuffer else {
            swift_wayland_resource_post_error(resource, 4, "surface already committed a buffer")  // already_constructed
            return
        }
        if let output {
            let key = ObjectIdentifier(output)
            guard !lockedOutputs.contains(key) else {
                swift_wayland_resource_post_error(resource, 3, "output already has a lock surface")  // duplicate_output
                return
            }
            lockedOutputs.insert(key)
        }
        let lockSurface = ExtSessionLockSurface(lock: self, manager: manager, surface: surface, output: output)
        surface.assignRole(lockSurface)
        guard let lsres = id.create(vtable: ExtSessionLockSurfaceV1Server.vtable, owner: lockSurface)
        else { return }
        lockSurface.bind(lsres)
        lockSurface.sendConfigure()
    }
}

/// ext_session_lock_surface_v1 owner (Rule 9): the per-output lock surface and its
/// configure↔ack↔commit handshake (WlSurfaceRole).
final class ExtSessionLockSurface: WlSurfaceRole {
    private weak var lock: ExtSessionLock?
    private weak var manager: SessionLockManager?
    private weak var surface: WlSurface?
    private weak var output: WlOutput?
    var outputID: UInt64 { output?.info.outputId ?? 0 }
    private var resource: UnsafeMutablePointer<wl_resource>?
    private var lastConfigureSerial: UInt32 = 0
    private var ackedSerial: UInt32?
    /// The most recently configured surface-local (logical) size — the buffer a client
    /// commits must match it (scaled by buffer_scale), else dimensions_mismatch.
    private var configuredWidth: UInt32 = 0
    private var configuredHeight: UInt32 = 0

    init(lock: ExtSessionLock, manager: SessionLockManager, surface: WlSurface, output: WlOutput?) {
        self.lock = lock
        self.manager = manager
        self.surface = surface
        self.output = output
    }
    fileprivate func bind(_ resource: UnsafeMutablePointer<wl_resource>) { self.resource = resource }

    /// A lock surface cannot be retargeted to a different wl_output. Destroy its
    /// server-side role resource when that output is withdrawn; the security gate
    /// remains fail-closed and the locker may create a surface for a new output.
    func outputRemoved() {
        output = nil
        if let resource {
            self.resource = nil
            wl_resource_destroy(resource)
        }
    }

    /// Configure the lock surface to its output's size (surface-local).
    fileprivate func sendConfigure() {
        guard let resource, let manager else { return }
        let rect = output?.logicalRect ?? WlRect(x: 0, y: 0, width: 1, height: 1)
        let serial = manager.nextSerial()
        lastConfigureSerial = serial
        ackedSerial = nil
        configuredWidth = UInt32(max(0, rect.width))
        configuredHeight = UInt32(max(0, rect.height))
        ext_session_lock_surface_v1_send_configure(
            resource, serial, configuredWidth, configuredHeight)
    }

    func validateSurfaceCommit(
        _ surface: WlSurface,
        context: SurfaceRoleCommitContext
    ) -> Bool {
        guard let resource else { return false }
        guard ackedSerial != nil else {
            swift_wayland_resource_post_error(
                resource, 0, "commit before first ack_configure")
            return false
        }
        guard context.willHaveBuffer else {
            swift_wayland_resource_post_error(
                resource, 1, "commit with null buffer")
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
                swift_wayland_resource_post_error(
                    resource, 2,
                    "buffer size does not match configure")
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
    func ackConfigure(_ resource: UnsafeMutablePointer<wl_resource>, serial: UInt32) {
        guard serial == lastConfigureSerial else {
            swift_wayland_resource_post_error(resource, 3, "invalid configure serial")  // invalid_serial
            return
        }
        ackedSerial = serial
    }
}
