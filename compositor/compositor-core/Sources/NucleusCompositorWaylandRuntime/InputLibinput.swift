// LibinputBackend — the compositor's libinput context plus the udev context and
// the DRM hotplug monitor. Swift owns device discovery and event extraction
// (Rule 7/9): libinput is created from udev, its restricted device opens are
// mediated through the shared `SeatSession`, and its FD is pumped from the loop.
//
// Single-threaded on the compositor main actor. Holds raw `libinput*`/`udev*`
// pointers and the interface struct libinput retains, so it is a reference type
// with explicit teardown.

import NucleusCompositorInputC

@MainActor
@safe final class UdevMonitor {
    private let udev: OpaquePointer
    private let monitor: OpaquePointer

    /// Create a netlink monitor filtered to `subsystem` (e.g. "drm") and enable
    /// receiving. Returns nil if any step fails.
    init?(udev: OpaquePointer, subsystem: String) {
        guard let mon = unsafe udev_monitor_new_from_netlink(udev, "udev") else { return nil }
        if unsafe udev_monitor_filter_add_match_subsystem_devtype(mon, subsystem, nil) < 0 {
            unsafe udev_monitor_unref(mon)
            return nil
        }
        if unsafe udev_monitor_enable_receiving(mon) < 0 {
            unsafe udev_monitor_unref(mon)
            return nil
        }
        unsafe self.udev = udev
        unsafe self.monitor = mon
    }

    isolated deinit { unsafe udev_monitor_unref(monitor) }

    var fd: Int32 { unsafe udev_monitor_get_fd(monitor) }

    /// A single hotplug event: the device action + sysname, or nil when the queue
    /// is drained. The device is consumed and freed before returning.
    struct HotplugEvent {
        var action: String
        var sysname: String
        var subsystem: String
    }

    func receive() -> HotplugEvent? {
        guard let dev = unsafe udev_monitor_receive_device(monitor) else { return nil }
        defer { unsafe udev_device_unref(dev) }
        let action = unsafe udev_device_get_action(dev).map { unsafe String(cString: $0) } ?? ""
        let sysname = unsafe udev_device_get_sysname(dev).map { unsafe String(cString: $0) } ?? ""
        let subsystem = unsafe udev_device_get_subsystem(dev).map { unsafe String(cString: $0) } ?? ""
        return HotplugEvent(action: action, sysname: sysname, subsystem: subsystem)
    }
}

@MainActor
@safe final class LibinputBackend {
    private let udev: OpaquePointer
    private var handle: OpaquePointer?
    private let interface: UnsafeMutablePointer<libinput_interface>
    /// The seat mediates restricted device opens. Retaining it makes the
    /// `interface` userdata borrow valid until `libinput_unref` disables every
    /// callback; there is no reverse retain from the seat.
    private let seat: SeatSession

    private init(udev: OpaquePointer, interface: UnsafeMutablePointer<libinput_interface>, seat: SeatSession) {
        unsafe self.udev = udev
        unsafe self.interface = interface
        self.seat = seat
    }

    /// Create the udev context + libinput context bound to `seatName`, with device
    /// opens routed through `seat`. Returns nil if udev/libinput creation fails.
    static func create(seat: SeatSession, seatName: String = "seat0") -> LibinputBackend? {
        guard let udev = unsafe udev_new() else { return nil }
        let interface = UnsafeMutablePointer<libinput_interface>.allocate(capacity: 1)
        unsafe interface.pointee = libinput_interface(
            open_restricted: { path, _, data in
                guard let path = unsafe path,
                      let seat = unsafe LibinputBackend.seat(data)
                else { return -1 }
                return unsafe seat.openDevice(path: path)
            },
            close_restricted: { fd, data in
                unsafe LibinputBackend.seat(data)?.closeDevice(fd: fd)
            })
        let userdata = unsafe Unmanaged.passUnretained(seat).toOpaque()
        guard let li = unsafe libinput_udev_create_context(interface, userdata, udev) else {
            unsafe interface.deallocate()
            unsafe udev_unref(udev)
            return nil
        }
        if unsafe libinput_udev_assign_seat(li, seatName) < 0 {
            _ = unsafe libinput_unref(li)
            unsafe interface.deallocate()
            unsafe udev_unref(udev)
            return nil
        }
        let backend = unsafe LibinputBackend(udev: udev, interface: interface, seat: seat)
        unsafe backend.handle = li
        return backend
    }

    isolated deinit {
        if let handle = unsafe handle { _ = unsafe libinput_unref(handle) }
        unsafe interface.deallocate()
        unsafe udev_unref(udev)
    }

    private static func seat(_ data: UnsafeMutableRawPointer?) -> SeatSession? {
        guard let data = unsafe data else { return nil }
        return unsafe Unmanaged<SeatSession>.fromOpaque(data).takeUnretainedValue()
    }

    var fd: Int32 {
        guard let handle = unsafe handle else { return -1 }
        return unsafe libinput_get_fd(handle)
    }
    @unsafe var udevContext: OpaquePointer { unsafe udev }

    func dispatch() {
        guard let handle = unsafe handle else { return }
        _ = unsafe libinput_dispatch(handle)
    }

    func resume() {
        guard let handle = unsafe handle else { return }
        _ = unsafe libinput_resume(handle)
    }

    func suspend() {
        guard let handle = unsafe handle else { return }
        unsafe libinput_suspend(handle)
    }

    /// Pop the next pending libinput event (caller must `libinput_event_destroy` it
    /// after extraction), or nil when the queue is empty.
    @unsafe func nextEvent() -> OpaquePointer? {
        guard let handle = unsafe handle else { return nil }
        return unsafe libinput_get_event(handle)
    }
}
