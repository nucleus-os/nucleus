import Glibc

/// Render-server-owned DRM primary-node session. The render-server runtime
/// injects its libseat device operations and owns this object until reactor
/// shutdown has completed.
@MainActor
@safe package final class DrmSession {
    private var openDevice: ((UnsafePointer<CChar>?) -> Int32)?
    private var closeDevice: ((Int32) -> Void)?

    package private(set) var fd: Int32 = -1
    package private(set) var generation: UInt64 = 0

    package init() {}

    package func installDeviceSeat(
        package: @escaping (UnsafePointer<CChar>?) -> Int32,
        close: @escaping (Int32) -> Void
    ) {
        unsafe openDevice = open
        closeDevice = close
    }

    package func open(path: UnsafePointer<CChar>?) -> Int32 {
        guard fd < 0 else { return -1 }
        guard let path = unsafe path else { return -1 }
        guard let openDevice = unsafe openDevice else { return -1 }
        let opened = unsafe openDevice(path)
        guard opened >= 0 else { return -1 }
        generation &+= 1
        if generation == 0 { generation = 1 }
        fd = opened
        return opened
    }

    package func close() {
        guard fd >= 0 else { return }
        let ownedFD = fd
        fd = -1
        closeDevice?(ownedFD)
    }
}
