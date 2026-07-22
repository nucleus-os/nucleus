import Testing
@testable import NucleusRenderer
@testable import NucleusCompositorRendererLinux
import NucleusCompositorDrmC

// `FenceFd` ownership (close on deinit, release hands off) and the DMA-BUF
// sync-flag constants are hardware-independent. The fixture's best-effort real
// syncobj round-trip on a render node (which asserted nothing) is dropped.
@Suite struct DrmSyncTests {
    /// Whether `fd` is still an open descriptor (fcntl F_GETFD succeeds).
    static func isOpen(_ fd: Int32) -> Bool {
        nucleus_drm_fd_is_open(fd) != 0
    }

    @Test func swiftImporterPreservesSyncSnapshotABI() {
        #expect(MemoryLayout<nucleus_drm_sync_file_snapshot>.size == 16)
        #expect(MemoryLayout<nucleus_drm_sync_file_snapshot>.stride == 16)
        #expect(MemoryLayout<nucleus_drm_sync_file_snapshot>.alignment == 8)
        #expect(MemoryLayout<nucleus_drm_sync_file_snapshot>.offset(
            of: \nucleus_drm_sync_file_snapshot.status) == 0)
        #expect(MemoryLayout<nucleus_drm_sync_file_snapshot>.offset(
            of: \nucleus_drm_sync_file_snapshot.fence_count) == 4)
        #expect(MemoryLayout<nucleus_drm_sync_file_snapshot>.offset(
            of: \nucleus_drm_sync_file_snapshot.latest_timestamp_ns) == 8)
    }

    @Test func fenceOwnership() {
        // FenceFd ownership over a real pipe fd (no DRM needed).
        var fds: [Int32] = [-1, -1]
        if pipe(&fds) == 0 {
            let readEnd = fds[0]
            let writeEnd = fds[1]
            close(writeEnd)
            // release() returns the same fd and does NOT close it.
            let fence = FenceFd(owning: readEnd)
            // FenceFd is move-only (~Copyable); read properties into Copyable locals
            // before #expect (the macro captures its expression, requiring Copyable).
            let fenceValid = fence.isValid
            #expect(fenceValid, "fence-valid")
            let raw = fence.release()
            #expect(raw == readEnd, "fence-release-returns-fd")
            #expect(Self.isOpen(raw), "fence-release-keeps-open")
            close(raw)
            // Do not probe the integer after close: another parallel test may
            // immediately reuse that descriptor number for an unrelated file.
        } else {
            Issue.record("pipe")
        }

        // An invalid fd owner reports not-valid (and its deinit no-ops).
        do {
            let invalid = FenceFd(owning: -1)
            let invalidValid = invalid.isValid
            #expect(!invalidValid, "fence-invalid-fd")
        }
    }

    @Test func dmaBufSyncFlags() {
        // DMA-BUF sync-direction flags.
        #expect(DmaBufSync.readWrite == (DmaBufSync.read | DmaBufSync.write), "dmabuf-flags")
    }

    @Test func syncFileSnapshotRejectsNonSyncFileDescriptors() {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else {
            Issue.record("pipe")
            return
        }
        defer {
            close(fds[0])
            close(fds[1])
        }
        var snapshot = nucleus_drm_sync_file_snapshot()
        #expect(nucleus_drm_get_sync_file_snapshot(fds[0], &snapshot) == -1)
        #expect(snapshot.status == 0)
        #expect(snapshot.fence_count == 0)
        #expect(snapshot.latest_timestamp_ns == 0)
    }
}
