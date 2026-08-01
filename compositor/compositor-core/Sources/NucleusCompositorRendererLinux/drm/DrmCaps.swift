// Swift DRM capability discovery + session ioctls over
// real libdrm.
//
// Init-time capability negotiation an output pipeline needs before scanout:
// enabling the universal-planes + atomic client caps, and reading the cursor
// dimensions / ADDFB2-modifiers / syncobj device caps. DRM-master ownership
// belongs exclusively to libseat; renderer code only uses the descriptor while
// the seat is active.

import NucleusCompositorDrmC

/// The device + plane capabilities an output reads at init.
struct DrmCaps: Sendable, Equatable {
    var cursorWidth: UInt64
    var cursorHeight: UInt64
    var addFB2Modifiers: Bool
    var syncobj: Bool
    var timestampMonotonic: Bool
}

enum DrmCapabilities {
    // Device caps (drm.h DRM_CAP_*).
    static let capCursorWidth: UInt64 = 0x8
    static let capCursorHeight: UInt64 = 0x9
    static let capAddFB2Modifiers: UInt64 = 0x10
    static let capSyncobj: UInt64 = 0x13
    static let capTimestampMonotonic: UInt64 = 0x6

    // Client caps (drm.h DRM_CLIENT_CAP_*).
    static let clientCapUniversalPlanes: UInt64 = 1
    static let clientCapAtomic: UInt64 = 3

    /// Read a device capability, or nil if the query failed.
    static func get(fd: Int32, capability: UInt64) -> UInt64? {
        var value: UInt64 = 0
        return unsafe drmGetCap(fd, capability, &value) == 0 ? value : nil
    }

    /// Enable a client capability. Returns true on success.
    @discardableResult
    static func setClientCap(fd: Int32, capability: UInt64, value: UInt64 = 1) -> Bool {
        drmSetClientCap(fd, capability, value) == 0
    }

    /// Enable universal planes then atomic — the order the kernel requires
    /// (atomic implies universal planes). Returns true only if both succeed.
    static func enableAtomicModesetting(fd: Int32) -> Bool {
        setClientCap(fd: fd, capability: clientCapUniversalPlanes)
            && setClientCap(fd: fd, capability: clientCapAtomic)
    }

    /// Read the cursor/modifier/syncobj device caps. Absent caps read as 0/false.
    static func discover(fd: Int32) -> DrmCaps {
        DrmCaps(
            cursorWidth: get(fd: fd, capability: capCursorWidth) ?? 0,
            cursorHeight: get(fd: fd, capability: capCursorHeight) ?? 0,
            addFB2Modifiers: (get(fd: fd, capability: capAddFB2Modifiers) ?? 0) != 0,
            syncobj: (get(fd: fd, capability: capSyncobj) ?? 0) != 0,
            timestampMonotonic: (get(fd: fd, capability: capTimestampMonotonic) ?? 0) != 0)
    }
}
