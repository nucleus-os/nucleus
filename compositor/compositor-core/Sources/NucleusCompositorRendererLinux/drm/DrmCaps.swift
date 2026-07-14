// Phase 10a.6 (part 1) — Swift DRM capability discovery + session ioctls over
// real libdrm.
//
// Init-time capability negotiation an output pipeline needs before scanout:
// enabling the universal-planes + atomic client caps, and reading the cursor
// dimensions / ADDFB2-modifiers / syncobj device caps. Plus the
// outside-the-frame-path session ioctls (`drmSetMaster`/`drmDropMaster`) and the
// PRIME import / GEM-close helpers framebuffer creation uses. Nothing imports it yet.

import NucleusCompositorDrmC

/// The device + plane capabilities an output reads at init.
struct DrmCaps: Sendable, Equatable {
    var cursorWidth: UInt64
    var cursorHeight: UInt64
    var addFB2Modifiers: Bool
    var syncobj: Bool
}

enum DrmCapabilities {
    // Device caps (drm.h DRM_CAP_*).
    static let capCursorWidth: UInt64 = 0x8
    static let capCursorHeight: UInt64 = 0x9
    static let capAddFB2Modifiers: UInt64 = 0x10
    static let capSyncobj: UInt64 = 0x13

    // Client caps (drm.h DRM_CLIENT_CAP_*).
    static let clientCapUniversalPlanes: UInt64 = 1
    static let clientCapAtomic: UInt64 = 3

    /// Read a device capability, or nil if the query failed.
    static func get(fd: Int32, capability: UInt64) -> UInt64? {
        var value: UInt64 = 0
        return drmGetCap(fd, capability, &value) == 0 ? value : nil
    }

    /// Enable a client capability. Returns true on success.
    @discardableResult
    static func setClientCap(fd: Int32, capability: UInt64, value: UInt64 = 1) -> Bool {
        drmSetClientCap(fd, capability, value) == 0
    }

    /// Enable universal planes then atomic — the order the kernel requires
    /// (atomic implies universal planes). Returns true only if both succeed.
    static func enableAtomicModesetting(fd: Int32) -> Bool {
        setClientCap(fd: fd, capability: clientCapUniversalPlanes) &&
            setClientCap(fd: fd, capability: clientCapAtomic)
    }

    /// Read the cursor/modifier/syncobj device caps. Absent caps read as 0/false.
    static func discover(fd: Int32) -> DrmCaps {
        DrmCaps(
            cursorWidth: get(fd: fd, capability: capCursorWidth) ?? 0,
            cursorHeight: get(fd: fd, capability: capCursorHeight) ?? 0,
            addFB2Modifiers: (get(fd: fd, capability: capAddFB2Modifiers) ?? 0) != 0,
            syncobj: (get(fd: fd, capability: capSyncobj) ?? 0) != 0)
    }
}

/// Session-management ioctls used outside the per-frame path.
enum DrmSession {
    /// Acquire DRM master on `fd` (seat resume). Returns true on success.
    @discardableResult
    static func setMaster(fd: Int32) -> Bool { drmSetMaster(fd) == 0 }

    /// Drop DRM master on `fd` (seat suspend / VT switch). Returns true on success.
    @discardableResult
    static func dropMaster(fd: Int32) -> Bool { drmDropMaster(fd) == 0 }

    /// Import a DMA-BUF fd into a device-local GEM handle (framebuffer creation).
    /// Returns the handle, or nil on failure.
    static func primeFDToHandle(fd: Int32, dmabufFd: Int32) -> UInt32? {
        var handle: UInt32 = 0
        return drmPrimeFDToHandle(fd, dmabufFd, &handle) == 0 ? handle : nil
    }

    /// Close a GEM buffer handle.
    @discardableResult
    static func closeBufferHandle(fd: Int32, handle: UInt32) -> Bool {
        drmCloseBufferHandle(fd, handle) == 0
    }
}
