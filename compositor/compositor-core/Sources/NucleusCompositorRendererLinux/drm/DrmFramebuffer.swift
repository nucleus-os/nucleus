// A KMS framebuffer id is created from a buffer object's plane handles and
// removed with `drmModeRmFB`. `DrmFramebuffer` makes that pairing a Swift
// ownership invariant: the fb id is removed exactly once on `deinit`.
// `release()` hands the raw id to the atomic-commit path without removing it.
// The Swift renderer creates the composited framebuffer and Swift
// borrows the id for the atomic commit. The fb id is a lightweight kernel handle
// over a BO; this owner borrows the DRM fd and never owns the BO behind the fb.

import NucleusCompositorDrmC

/// Owns a KMS framebuffer id, removing it on teardown. Borrows the DRM device fd
/// (the `DrmDeviceFd` remains its sole owner) and does not own the underlying BO.
struct DrmFramebuffer: ~Copyable {
    static let explicitModifierFlags = UInt32(DRM_MODE_FB_MODIFIERS)

    let deviceFd: Int32
    private(set) var fbId: UInt32
    let width: UInt32
    let height: UInt32
    let pixelFormat: UInt32

    /// Create a framebuffer with explicit per-plane modifiers (the modern
    /// scanout path — `drmModeAddFB2WithModifiers` with the required
    /// `DRM_MODE_FB_MODIFIERS` flag). Up to 4 planes; pass 0 handles
    /// for unused planes. Returns nil on failure.
    init?(
        deviceFd: Int32,
        width: UInt32,
        height: UInt32,
        pixelFormat: UInt32,
        handles: [UInt32],
        pitches: [UInt32],
        offsets: [UInt32],
        modifiers: [UInt64],
        flags: UInt32 = DrmFramebuffer.explicitModifierFlags
    ) {
        let h = DrmFramebuffer.fourPlane(handles)
        let p = DrmFramebuffer.fourPlane(pitches)
        let o = DrmFramebuffer.fourPlane(offsets)
        let m = DrmFramebuffer.fourPlane64(modifiers)
        var id: UInt32 = 0
        // libdrm takes `const uint32_t[4]` / `const uint64_t[4]`; a Swift array
        // converts to the element pointer for the call.
        let rc = drmModeAddFB2WithModifiers(
            deviceFd, width, height, pixelFormat, h, p, o, m, &id, flags)
        guard rc == 0, id != 0 else { return nil }
        self.deviceFd = deviceFd
        self.fbId = id
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
    }

    /// Create a framebuffer without modifiers (`drmModeAddFB2`), for buffers
    /// whose modifier is implicit/linear. Returns nil on failure.
    init?(
        deviceFd: Int32,
        width: UInt32,
        height: UInt32,
        pixelFormat: UInt32,
        handles: [UInt32],
        pitches: [UInt32],
        offsets: [UInt32],
        flags: UInt32 = 0
    ) {
        let h = DrmFramebuffer.fourPlane(handles)
        let p = DrmFramebuffer.fourPlane(pitches)
        let o = DrmFramebuffer.fourPlane(offsets)
        var id: UInt32 = 0
        let rc = drmModeAddFB2(deviceFd, width, height, pixelFormat, h, p, o, &id, flags)
        guard rc == 0, id != 0 else { return nil }
        self.deviceFd = deviceFd
        self.fbId = id
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
    }

    var isValid: Bool { fbId != 0 }

    /// Relinquish the fb id without removing it. The renderer keeps the BO and
    /// framebuffer lifetime; Swift only borrows the id for the atomic commit.
    consuming func release() -> UInt32 {
        let taken = fbId
        discard self
        return taken
    }

    deinit {
        _ = drmModeRmFB(deviceFd, fbId)
    }

    /// Pad/truncate to libdrm's fixed 4-plane array.
    private static func fourPlane(_ values: [UInt32]) -> [UInt32] {
        (0..<4).map { $0 < values.count ? values[$0] : 0 }
    }

    private static func fourPlane64(_ values: [UInt64]) -> [UInt64] {
        (0..<4).map { $0 < values.count ? values[$0] : 0 }
    }
}
