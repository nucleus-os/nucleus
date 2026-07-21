// wl_pointer.set_cursor — client-provided cursor surfaces.
//
// A client names a wl_surface as its cursor (plus a hotspot); the surface's committed
// buffer is the cursor image, updated on every commit (animated cursors). The
// compositor reads the surface's pixels and feeds them to the global cursor model,
// which drives the hardware cursor plane (the same path the theme/shape cursors use).
// SHM cursor buffers are copied directly. Imported dmabuf cursor buffers are read back
// through the renderer's registered-texture seam.
//
// The binding is tied to pointer focus: the focused client owns the cursor, so when
// focus leaves (InputDispatch restores the default), the binding is cleared and later
// commits from the now-unfocused surface no longer touch the cursor.

import WaylandServerC
import WaylandServer
import NucleusCompositorServer
import Glibc

/// The current client cursor-surface binding (the focused client's `set_cursor`).
/// Main-actor: set/read on the single compositor thread.
@MainActor
final class PointerCursorSurface {
    private unowned let server: NucleusCompositorServer
    /// The wire id of the surface acting as the cursor, or 0 when none is bound.
    private(set) var surfaceId: UInt32 = 0
    private(set) var hotspotX: Int32 = 0
    private(set) var hotspotY: Int32 = 0
    private var pendingCaptureID: UInt64?
    private var captureGeneration: UInt64 = 0

    init(server: NucleusCompositorServer) {
        self.server = server
    }

    func bind(surfaceId: UInt32, hotspotX: Int32, hotspotY: Int32) {
        cancelPendingCapture()
        self.surfaceId = surfaceId
        self.hotspotX = hotspotX
        self.hotspotY = hotspotY
    }

    /// Clear the binding (nil surface, or focus left the client). Does not itself change
    /// the cursor image — the caller applies the default/hidden cursor.
    func clear() {
        cancelPendingCapture()
        surfaceId = 0
    }

    func unbind(surfaceID: UInt32) {
        if surfaceId == surfaceID { clear() }
    }

    /// `wl_surface.offset` moves the cursor surface relative to its previous
    /// buffer, so the hotspot moves by the inverse delta on the same commit.
    func applyCommittedOffset(
        surfaceID: UInt32,
        x: Int32,
        y: Int32
    ) {
        guard surfaceId == surfaceID else { return }
        hotspotX = Int32(clamping: Int64(hotspotX) - Int64(x))
        hotspotY = Int32(clamping: Int64(hotspotY) - Int64(y))
    }

    @discardableResult
    func reapplyCurrent(from compositor: WlCompositor) -> Bool {
        guard surfaceId != 0, let surface = compositor.surface(id: surfaceId) else { return false }
        applyCommittedImage(surface)
        return true
    }

    /// Realize surface `surfaceId`'s committed SHM buffer as the cursor image with the
    /// bound hotspot. No-op if it is not the bound cursor surface, has no SHM buffer, or
    /// the format is not a 32-bit ARGB/XRGB variant.
    func applyCommittedImage(_ surface: WlSurface) {
        guard surface.objectId == surfaceId, surfaceId != 0 else { return }
        cancelPendingCapture()
        if let buffer = surface.currentBuffer, let shm = Self.cursorImageFromShm(buffer) {
            surface.releaseCurrentBufferImmediately()
            server.cursor.setImage(
                pixels: shm.pixels,
                width: shm.width,
                height: shm.height,
                hotSpotX: hotspotX,
                hotSpotY: hotspotY)
            return
        }
        let iosurfaceID = surface.renderIosurfaceId
        guard iosurfaceID != 0,
              let service = server.renderService
        else { return }
        let generation = captureGeneration
        pendingCaptureID = service.beginReadSurface(
            iosurfaceID: iosurfaceID
        ) { [weak self, weak surface] capture in
            guard let self, generation == self.captureGeneration else { return }
            self.pendingCaptureID = nil
            guard let surface,
                  surface.objectId == self.surfaceId,
                  surface.renderIosurfaceId == iosurfaceID,
                  let capture,
                  let width = UInt32(exactly: capture.width),
                  let height = UInt32(exactly: capture.height)
            else { return }
            self.server.cursor.setImage(
                pixels: capture.pixels,
                width: width,
                height: height,
                hotSpotX: self.hotspotX,
                hotSpotY: self.hotspotY)
            RenderBridge.requestCursorFrame(server: self.server)
        }
    }

    private func cancelPendingCapture() {
        captureGeneration &+= 1
        precondition(captureGeneration != 0, "cursor capture generation exhausted")
        if let pendingCaptureID {
            server.renderService?
                .cancelCapture(pendingCaptureID)
            self.pendingCaptureID = nil
        }
    }

    /// Read an SHM buffer into tightly-packed ARGB8888 pixels. Accepts the 32-bit
    /// ARGB8888 (0) / XRGB8888 (1) wl_shm formats — whose byte order matches the cursor
    /// plane's ARGB8888 — repacking away any stride padding. Returns nil otherwise. The
    /// libwayland access is here; the format gate + repack are the pure, tested units.
    static func cursorImageFromShm(
        _ buffer: UnsafeMutablePointer<wl_resource>
    ) -> (pixels: [UInt8], width: UInt32, height: UInt32)? {
        guard let shm = wl_shm_buffer_get(buffer) else { return nil }
        guard isReadableCursorShmFormat(wl_shm_buffer_get_format(shm)) else { return nil }
        let w = Int(wl_shm_buffer_get_width(shm))
        let h = Int(wl_shm_buffer_get_height(shm))
        let stride = Int(wl_shm_buffer_get_stride(shm))
        guard w > 0, h > 0, stride >= w * 4 else { return nil }

        wl_shm_buffer_begin_access(shm)
        defer { wl_shm_buffer_end_access(shm) }
        guard let data = wl_shm_buffer_get_data(shm) else { return nil }
        let pixels = repackTightARGB(
            source: UnsafeRawBufferPointer(start: data, count: stride * h),
            width: w, height: h, sourceStride: stride)
        return (pixels, UInt32(w), UInt32(h))
    }

    /// Whether a wl_shm format is a 32-bit ARGB/XRGB variant readable as ARGB8888 (the
    /// cursor plane's byte order): ARGB8888 (0) or XRGB8888 (1). Pure — isolation-free.
    nonisolated static func isReadableCursorShmFormat(_ format: UInt32) -> Bool {
        format == 0 || format == 1
    }

    /// Repack a `width`×`height` ARGB8888 source with `sourceStride` bytes per row into a
    /// tightly-packed `width*height*4` buffer, stripping stride padding. Copies one full
    /// `width*4`-byte row per line, clamped to the source length; short/degenerate inputs
    /// yield a zero-filled buffer of the correct size (never over-reads).
    nonisolated static func repackTightARGB(
        source: UnsafeRawBufferPointer, width: Int, height: Int, sourceStride: Int
    ) -> [UInt8] {
        let rowBytes = width * 4
        var out = [UInt8](repeating: 0, count: max(0, rowBytes * height))
        guard width > 0, height > 0, sourceStride >= rowBytes else { return out }
        out.withUnsafeMutableBytes { dst in
            guard let dstBase = dst.baseAddress, let srcBase = source.baseAddress else { return }
            for row in 0..<height {
                let srcOff = row * sourceStride
                guard srcOff + rowBytes <= source.count else { break }
                dstBase.advanced(by: row * rowBytes).copyMemory(
                    from: srcBase.advanced(by: srcOff), byteCount: rowBytes)
            }
        }
        return out
    }
}
