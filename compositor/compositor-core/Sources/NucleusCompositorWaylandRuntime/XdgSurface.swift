// ConfigurePolicy by the production router.

import WaylandServerC
import WaylandServer
import WaylandServerDispatch
import NucleusRenderModel

final class XdgSurface: WlSurfaceRole {
    unowned let shell: XdgShell
    weak var surface: WlSurface?
    private(set) var resource: UnsafeMutablePointer<wl_resource>?
    private let wmBaseResource: UnsafeMutablePointer<wl_resource>

    private let configureLedger = XdgConfigureLedger()
    var lastConsumedConfigure: XdgConfigureRecord? {
        configureLedger.lastConsumed
    }
    private var pendingWindowGeometry: WlRect?
    private var pendingWindowGeometrySet = false
    private(set) var windowGeometry: WlRect?
    weak var toplevel: XdgToplevel?
    weak var popup: XdgPopup?
    private var roleAssigned = false
    private var mapped = false
    private var needsInitialConfigure = true
    var isMapped: Bool { mapped }
    var hasSentInitialConfigure: Bool {
        !needsInitialConfigure
    }

    init(
        shell: XdgShell,
        surface: WlSurface,
        wmBaseResource: UnsafeMutablePointer<wl_resource>
    ) {
        self.shell = shell
        self.surface = surface
        self.wmBaseResource = wmBaseResource
    }

    package func bind(_ resource: UnsafeMutablePointer<wl_resource>) { self.resource = resource }

    deinit {
        surface?.releaseXdgConstruction()
    }

    /// Send and ledger one complete configure record.
    @discardableResult
    func sendConfigureSerial(
        roleState: XdgRoleConfigure,
        initial: Bool
    ) -> UInt32 {
        let serial = shell.nextSerial()
        if let resource { xdg_surface_send_configure(resource, serial) }
        configureLedger.append(XdgConfigureRecord(
            serial: serial, roleState: roleState, initial: initial))
        return serial
    }

    /// Send a full toplevel configure cycle: the toplevel size+states half under a
    /// fresh serial, then the xdg_surface.configure serial.
    func configureToplevel(initial: Bool) {
        guard let toplevel else { return }
        toplevel.decoration?.sendConfigureIfNeeded()
        let plan = shell.delegate?.configure(for: toplevel, initial: initial) ?? XdgToplevelConfigure()
        toplevel.sendConfigure(plan)
        let serial = sendConfigureSerial(
            roleState: .toplevel(plan), initial: initial)
        shell.delegate?.toplevelConfigureSent(toplevel, serial: serial, initial: initial)
        shell.reconfigureReactivePopups(parent: self)
    }

    func hasConfigure(serial: UInt32) -> Bool {
        configureLedger.contains(serial: serial)
    }

    func validatePositionerParentConfigure(
        _ snapshot: XdgPositionerSnapshot
    ) -> Bool {
        if let serial = snapshot.parentConfigureSerial,
            !hasConfigure(serial: serial)
        {
            return false
        }
        let width = windowGeometry?.width
            ?? Int32(clamping: Int(
                max(0, surface?.committedLogicalWidth.rounded(.up) ?? 0)))
        let height = windowGeometry?.height
            ?? Int32(clamping: Int(
                max(0, surface?.committedLogicalHeight.rounded(.up) ?? 0)))
        return mapped && snapshot.isValid(
            parentWidth: width, parentHeight: height)
    }

    func roleObjectDestroyed(_ object: AnyObject) {
        if toplevel === object { toplevel = nil }
        if popup === object { popup = nil }
    }

    func postWmError(_ code: UInt32, _ message: String) {
        swift_wayland_resource_post_error(wmBaseResource, code, message)
    }

    // MARK: WlSurfaceRole

    func validateSurfaceCommit(
        _ surface: WlSurface,
        context: SurfaceRoleCommitContext
    ) -> Bool {
        guard roleAssigned else {
            postWmError(
                1 /* not_constructed */,
                "xdg_surface must be given a role before wl_surface.commit")
            return false
        }
        guard context.willHaveBuffer, !mapped else { return true }
        if let popup, !popup.hasValidParent {
            postWmError(
                3 /* invalid_popup_parent */,
                "popup must be adopted by a valid parent before mapping")
            return false
        }
        guard configureLedger.acknowledged != nil else {
            if let resource {
                swift_wayland_resource_post_error(
                    resource, 3 /* unconfigured_buffer */,
                    "buffer committed before an initial configure was acknowledged")
            }
            return false
        }
        return true
    }

    func roleSurfaceCommit(_ surface: WlSurface, isInitial _: Bool) {
        if pendingWindowGeometrySet {
            windowGeometry = clampedWindowGeometry(
                pendingWindowGeometry, surface: surface)
            pendingWindowGeometrySet = false
        }
        if !surface.hasCurrentBuffer {
            if mapped {
                mapped = false
                shell.dismissPopups(parent: self)
                if let toplevel {
                    shell.toplevelDidUnmap(toplevel)
                    shell.delegate?.toplevelDidCommit(
                        toplevel,
                        ackedSerial: lastConsumedConfigure?.serial ?? 0,
                        hasBuffer: false)
                }
                configureLedger.resetForUnmap()
                needsInitialConfigure = true
            }
            if needsInitialConfigure, toplevel != nil {
                configureToplevel(initial: true)
                needsInitialConfigure = false
            } else if needsInitialConfigure, let popup {
                popup.reconfigureUnderNewParent()
                needsInitialConfigure = false
            }
            return
        }
        _ = configureLedger.consumeAcknowledged()
        mapped = true
        if let toplevel, let consumed = lastConsumedConfigure {
            shell.delegate?.toplevelDidCommit(
                toplevel,
                ackedSerial: consumed.serial,
                hasBuffer: true)
        }
    }

