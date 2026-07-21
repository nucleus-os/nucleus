import Glibc

/// Runtime-owned DRM primary-node session. The compositor composition root
/// injects its libseat device operations and owns this object until reactor
/// shutdown has completed.
@MainActor
public final class DrmSession {
    private var openDevice: ((UnsafePointer<CChar>?) -> Int32)?
    private var closeDevice: ((Int32) -> Void)?

    public private(set) var fd: Int32 = -1
    public private(set) var generation: UInt64 = 0

    public init() {}

    public func installDeviceSeat(
        open: @escaping (UnsafePointer<CChar>?) -> Int32,
        close: @escaping (Int32) -> Void
    ) {
        openDevice = open
        closeDevice = close
    }

    public func open(path: UnsafePointer<CChar>?) -> Int32 {
        guard fd < 0, let path, let openDevice else { return -1 }
        let opened = openDevice(path)
        guard opened >= 0 else { return -1 }
        generation &+= 1
        if generation == 0 { generation = 1 }
        fd = opened
        return opened
    }

    public func close() {
        guard fd >= 0 else { return }
        let ownedFD = fd
        fd = -1
        closeDevice?(ownedFD)
    }
}
