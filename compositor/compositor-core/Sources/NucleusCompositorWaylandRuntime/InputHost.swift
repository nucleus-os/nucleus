// InputHost — the Swift owner of the compositor's input backend: the libseat
// session, the libinput context, the xkb keyboard, and the central InputDispatch.
// It is the input analog of XwaylandHost: the bring-up + reactor loop drive it
// through the @_cdecl crossings below, and the reactor loop borrows its seat
// for DRM-primary opens until the loop shell moves to Swift.
//
// Single-threaded on the compositor main actor; the loop handlers run on that
// thread, so the @_cdecl thunks assume isolation. The libinput restricted opens go
// through the seat; the DRM connector-hotplug udev monitor is Swift-owned too,
// sharing libinput's udev context (the reactor borrows its fd and drives the drain).

import Glibc
import NucleusCompositorInputC
import NucleusCompositorServer

// The composition root owns process exit + VT session lifecycle. The area DAG
// forbids the input host (`.nucleus_compositor_substrate`) from importing the runtime
// (`.nucleus_compositor_runtime`), so it reaches them through the inverted
// `NucleusCompositorServer.shared.sessionControl` seam the root installs at bring-up.

@MainActor
final class InputHost {
    let seat: SeatSession
    let xkb: XkbKeyboard
    let dispatch: InputDispatch
    private var libinput: LibinputBackend?
    /// DRM connector-hotplug monitor over libinput's udev context. Released before
    /// the backend that owns that context (udev refcounting makes the order safe).
    private var drmHotplug: UdevMonitor?
    private(set) var active = false

    private init(seat: SeatSession, xkb: XkbKeyboard) {
        self.seat = seat
        self.xkb = xkb
        self.dispatch = InputDispatch(xkb: xkb)
        NucleusCompositorServer.shared.inputControl = self.dispatch
    }

    /// Open the libseat session + compile the keymap. The session is not active until
    /// libseat fires enable; `waitForActivation` pumps the FD until it does. Returns
    /// nil if seatd/logind or xkb is unavailable.
    static func open() -> InputHost? {
        guard let seat = SeatSession.open(), let xkb = XkbKeyboard() else { return nil }
        let host = InputHost(seat: seat, xkb: xkb)
        seat.onEnable = { [weak host] in host?.handleSeatEnable() }
        seat.onDisable = { [weak host] in host?.handleSeatDisable() }
        return host
    }

    /// Pump the seat FD until the initial enable arrives (libseat activates async).
    func waitForActivation() {
        var spins = 0
        while !active && spins < 1000 {
            if seat.dispatch(timeoutMs: 1000) < 0 { break }
            spins += 1
        }
    }

    private func handleSeatEnable() {
        active = true
        // Modifier keys may have released on the other VT; clear stuck state first.
        dispatch.resetKeyboardState()
        libinput?.resume()
        libinput?.dispatch()
        NucleusCompositorServer.shared.sessionControl?.sessionResume()
    }

    private func handleSeatDisable() {
        active = false
        NucleusCompositorServer.shared.sessionControl?.sessionPause()
        libinput?.suspend()
    }

    /// Create the libinput context (its device opens mediated through the seat) and
    /// publish the keymap to the router seat. Returns false on libinput failure.
    func startLibinput() -> Bool {
        guard let li = LibinputBackend.create(seat: seat) else { return false }
        libinput = li
        // The DRM connector-hotplug monitor shares libinput's udev context (one
        // netlink monitor filtered to the "drm" subsystem). Swift owns it now; the
        // reactor borrows its fd and drives `drainDrmHotplug` on readiness.
        drmHotplug = UdevMonitor(udev: li.udevContext, subsystem: "drm")
        publishKeymap()
        return true
    }

    /// Hand the compiled keymap fd + size to the router seat (Swift owns it now),
    /// which relays wl_keyboard.keymap to clients. Re-callable at router activation.
    func publishKeymap() {
        guard xkb.keymapFd >= 0, let seatObj = RouterHost.shared.runtime?.seat else { return }
        seatObj.keymapFd = xkb.keymapFd
        seatObj.keymapSize = xkb.keymapSize
    }

    var seatFd: Int32 { seat.fd }
    var libinputFd: Int32 { libinput?.fd ?? -1 }
    var drmHotplugFd: Int32 { drmHotplug?.fd ?? -1 }

    func dispatchSeat() { seat.dispatch() }

