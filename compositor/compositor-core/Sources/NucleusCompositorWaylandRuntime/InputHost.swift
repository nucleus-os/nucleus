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
internal import NucleusCompositorServer
import NucleusCompositorServerTypes
package import NucleusConfig

/// Opaque identity for a live C-owned libinput device. It pairs inventory events
/// and is never converted back into a pointer.
private struct LibinputDeviceID: Hashable {
    private let rawValue: UInt

    @unsafe
    init(_ device: OpaquePointer) {
        rawValue = unsafe UInt(bitPattern: UnsafeRawPointer(device))
    }
}

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

    /// One live device: its capabilities, and a retained handle so a
    /// configuration reload can re-apply settings to hardware that is already
    /// connected. libinput hands out no device enumeration, so the only way to
    /// revisit a device later is to have held a reference to it.
    /// `@safe` because the record's whole job is to make the handle's lifetime
    /// an invariant of `InputHost`: it is reffed on the way in, unreffed on
    /// removal and on teardown, and never escapes. Individual uses of the
    /// handle are still marked `unsafe` at their call sites.
    @safe private struct DeviceRecord {
        var capabilities: DeviceCapabilities
        /// Retained with `libinput_device_ref`; released on removal.
        var device: OpaquePointer
    }

    let seat: SeatSession
    let xkb: XkbKeyboard
    let dispatch: InputDispatch
    private var libinput: LibinputBackend?
    /// DRM connector-hotplug monitor over libinput's udev context. Released before
    /// the backend that owns that context (udev refcounting makes the order safe).
    private var drmHotplug: UdevMonitor?
    private var devices: [LibinputDeviceID: DeviceRecord] = [:]
    private var advertisedCapabilities = DeviceCapabilities()
    private(set) var active = false
    /// Settings applied to every device on arrival and on reload. Defaults hold
    /// until the composition root loads a configuration file.
    private var inputConfiguration = InputConfig.defaults

    private init(
        host: RouterHost,
        seat: SeatSession,
        xkb: XkbKeyboard,
        configuration: InputConfig
    ) {
        self.host = host
        self.seat = seat
        self.xkb = xkb
        self.inputConfiguration = configuration
        self.dispatch = InputDispatch(xkb: xkb, host: host)
        host.server.inputControl = self.dispatch
    }

    /// Open the libseat session + compile the keymap. The session is not active until
    /// libseat fires enable; `waitForActivation` pumps the FD until it does. Returns
    /// nil if seatd/logind or xkb is unavailable.
    static func open(
        host: RouterHost, configuration: InputConfig = .defaults
    ) -> InputHost? {
        guard let seat = SeatSession.open(),
            let xkb = XkbKeyboard(rules: xkbRules(for: configuration))
        else { return nil }
        let inputHost = InputHost(
            host: host, seat: seat, xkb: xkb, configuration: configuration)
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
        drmHotplug = unsafe UdevMonitor(udev: li.udevContext, subsystem: "drm")
        publishKeymap()
        return true
    }

    /// Hand the compiled keymap fd + size to the router seat (Swift owns it now),
    /// which relays wl_keyboard.keymap to clients. Re-callable at router activation.
    func publishKeymap() {
        guard let descriptor = xkb.duplicateKeymapDescriptor(),
            let seatObj = host.runtime?.seat
        else { return }
        seatObj.updateKeymap(
            descriptor: consume descriptor,
            size: xkb.keymapSize)
        // Repeat timing belongs to the same keyboard publication: the seat is
        // only reachable once the router is active, which is also the first
        // moment a client could bind a keyboard and read it.
        seatObj.updateRepeatInfo(
            rate: Int32(clamping: inputConfiguration.keyboard.repeatRate),
            delay: Int32(clamping: inputConfiguration.keyboard.repeatDelay))
    }

    /// Adopt a new input configuration.
    ///
    /// Applies to every device already connected, not only to ones that arrive
    /// afterwards — a reload that only affected future hardware would look like
    /// it had silently failed. Key repeat goes to the seat, which rebroadcasts
    /// it to bound keyboards.
    ///
    /// The xkb rule set is deliberately *not* recompiled here. A new keymap
    /// invalidates every client's key state, so it belongs with the session
    /// transition path that already resets modifiers and grabs, not in the
    /// middle of a settings reload.
    func updateInputConfiguration(_ configuration: InputConfig) {
        inputConfiguration = configuration
        for record in devices.values {
            unsafe InputDeviceConfiguration.apply(
                configuration, to: record.device)
        }
        host.runtime?.seat.updateRepeatInfo(
            rate: Int32(clamping: configuration.keyboard.repeatRate),
            delay: Int32(clamping: configuration.keyboard.repeatDelay))
    }

    /// The rule set the keymap should be compiled from. Read at bring-up, where
    /// a fresh keymap costs nothing because no client is bound yet.
    nonisolated static func xkbRules(
        for configuration: InputConfig
    ) -> XkbRules {
        let xkb = configuration.keyboard.xkb
        return XkbRules(
            rules: xkb.rules,
            model: xkb.model,
            layout: xkb.layout,
            variant: xkb.variant,
            options: xkb.options)
    }

    isolated deinit {
        // libinput devices are retained so a reload can revisit them; release
        // them with the host that holds them.
        for record in devices.values {
            _ = unsafe libinput_device_unref(record.device)
        }
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
        while let event = unsafe li.nextEvent() {
            if unsafe consumeDeviceLifecycle(event) {
                unsafe libinput_event_destroy(event)
                continue
            }
            let snapshot = dispatch.currentSnapshot()
            let scale = host.server.displayFractionalScaleAt(
                x: snapshot.cursorX, y: snapshot.cursorY)
            let touchSpace = host.server.layout.displays.first.map {
                TouchCoordinateSpace(
                    x: $0.logicalRect.x, y: $0.logicalRect.y,
                    width: UInt32(max(1, $0.logicalRect.width.rounded())),
                    height: UInt32(max(1, $0.logicalRect.height.rounded())))
            }
            let batch = unsafe InputEventNormalize.translate(
                event, snapshot: snapshot, scale: scale, touchSpace: touchSpace)
            unsafe libinput_event_destroy(event)
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
    @unsafe private func consumeDeviceLifecycle(_ event: OpaquePointer) -> Bool {
        let type = unsafe libinput_event_get_type(event)
        guard type == LIBINPUT_EVENT_DEVICE_ADDED || type == LIBINPUT_EVENT_DEVICE_REMOVED,
            let device = unsafe libinput_event_get_device(event)
        else { return false }

        let key = unsafe LibinputDeviceID(device)
        if type == LIBINPUT_EVENT_DEVICE_ADDED {
            // Configure before the device is announced, so its first event is
            // already produced under the user's settings.
            unsafe InputDeviceConfiguration.apply(
                inputConfiguration, to: device)
            _ = unsafe libinput_device_ref(device)
            unsafe devices[key] = DeviceRecord(
                capabilities: DeviceCapabilities(
                    pointer: unsafe libinput_device_has_capability(
                        device, LIBINPUT_DEVICE_CAP_POINTER) != 0,
                    keyboard: unsafe libinput_device_has_capability(
                        device, LIBINPUT_DEVICE_CAP_KEYBOARD) != 0,
                    touch: unsafe libinput_device_has_capability(
                        device, LIBINPUT_DEVICE_CAP_TOUCH) != 0),
                device: device)
        } else if let record = devices.removeValue(forKey: key) {
            _ = unsafe libinput_device_unref(record.device)
        }

        let next = devices.values.reduce(DeviceCapabilities()) {
            $0 | $1.capabilities
        }
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
    @unsafe func openDevice(path: UnsafePointer<CChar>) -> Int32 {
        unsafe seat.openDevice(path: path)
    }
    func closeDevice(fd: Int32) { seat.closeDevice(fd: fd) }
    func switchSession(to vt: Int32) { seat.switchSession(to: vt) }
}

// MARK: - composition-root lifecycle

extension WaylandRuntime {
    /// Open the seat and compile the keymap under a configuration.
    ///
    /// The configuration arrives here rather than being applied afterwards
    /// because the xkb rule set is an input to keymap compilation, and the
    /// keymap is built exactly once, before any client can bind a keyboard.
    package func openSeat(configuration: InputConfig = .defaults) -> Bool {
        guard
            let inputHost = InputHost.open(
                host: host, configuration: configuration)
        else { return false }
        host.inputHost = inputHost
        inputHost.waitForActivation()
        return inputHost.active
    }

    /// Adopt a configuration after bring-up, applying it to connected devices.
    package func updateInputConfiguration(_ configuration: InputConfig) {
        host.inputHost?.updateInputConfiguration(configuration)
    }

    package func startLibinput() -> Bool { host.inputHost?.startLibinput() ?? false }
    package func publishKeymap() { host.inputHost?.publishKeymap() }
    package var seatFileDescriptor: Int32 { host.inputHost?.seatFd ?? -1 }
    package var libinputFileDescriptor: Int32 { host.inputHost?.libinputFd ?? -1 }
    package func dispatchSeat() { host.inputHost?.dispatchSeat() }
    package var drmHotplugFileDescriptor: Int32 { host.inputHost?.drmHotplugFd ?? -1 }
    package func drainDrmHotplug() -> Bool { host.inputHost?.drainDrmHotplug() ?? false }
    package func drainLibinput() { host.inputHost?.drainLibinput() }

    package func openDevice(_ path: UnsafePointer<CChar>?) -> Int32 {
        guard let path = unsafe path else { return -1 }
        return unsafe host.inputHost?.openDevice(path: path) ?? -1
    }

    package func closeDevice(_ fileDescriptor: Int32) {
        host.inputHost?.closeDevice(fd: fileDescriptor)
    }

    package func shutdownInput() {
        if host.server.inputControl === host.inputHost?.dispatch {
            host.server.inputControl = nil
        }
        host.inputHost = nil
    }

    package func completeSessionPause() {
        host.inputHost?.completeSessionPause()
    }
}
