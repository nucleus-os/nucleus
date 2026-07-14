// The DRM primary-node device session — Swift-authoritative owner of the DRM
// primary-node fd.
//
// The fd is opened through the Swift seat (libseat) for DRM-master negotiation and
// closed back through it, so this owner is the one place that holds the fd, the
// session generation the reactor's page-flip poll token carries (a device re-open
// mints a fresh generation so stale completions are rejected), and the open/close
// obligation.
//
// The seat lives in the substrate module (built after this one), so it cannot be
// imported here. The composition root installs the seat's open/close as closures
// at bring-up (`DrmSession.installDeviceSeat`).
//
// This is the dependency-clean half of the former `NucleusCompositorRenderRuntime`: it
// references no renderer (only Glibc + injected seat closures), so it is the piece
// that cleaves out of the render runtime into the compositor package. The
// renderer-coupled `RenderRuntime` facade remains in the core `NucleusCompositorRenderRuntime`
// target until its dependency cluster relocates.

import Glibc

@MainActor private var installedSeatOpenDevice: ((UnsafePointer<CChar>?) -> Int32)?
@MainActor private var installedSeatCloseDevice: ((Int32) -> Void)?

@MainActor private func seatOpenDevice(_ path: UnsafePointer<CChar>?) -> Int32 {
    installedSeatOpenDevice?(path) ?? -1
}

@MainActor private func seatCloseDevice(_ fd: Int32) {
    installedSeatCloseDevice?(fd)
}

@MainActor
private final class DrmPrimaryDevice {
    static var shared: DrmPrimaryDevice?

    private(set) var fd: Int32
    private(set) var generation: UInt64

    private init(fd: Int32, generation: UInt64) {
        self.fd = fd
        self.generation = generation
    }

    static func open(path: UnsafePointer<CChar>) -> DrmPrimaryDevice? {
        let fd = seatOpenDevice(path)
        guard fd >= 0 else { return nil }
        let device = DrmPrimaryDevice(fd: fd, generation: 0)
        shared = device
        return device
    }

    func close() {
        if fd >= 0 {
            seatCloseDevice(fd)
            fd = -1
        }
    }
}

@MainActor
public enum DrmSession {
    /// Install the seat's device open/close as closures (the seat is in the
    /// substrate module, built after this one, so it is injected at bring-up).
    public static func installDeviceSeat(
        open: @escaping (UnsafePointer<CChar>?) -> Int32,
        close: @escaping (Int32) -> Void
    ) {
        installedSeatOpenDevice = open
        installedSeatCloseDevice = close
    }

    /// Open the DRM primary node through the Swift seat and take Swift ownership of
    /// the resulting fd. Returns the fd (borrowed by the reactor poll), or -1.
    public static func open(path: UnsafePointer<CChar>?) -> Int32 {
        guard let path else { return -1 }
        return DrmPrimaryDevice.open(path: path)?.fd ?? -1
    }

    /// The Swift-owned DRM primary fd, or -1 when no session is open.
    public static var fd: Int32 {
        DrmPrimaryDevice.shared?.fd ?? -1
    }

    /// The session generation the reactor's DRM poll token carries; 0 when no
    /// session is open.
    public static var generation: UInt64 {
        DrmPrimaryDevice.shared?.generation ?? 0
    }

    /// Close the DRM primary fd back through the seat at compositor shutdown.
    public static func close() {
        DrmPrimaryDevice.shared?.close()
        DrmPrimaryDevice.shared = nil
    }
}
