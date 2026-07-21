// InputHost — the Swift owner of the compositor's input backend: the libseat
// session, the libinput context, the xkb keyboard, and the central InputDispatch.
// It is the input analog of XwaylandHost: the bring-up + reactor loop drive it
// through ordinary Swift calls, and the reactor loop borrows its seat for
// DRM-primary opens.
//
// Single-threaded on the compositor main actor; the loop handlers run on that
// thread, so callback thunks assume isolation. The libinput restricted opens go
// through the seat; the DRM connector-hotplug udev monitor is Swift-owned too,
// sharing libinput's udev context (the reactor borrows its fd and drives the drain).

import Glibc
import NucleusCompositorInputC
import NucleusCompositorServer

// The composition root owns process exit + VT session lifecycle. The area DAG
// forbids the input host (`.nucleus_compositor_substrate`) from importing the runtime
// (`.nucleus_compositor_runtime`), so it reaches them through the inverted
// runtime server's `sessionControl` seam the root installs at bring-up.

@MainActor
final class InputHost {
    private unowned let host: RouterHost
    private struct DeviceCapabilities: Equatable {
        var pointer = false
        var keyboard = false
        var touch = false

        static func | (lhs: Self, rhs: Self) -> Self {
            Self(
                pointer: lhs.pointer || rhs.pointer,
                keyboard: lhs.keyboard || rhs.keyboard,
                touch: lhs.touch || rhs.touch)
        }
    }

    let seat: SeatSession
    let xkb: XkbKeyboard
    let dispatch: InputDispatch
    private var libinput: LibinputBackend?
    /// DRM connector-hotplug monitor over libinput's udev context. Released before
    /// the backend that owns that context (udev refcounting makes the order safe).
    private var drmHotplug: UdevMonitor?
    private var devices: [UInt: DeviceCapabilities] = [:]
    private var advertisedCapabilities = DeviceCapabilities()
    private(set) var active = false

    private init(host: RouterHost, seat: SeatSession, xkb: XkbKeyboard) {
        self.host = host
        self.seat = seat
        self.xkb = xkb
        self.dispatch = InputDispatch(xkb: xkb, host: host)
        host.server.inputControl = self.dispatch
    }

    /// Open the libseat session + compile the keymap. The session is not active until
    /// libseat fires enable; `waitForActivation` pumps the FD until it does. Returns
    /// nil if seatd/logind or xkb is unavailable.
    static func open(host: RouterHost) -> InputHost? {
        guard let seat = SeatSession.open(), let xkb = XkbKeyboard() else { return nil }
        let inputHost = InputHost(host: host, seat: seat, xkb: xkb)
        seat.onEnable = { [weak inputHost] in inputHost?.handleSeatEnable() }
        seat.onDisable = { [weak inputHost] in inputHost?.handleSeatDisable() ?? true }
        return inputHost
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
        if let sessionControl = host.server.sessionControl,
            !sessionControl.sessionResume()
        {
            active = false
            return
        }
        // Modifier keys, focus, or implicit grabs may have changed on the other VT.
        host.runtime?.seat.invalidateSerialsForSessionTransition()
        dispatch.resetSessionState()
        libinput?.resume()
        libinput?.dispatch()
    }

    private func handleSeatDisable() -> Bool {
        active = false
        host.runtime?.seat.invalidateSerialsForSessionTransition()
        dispatch.resetSessionState()
        let canAcknowledge =
            host.server.sessionControl?.sessionPause()
            ?? true
        libinput?.suspend()
        return canAcknowledge
    }

