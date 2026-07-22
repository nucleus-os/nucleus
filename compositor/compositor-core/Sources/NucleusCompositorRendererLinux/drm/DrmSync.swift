// DRM explicit-sync owners and the DMA-BUF sync-file façade.
//
// Three leaf resources the explicit-sync path holds, each a noncopyable owner:
//   - `FenceFd` — a sync_file (or out-fence) file descriptor, closed on `deinit`,
//     `release()`d to hand the raw fd to another owner (the reactor, the seat)
//     without closing.
//   - `DrmSyncobj` — a DRM syncobj handle, created via `drmSyncobjCreate` and
//     destroyed via `drmSyncobjDestroy`; borrows the DRM fd and never closes it.
//     Wraps the libdrm syncobj API (export/import sync-file, handle fd transfer,
//     timeline signal) directly.
//   - `DmaBufSync` — the `nucleus_drm_dmabuf_{export,import}_sync_file` façade
//     wraps the `_IOWR`/`_IOW`
//     request numbers Swift can't fold).

import NucleusCompositorDrmC

// MARK: - Fence fd owner

/// Owns a sync_file / fence file descriptor and closes it on destruction.
struct FenceFd: ~Copyable {
    private(set) var fd: Int32

    init(owning fd: Int32) {
        self.fd = fd
    }

    var isValid: Bool { fd >= 0 }

    /// Relinquish the fd without closing it, ending this owner.
    consuming func release() -> Int32 {
        let taken = fd
        discard self
        return taken
    }

    deinit {
        if fd >= 0 { close(fd) }
    }
}

// MARK: - DRM syncobj owner

/// Owns a DRM syncobj handle, destroyed on teardown. Borrows the DRM device fd
/// (the `DrmDeviceFd` remains its sole owner and outlives this).
struct DrmSyncobj: ~Copyable {
    /// `drmSyncobjCreate` flag: the syncobj starts already signalled.
    static let createSignaled: UInt32 = 1 << 0
    /// Wait for all requested syncobjs/timeline points.
    static let waitAll: UInt32 = 1 << 0
    /// Timeline wait points are submitted as timeline values rather than binary
    /// syncobj waits.
    static let waitForSubmit: UInt32 = 1 << 1
    /// libdrm forwards an absolute CLOCK_MONOTONIC deadline to the kernel. `-1`
    /// is therefore already expired; the conventional non-expiring deadline is
    /// the largest signed nanosecond value.
    static let nonExpiringDeadlineNs: Int64 = .max

    let deviceFd: Int32
    private(set) var handle: UInt32

    init?(deviceFd: Int32, signaled: Bool = false) {
        var created: UInt32 = 0
        let flags = signaled ? DrmSyncobj.createSignaled : 0
        guard drmSyncobjCreate(deviceFd, flags, &created) == 0, created != 0 else { return nil }
        self.deviceFd = deviceFd
        self.handle = created
    }

    init?(deviceFd: Int32, importingHandleFd fd: Int32) {
        var imported: UInt32 = 0
        guard fd >= 0, drmSyncobjFDToHandle(deviceFd, fd, &imported) == 0, imported != 0 else {
            return nil
        }
        self.deviceFd = deviceFd
        self.handle = imported
    }

    var isValid: Bool { handle != 0 }

    /// Export the syncobj's current fence as a sync_file fd (the explicit-sync
    /// hand-off to clients / the reactor).
    borrowing func exportSyncFile() -> FenceFd? {
        var out: Int32 = -1
        guard drmSyncobjExportSyncFile(deviceFd, handle, &out) == 0, out >= 0 else { return nil }
        return FenceFd(owning: out)
    }

    /// Materialize this syncobj as its own handle fd (for cross-process /
    /// cross-device transfer). Distinct from `exportSyncFile`, which exports the
    /// contained fence.
    borrowing func exportHandleFd() -> FenceFd? {
        var out: Int32 = -1
        guard drmSyncobjHandleToFD(deviceFd, handle, &out) == 0, out >= 0 else { return nil }
        return FenceFd(owning: out)
    }

    /// Import a sync_file fence into this syncobj. The caller keeps ownership of
    /// `syncFd`. Returns true on success.
    borrowing func importSyncFile(_ syncFd: Int32) -> Bool {
        drmSyncobjImportSyncFile(deviceFd, handle, syncFd) == 0
    }

    /// Copy a fence from another syncobj's timeline point into this one's.
    borrowing func transfer(
        toPoint dstPoint: UInt64,
        from source: borrowing DrmSyncobj,
        fromPoint srcPoint: UInt64,
        flags: UInt32 = 0
    ) -> Bool {
        drmSyncobjTransfer(deviceFd, handle, dstPoint, source.handle, srcPoint, flags) == 0
    }

    /// Signal this syncobj's timeline at `point`.
    borrowing func timelineSignal(point: UInt64) -> Bool {
        var handles = handle
        var points = point
        return drmSyncobjTimelineSignal(deviceFd, &handles, &points, 1) == 0
    }

    borrowing func timelineWait(
        point: UInt64, timeoutNs: Int64 = DrmSyncobj.nonExpiringDeadlineNs
    ) -> Bool {
        var handles = handle
        var points = point
        var first: UInt32 = 0
        return drmSyncobjTimelineWait(
            deviceFd, &handles, &points, 1, timeoutNs,
            DrmSyncobj.waitAll | DrmSyncobj.waitForSubmit, &first) == 0
    }

    deinit {
        _ = drmSyncobjDestroy(deviceFd, handle)
    }
}

// MARK: - DMA-BUF implicit sync

/// The kernel DMA-BUF implicit-sync ioctls, through the NucleusCompositorDrmC façade.
enum DmaBufSync {
    /// `DMA_BUF_SYNC_*` access-direction flags (mirrored — the kernel header
    /// macros, used to tag the export/import direction).
    static let read: UInt32 = 1 << 0
    static let write: UInt32 = 2 << 0
    static let readWrite: UInt32 = read | write

    /// Export a sync_file fd from a DMA-BUF's implicit reservation. `flags`
    /// selects the access direction.
    static func exportSyncFile(dmabufFd: Int32, flags: UInt32 = read) -> FenceFd? {
        let fd = nucleus_drm_dmabuf_export_sync_file(dmabufFd, flags)
        guard fd >= 0 else { return nil }
        return FenceFd(owning: fd)
    }

    /// Attach a sync_file fence to a DMA-BUF's implicit reservation. The caller
    /// keeps ownership of `syncFd`. Returns true on success.
    static func importSyncFile(dmabufFd: Int32, flags: UInt32, syncFd: Int32) -> Bool {
        nucleus_drm_dmabuf_import_sync_file(dmabufFd, flags, syncFd) == 0
    }
}
