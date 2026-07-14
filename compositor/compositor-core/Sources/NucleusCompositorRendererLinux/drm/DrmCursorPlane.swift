// Per-output hardware KMS cursor plane.
//
// A GBM cursor BO (ARGB8888, GBM_BO_USE_CURSOR | GBM_BO_USE_WRITE) with a KMS
// framebuffer over it, double-buffered so a cursor-image change never overwrites
// the BO the kernel is still scanning. The image is CPU-uploaded (packed into the
// BO's stride via `packCursorPixels`, written with `gbm_bo_write`), so there is no
// Vulkan import here — this is the light, compositor-owned path, distinct from the
// GPU-rendered scanout ring. The placement math (`cursorPlanePlacement`) and packing
// (`packCursorPixels`) live in DrmColorCursor.swift and are unit-tested; this owns
// the buffers and the KMS objects. `DrmOutput.assembleScanoutCommit` adds the cursor
// plane's atomic state, referencing this plane's `frontFbId` each commit.
//
// Image changes are rare (theme / shape); pointer motion re-places the plane every
// frame but needs no re-upload — the front fb id is stable until the next image.

import NucleusCompositorDrmC

final class DrmCursorPlane {
    private let deviceFd: Int32
    let planeId: UInt32
    let crtcId: UInt32
    let props: CursorPlaneProps
    /// The BO dimensions (the driver's max cursor size, e.g. 64×64). The image is
    /// packed top-left; the rest stays transparent.
    let width: UInt32
    let height: UInt32

    private struct Buffer {
        let bo: OpaquePointer
        let fbId: UInt32
        let stride: UInt32
    }
    private var buffers: [Buffer]
    private var frontIndex = 0
    private(set) var hasImage = false

    private init(
        deviceFd: Int32, planeId: UInt32, crtcId: UInt32, props: CursorPlaneProps,
        width: UInt32, height: UInt32, buffers: [Buffer]
    ) {
        self.deviceFd = deviceFd
        self.planeId = planeId
        self.crtcId = crtcId
        self.props = props
        self.width = width
        self.height = height
        self.buffers = buffers
    }

    /// Allocate a double-buffered cursor plane, or nil if the plane has no discovered
    /// props or any BO/fb allocation fails (the compositor then runs without a hardware
    /// cursor on this output).
    static func create(
        gbmDevice: OpaquePointer, deviceFd: Int32, planeId: UInt32, crtcId: UInt32,
        props: CursorPlaneProps, width: UInt32, height: UInt32
    ) -> DrmCursorPlane? {
        guard planeId != 0, props.fbId != 0, width > 0, height > 0 else { return nil }

        var buffers: [Buffer] = []
        func rollback() {
            for b in buffers { _ = drmModeRmFB(deviceFd, b.fbId); gbm_bo_destroy(b.bo) }
        }

        for _ in 0..<2 {
            guard let bo = gbm_bo_create(
                gbmDevice, width, height, drmFormatARGB8888,
                GBM_BO_USE_CURSOR.rawValue | GBM_BO_USE_WRITE.rawValue
            ) else { rollback(); return nil }

            let handle = gbm_bo_get_handle_for_plane(bo, 0).u32
            let stride = gbm_bo_get_stride(bo)
            guard let fb = DrmFramebuffer(
                deviceFd: deviceFd, width: width, height: height, pixelFormat: drmFormatARGB8888,
                handles: [handle], pitches: [stride], offsets: [0]
            ) else { gbm_bo_destroy(bo); rollback(); return nil }
            buffers.append(Buffer(bo: bo, fbId: fb.release(), stride: stride))
        }

        return DrmCursorPlane(
            deviceFd: deviceFd, planeId: planeId, crtcId: crtcId, props: props,
            width: width, height: height, buffers: buffers)
    }

    /// The framebuffer id the next atomic commit should scan out for the cursor, or 0
    /// until an image has been uploaded (the plane stays cleared).
    var frontFbId: UInt32 { hasImage ? buffers[frontIndex].fbId : 0 }

    /// Upload a new cursor image into the back buffer and swap it to front. `pixels`
    /// is tightly-packed ARGB8888 of `srcWidth × srcHeight`; it is clamped/padded into
    /// the BO's stride by `packCursorPixels`. Writing the back buffer (not the scanned
    /// front) means the swap never tears the currently-displayed cursor.
    func upload(pixels: [UInt8], srcWidth: Int, srcHeight: Int) {
        guard !buffers.isEmpty else { return }
        let backIndex = (frontIndex + 1) % buffers.count
        let back = buffers[backIndex]
        let packed = packCursorPixels(
            source: pixels, sourceWidth: srcWidth, sourceHeight: srcHeight,
            destinationStride: Int(back.stride),
            destinationWidth: Int(width), destinationHeight: Int(height))
        packed.withUnsafeBytes { raw in
            if let base = raw.baseAddress { _ = gbm_bo_write(back.bo, base, raw.count) }
        }
        frontIndex = backIndex
        hasImage = true
    }

    /// Compute this plane's placement for the atomic commit from the live pointer
    /// position, or nil when the pointer is off this output (the plane is cleared). The
    /// BO size is used for src/crtc extent so the whole plane is presented with the
    /// image packed top-left and the theme hotspot applied.
    func placement(
        outputRect: OutputRect, fractionalScale: Double,
        cursorX: Double, cursorY: Double, hotspotX: Int32, hotspotY: Int32
    ) -> CursorPlacement? {
        cursorPlanePlacement(
            rect: outputRect, fractionalScale: fractionalScale,
            cursorX: cursorX, cursorY: cursorY,
            hotspotX: hotspotX, hotspotY: hotspotY,
            width: width, height: height)
    }

    /// Remove the KMS framebuffers and destroy the BOs. Called on output teardown,
    /// BEFORE the GBM device drops, so the kernel stops scanning them first.
    func destroy() {
        for b in buffers { _ = drmModeRmFB(deviceFd, b.fbId); gbm_bo_destroy(b.bo) }
        buffers = []
        hasImage = false
    }
}
