// SeatSession — the compositor's libseat session/seat owner. Swift owns the seat
// (Rule 7/9): opening it, dispatching its FD, mediating restricted device opens for
// libinput and DRM, and acknowledging VT switches. The seat is shared between input
// input and the DRM backend; the enable/disable
// transitions fan out to both through the `onEnable`/`onDisable` hooks the owner
// installs.
//
// Single-threaded on the compositor main actor. Holds a raw `libseat*` and the
// listener struct libseat retains a pointer to, so it is a reference type with
// explicit teardown.

import NucleusCompositorInputC

@MainActor
final class SeatSession {
    struct NativeOperations {
        let open: (
            UnsafePointer<libseat_seat_listener>?,
            UnsafeMutableRawPointer?
        ) -> OpaquePointer?
        let close: (OpaquePointer?) -> Int32
        let disable: (OpaquePointer?) -> Int32

        @MainActor static let live = NativeOperations(
            open: libseat_open_seat,
            close: libseat_close_seat,
            disable: libseat_disable_seat)
    }

    private var handle: OpaquePointer?
    private let native: NativeOperations
    /// libseat retains the listener pointer for the session's lifetime; keep it in
    /// stable heap storage and feed the session itself as the userdata.
    private let listener: UnsafeMutablePointer<libseat_seat_listener>

    /// Session-active transitions. The owner wires these to resume/suspend Swift
    /// libinput and the DRM outputs.
    var onEnable: (@MainActor () -> Void)?
    var onDisable: (@MainActor () -> Bool)?

    /// A disable callback may outlive the callback stack while KMS waits for an
    /// accepted nonblocking page flip. Keep the acknowledgement obligation here,
    /// beside the libseat handle that owns it.
    private var disableAcknowledgementPending = false

    /// fd → libseat device id, so a libinput close_restricted (which only knows the
    /// fd) can close the right seat device.
    private var deviceIds: [Int32: Int32] = [:]

    private init(native: NativeOperations) {
        self.native = native
        listener = .allocate(capacity: 1)
        listener.initialize(to: libseat_seat_listener(
            enable_seat: { _, data in SeatSession.from(data)?.handleEnable() },
            disable_seat: { seat, data in SeatSession.from(data)?.handleDisable(seat) }))
    }

    /// Open the seat. Returns nil if seatd/logind is unavailable. The session is not
    /// active until libseat fires `enable_seat` (dispatch the FD to pump it).
    static func open() -> SeatSession? {
        open(using: .live)
    }

    /// Internal injection point for deterministic native lifetime coverage.
    static func open(using native: NativeOperations) -> SeatSession? {
        let session = SeatSession(native: native)
        let userdata = Unmanaged.passUnretained(session).toOpaque()
        guard let handle = native.open(session.listener, userdata) else {
            return nil
        }
        session.handle = handle
        return session
    }

    isolated deinit {
        if let handle { _ = native.close(handle) }
        listener.deinitialize(count: 1)
        listener.deallocate()
    }

    private static func from(_ data: UnsafeMutableRawPointer?) -> SeatSession? {
        guard let data else { return nil }
        return Unmanaged<SeatSession>.fromOpaque(data).takeUnretainedValue()
    }

    private func handleEnable() { onEnable?() }

    private func handleDisable(_ seat: OpaquePointer?) {
        disableAcknowledgementPending = true
        if onDisable?() ?? true {
            completeDisableAcknowledgement()
        }
    }

    func completeDisableAcknowledgement() {
        guard disableAcknowledgementPending else { return }
        disableAcknowledgementPending = false
        // Acknowledge deactivation only after all KMS kernel borrows retired.
        if let handle { _ = native.disable(handle) }
    }

    // MARK: - FD + dispatch

    var fd: Int32 { handle.map { libseat_get_fd($0) } ?? -1 }

    @discardableResult
    func dispatch(timeoutMs: Int32 = 0) -> Int32 {
        guard let handle else { return -1 }
        return libseat_dispatch(handle, timeoutMs)
    }

    func switchSession(to vt: Int32) {
        guard let handle else { return }
        _ = libseat_switch_session(handle, vt)
    }

    // MARK: - restricted device opens (mediated for libinput + DRM)

    /// Open a device node through the seat, returning its fd (or -1). Tracks the
    /// fd→id pairing so `closeDevice(fd:)` can release it.
    func openDevice(path: UnsafePointer<CChar>) -> Int32 {
        guard let handle else { return -1 }
        var fd: Int32 = -1
        let id = libseat_open_device(handle, path, &fd)
        guard id >= 0 else { return -1 }
        deviceIds[fd] = id
        return fd
    }

    func closeDevice(fd: Int32) {
        guard let handle else { return }
        if let id = deviceIds.removeValue(forKey: fd) {
            _ = libseat_close_device(handle, id)
        } else {
            close(fd)
        }
    }
}