    func completeSessionPause() {
        seat.completeDisableAcknowledgement()
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
        guard xkb.keymapFd >= 0, let seatObj = host.runtime?.seat else { return }
        seatObj.updateKeymap(fd: xkb.keymapFd, size: xkb.keymapSize)
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
            if consumeDeviceLifecycle(event) {
                libinput_event_destroy(event)
                continue
            }
            let snapshot = dispatch.currentSnapshot()
            let scale = host.server.displayFractionalScaleAt(x: snapshot.cursorX, y: snapshot.cursorY)
            let touchSpace = host.server.layout.displays.first.map {
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
                    host.server.sessionControl?.requestExit()
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

    /// Consume libinput's device inventory events before normal event
    /// translation. Capabilities are an aggregate of live physical devices, not a
    /// hard-coded promise made by the Wayland seat.
    private func consumeDeviceLifecycle(_ event: OpaquePointer) -> Bool {
        let type = libinput_event_get_type(event)
        guard type == LIBINPUT_EVENT_DEVICE_ADDED || type == LIBINPUT_EVENT_DEVICE_REMOVED,
            let device = libinput_event_get_device(event)
        else { return false }

        let key = UInt(bitPattern: UnsafeRawPointer(device))
        if type == LIBINPUT_EVENT_DEVICE_ADDED {
            devices[key] = DeviceCapabilities(
                pointer: libinput_device_has_capability(
                    device, LIBINPUT_DEVICE_CAP_POINTER) != 0,
                keyboard: libinput_device_has_capability(
                    device, LIBINPUT_DEVICE_CAP_KEYBOARD) != 0,
                touch: libinput_device_has_capability(
                    device, LIBINPUT_DEVICE_CAP_TOUCH) != 0)
        } else {
            devices[key] = nil
        }

        let next = devices.values.reduce(DeviceCapabilities(), |)
        guard next != advertisedCapabilities else { return true }
        if (advertisedCapabilities.pointer && !next.pointer)
            || (advertisedCapabilities.keyboard && !next.keyboard)
            || (advertisedCapabilities.touch && !next.touch)
        {
            // Clear focus, implicit grabs, pressed keys, and active touches before
            // withdrawing the corresponding capability.
            dispatch.resetSessionState()
        }
        advertisedCapabilities = next
        host.runtime?.seat.updateCapabilities(
            pointer: next.pointer, keyboard: next.keyboard, touch: next.touch)
        return true
    }

    // Seat-mediated device opens for the DRM backend.
    func openDevice(path: UnsafePointer<CChar>) -> Int32 { seat.openDevice(path: path) }
    func closeDevice(fd: Int32) { seat.closeDevice(fd: fd) }
    func switchSession(to vt: Int32) { seat.switchSession(to: vt) }
}

// MARK: - composition-root lifecycle

public extension WaylandRuntime {
    func openSeat() -> Bool {
        guard let inputHost = InputHost.open(host: host) else { return false }
        host.inputHost = inputHost
        inputHost.waitForActivation()
        return inputHost.active
    }

    func startLibinput() -> Bool { host.inputHost?.startLibinput() ?? false }
    func publishKeymap() { host.inputHost?.publishKeymap() }
    var seatFileDescriptor: Int32 { host.inputHost?.seatFd ?? -1 }
    var libinputFileDescriptor: Int32 { host.inputHost?.libinputFd ?? -1 }
    func dispatchSeat() { host.inputHost?.dispatchSeat() }
    var drmHotplugFileDescriptor: Int32 { host.inputHost?.drmHotplugFd ?? -1 }
    func drainDrmHotplug() -> Bool { host.inputHost?.drainDrmHotplug() ?? false }
    func drainLibinput() { host.inputHost?.drainLibinput() }

    func openDevice(_ path: UnsafePointer<CChar>?) -> Int32 {
        guard let path else { return -1 }
        return host.inputHost?.openDevice(path: path) ?? -1
    }

    func closeDevice(_ fileDescriptor: Int32) {
        host.inputHost?.closeDevice(fd: fileDescriptor)
    }

    func shutdownInput() {
        if host.server.inputControl === host.inputHost?.dispatch {
            host.server.inputControl = nil
        }
        host.inputHost = nil
    }

    func completeSessionPause() {
        host.inputHost?.completeSessionPause()
    }
}