    func roleSurfaceDestroyed(_ surface: WlSurface) { self.surface = nil }

    private func clampedWindowGeometry(
        _ geometry: WlRect?, surface: WlSurface
    ) -> WlRect? {
        guard let geometry else { return nil }
        let surfaceWidth = Int32(clamping: Int(
            max(1, surface.committedLogicalWidth.rounded(.up))))
        let surfaceHeight = Int32(clamping: Int(
            max(1, surface.committedLogicalHeight.rounded(.up))))
        let x = min(max(geometry.x, 0), surfaceWidth - 1)
        let y = min(max(geometry.y, 0), surfaceHeight - 1)
        let width = min(geometry.width, surfaceWidth - x)
        let height = min(geometry.height, surfaceHeight - y)
        return WlRect(
            x: x, y: y,
            width: max(1, width), height: max(1, height))
    }

}

// MARK: xdg_surface requests

extension XdgSurface: XdgSurfaceRequests {
    func destroy(_ resource: UnsafeMutablePointer<wl_resource>) {
        guard toplevel == nil, popup == nil else {
            swift_wayland_resource_post_error(
                resource, 6 /* defunct_role_object */,
                "destroy the XDG role object before xdg_surface")
            return
        }
        surface?.releaseXdgConstruction()
        wl_resource_destroy(resource)
    }

    func getToplevel(_ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId) {
        guard let surface else { return }
        guard !roleAssigned, surface.assignRole(self) else {
            swift_wayland_resource_post_error(resource, 2 /* already_constructed */, "xdg_surface already has a role")
            return
        }
        roleAssigned = true
        let toplevel = XdgToplevel(shell: shell, xdgSurface: self)
        guard let tres = id.create(vtable: XdgToplevelServer.vtable, owner: toplevel)
        else { return }
        toplevel.bind(tres)
        self.toplevel = toplevel
        // The initial configure is sent at the surface's first commit (xdg-shell
        // requires the configure follow the first commit, not the role request).
    }

    func getPopup(
        _ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId,
        parent parentRes: UnsafeMutablePointer<wl_resource>?,
        positioner positionerRes: UnsafeMutablePointer<wl_resource>?
    ) {
        guard let surface, let positionerRes,
            let positioner = WaylandResource.owner(
                of: positionerRes, as: XdgPositioner.self)
        else { return }
        guard let snapshot = positioner.snapshot() else {
            swift_wayland_resource_post_error(
                wmBaseResource, 5 /* invalid_positioner */,
                "positioner is incomplete")
            return
        }
        guard !roleAssigned, surface.assignRole(self) else {
            swift_wayland_resource_post_error(resource, 2 /* already_constructed */, "xdg_surface already has a role")
            return
        }
        roleAssigned = true
        let parent = parentRes.flatMap { WaylandResource.owner(of: $0, as: XdgSurface.self) }
        guard parent?.validatePositionerParentConfigure(snapshot) ?? true else {
            swift_wayland_resource_post_error(
                wmBaseResource, 5 /* invalid_positioner */,
                "positioner is not valid for the mapped parent geometry")
            return
        }
        let popup = XdgPopup(shell: shell, xdgSurface: self, parent: parent)
        guard let pres = id.create(vtable: XdgPopupServer.vtable, owner: popup)
        else { return }
        popup.bind(pres)
        self.popup = popup
        // A popup is configured immediately (placement is known at creation), then
        // the xdg_surface serial pairs it. The first commit maps it.
        let placement = popup.configure(positioner: snapshot)
        _ = sendConfigureSerial(
            roleState: .popup(placement), initial: true)
        needsInitialConfigure = false
    }

    func setWindowGeometry(
        _ resource: UnsafeMutablePointer<wl_resource>, x: Int32, y: Int32, width: Int32, height: Int32
    ) {
        guard width > 0, height > 0 else {
            swift_wayland_resource_post_error(
                resource, 5 /* invalid_size */,
                "window geometry must have positive dimensions")
            return
        }
        pendingWindowGeometry = WlRect(
            x: x, y: y, width: width, height: height)
        pendingWindowGeometrySet = true
    }

    func ackConfigure(_ resource: UnsafeMutablePointer<wl_resource>, serial: UInt32) {
        do {
            try configureLedger.acknowledge(serial: serial)
        } catch {
            swift_wayland_resource_post_error(
                resource, 4 /* invalid_serial */,
                "configure serial was not outstanding on this xdg_surface")
            return
        }
    }
}

// MARK: - xdg_toplevel

/// A toplevel window role. Owns its protocol identity; the window model + configure
/// policy live behind the XdgShellDelegate. A request mutates no window state here:
/// it is decoded and handed to the delegate, then a re-plan configure is sent for
/// state-changing requests.