    /// Drain queued DRM udev hotplug events; returns true if any DRM event was
    /// seen so the caller re-enumerates outputs. Draining stops the fd signalling
    /// readable until the next event.
    func drainDrmHotplug() -> Bool {
        guard let mon = drmHotplug else { return false }
        var sawDrm = false
        while let ev = mon.receive() {
            guard ev.subsystem == "drm" else { continue }
            sawDrm = true
        }
        return sawDrm
    }

    /// Drain the libinput event queue: translate each event to a wire record and run
    /// it through the dispatch, applying any exit / VT-switch the dispatch returns.
    func drainLibinput() {
        guard let li = libinput else { return }
        li.dispatch()
        while let event = li.nextEvent() {
            let snapshot = dispatch.currentSnapshot()
            let scale = NucleusCompositorServer.shared.displayFractionalScaleAt(x: snapshot.cursorX, y: snapshot.cursorY)
            let touchSpace = NucleusCompositorServer.shared.layout.displays.first.map {
                TouchCoordinateSpace(
                    x: $0.logicalRect.x, y: $0.logicalRect.y,
                    width: UInt32(max(1, $0.logicalRect.width.rounded())),
                    height: UInt32(max(1, $0.logicalRect.height.rounded())))
            }
            let batch = InputEventNormalize.translate(
                event, snapshot: snapshot, scale: scale, touchSpace: touchSpace)
            libinput_event_destroy(event)
            for record in batch.records {
                switch dispatch.dispatch(record, location: .hid) {
                case .exitRequested:
                    NucleusCompositorServer.shared.sessionControl?.requestExit()
                    return
                case .switchVT(let vt):
                    seat.switchSession(to: vt)
                default:
                    break
                }
            }
            if batch.needsPointerFrame { dispatch.deliverPointerFrame() }
        }
    }

    // Seat-mediated device opens for the DRM backend.
    func openDevice(path: UnsafePointer<CChar>) -> Int32 { seat.openDevice(path: path) }
    func closeDevice(fd: Int32) { seat.closeDevice(fd: fd) }
    func switchSession(to vt: Int32) { seat.switchSession(to: vt) }
}

// MARK: - bring-up + loop crossings (the composition root drives these directly)

@MainActor public func nucleus_input_host_open_seat() -> Bool {
    guard let host = InputHost.open() else { return false }
    RouterHost.shared.inputHost = host
    host.waitForActivation()
    return host.active
}

@MainActor public func nucleus_input_host_start_libinput() -> Bool {
    RouterHost.shared.inputHost?.startLibinput() ?? false
}

@MainActor public func nucleus_input_host_publish_keymap() {
    RouterHost.shared.inputHost?.publishKeymap()
}

@MainActor public func nucleus_input_host_seat_fd() -> Int32 {
    RouterHost.shared.inputHost?.seatFd ?? -1
}

@MainActor public func nucleus_input_host_libinput_fd() -> Int32 {
    RouterHost.shared.inputHost?.libinputFd ?? -1
}

@MainActor public func nucleus_input_host_seat_dispatch() {
    RouterHost.shared.inputHost?.dispatchSeat()
}

/// The Swift-owned DRM connector-hotplug udev monitor fd, or -1 before libinput
/// (which provides the shared udev context) is started.
@MainActor public func nucleus_input_host_drm_hotplug_fd() -> Int32 {
    RouterHost.shared.inputHost?.drmHotplugFd ?? -1
}

/// Drain queued DRM udev hotplug events; returns true if any DRM event was seen.
@MainActor public func nucleus_input_host_drain_drm_hotplug() -> Bool {
    RouterHost.shared.inputHost?.drainDrmHotplug() ?? false
}

@MainActor public func nucleus_input_host_drain_libinput() {
    RouterHost.shared.inputHost?.drainLibinput()
}

/// Open a device node through the Swift seat (the DRM primary node + VT reopen).
/// The composition root installs this as the render runtime's device-seat opener.
@MainActor public func nucleus_input_host_open_device(_ path: UnsafePointer<CChar>?) -> Int32 {
    guard let path else { return -1 }
    return RouterHost.shared.inputHost?.openDevice(path: path) ?? -1
}

@MainActor public func nucleus_input_host_close_device(_ fd: Int32) {
    RouterHost.shared.inputHost?.closeDevice(fd: fd)
}

@MainActor public func nucleus_input_host_shutdown() {
    if NucleusCompositorServer.shared.inputControl === RouterHost.shared.inputHost?.dispatch {
        NucleusCompositorServer.shared.inputControl = nil
    }
    RouterHost.shared.inputHost = nil
}
