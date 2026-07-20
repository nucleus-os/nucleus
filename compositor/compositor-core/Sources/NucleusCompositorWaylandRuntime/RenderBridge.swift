// The render-execution bridge: the Swift side of the narrow render-runtime
// crossings the runtime drivers call to turn a committed client buffer into GPU
// content the compositor scene samples.
//
// The Swift `WlSurface` owns the per-surface render-state (the IOSurface id);
// these crossings are the *execution* it drives — the GPU upload + the IOSurface
// registry. The layer-content publish is NOT here: it goes Swift→Swift through
// the scene feeder to the author, which owns the surface→layer mapping.
// Surface upload, IOSurface release, dmabuf format queries, and syncobj timeline
// import are Swift render-runtime calls and do not take the loop host handle.
// Frame requests mutate the Swift display links directly; screencopy params read
// the Swift display layout's pixel size — neither crosses the `@c` boundary.
//
// The render runtime (`NucleusCompositorRenderRuntime`) owns these GPU entries; the area DAG
// keeps this substrate module from importing it, so the composition root installs a
// `RenderUploadSink` (closures) into `NucleusCompositorServer.shared.renderUpload` at bring-up
// and the wrappers below call through it (inert before install).

import NucleusCompositorServer
import Glibc

// MARK: - Swift-facing wrapper (host-handle resolution + nil-safety)

/// Main-actor wrapper over render-runtime and surviving display-registry entries.
/// The compositor runs single-threaded on the main actor, so these calls are made
/// from the router's dispatch on that same thread.
@MainActor
enum RenderBridge {
    /// Upload a client SHM buffer to a GPU texture bound to the surface's IOSurface.
    /// Returns the stable IOSurfaceID, or zero on no-runtime/failure.
    static func uploadShm(
        prevIosurfaceId: UInt32, width: UInt32, height: UInt32,
        drmFormat: UInt32, stride: UInt32, pixels: UnsafePointer<UInt8>) -> UInt32 {
        guard let sink = NucleusCompositorServer.shared.renderUpload else { return 0 }
        return sink.uploadShm(prevIosurfaceId, width, height, drmFormat, stride, pixels)
    }

    /// Import a client DMA-BUF to a GPU texture bound to the surface's IOSurface.
    /// `fds`/`offsets`/`strides` are `nPlanes`-long; `acquireFenceFd` is consumed
    /// by the import (or -1). Returns the IOSurfaceID, or zero on failure.
    static func uploadDmabuf(
        prevIosurfaceId: UInt32, width: UInt32, height: UInt32,
        drmFormat: UInt32, drmModifier: UInt64, nPlanes: UInt32,
        fds: UnsafePointer<Int32>, offsets: UnsafePointer<UInt32>,
        strides: UnsafePointer<UInt32>, acquireFenceFd: Int32,
        acquire: SyncPoint?, release: SyncPoint?) -> UInt32 {
        guard let sink = NucleusCompositorServer.shared.renderUpload else { return 0 }
        return sink.uploadDmabuf(
            prevIosurfaceId, width, height, drmFormat, drmModifier,
            nPlanes, fds, offsets, strides, acquireFenceFd,
            acquire?.handle ?? 0, acquire?.point ?? 0,
            release?.handle ?? 0, release?.point ?? 0)
    }

    /// Drop the IOSurface identity `id` at surface teardown.
    static func releaseIosurface(_ id: UInt32) {
        guard id != 0 else { return }
        NucleusCompositorServer.shared.renderUpload?.iosurfaceRelease(id)
    }

    /// Arm a hardware frame for `outputId` (0 = every output) after a router surface
    /// commits content, so the new content composites and pending frame callbacks
    /// complete — the router-driven analog of the substrate `requestFrameForSurface`.
    static func requestFrame(
        outputId: UInt64,
        reason: RedrawReasons = .surfaceDamage
    ) {
        let layout = NucleusCompositorServer.shared.layout
        if outputId != 0 {
            guard let display = layout.display(id: outputId)
            else { return }
            NucleusCompositorServer.shared.renderUpload?
                .forcePresent(outputId)
            display.requestRedraw(reason)
            return
        }
        for display in layout.displays {
            NucleusCompositorServer.shared.renderUpload?
                .forcePresent(display.id)
            display.requestRedraw(reason)
        }
    }

    /// Queue the outputs touched by a model window's current frame and, for a
    /// geometry transition, its previous frame. Including both rectangles clears
    /// the vacated pixels while avoiding an all-output redraw for moves, maps,
    /// unmaps, stacking changes, and Xwayland ConfigureNotify traffic.
    static func requestFrame(
        forWindowID windowID: UInt64,
        includingPreviousRect previousRect: WindowRect? = nil,
        reason: RedrawReasons = .surfaceDamage
    ) {
        let server = NucleusCompositorServer.shared
        guard let window = server.window(id: windowID)
        else { return }
        let rects = [previousRect, window.currentRect()]
            .compactMap { $0 }
        var outputIDs: Set<DisplayID> = []
        if let outputID = window.currentOutputID {
            outputIDs.insert(outputID)
        }
        for display in server.layout.displays
        where rects.contains(where: {
            intersects($0, display.logicalRect)
        }) {
            outputIDs.insert(display.id)
        }
        guard !outputIDs.isEmpty else { return }
        for outputID in outputIDs {
            requestFrame(outputId: outputID, reason: reason)
        }
    }

    private static func intersects(
        _ window: WindowRect,
        _ output: LogicalRect
    ) -> Bool {
        let right = window.x + Double(window.width)
        let bottom = window.y + Double(window.height)
        return window.x < output.maxX
            && right > output.x
            && window.y < output.maxY
            && bottom > output.y
    }

    /// Queue only outputs intersecting the cursor's old or new bounds. This keeps
    /// pointer motion on one display from authoring every unrelated display while
    /// still updating both sides of a cross-output move.
    static func requestCursorFrame(
        previousX: Double? = nil,
        previousY: Double? = nil
    ) {
        let server = NucleusCompositorServer.shared
        let currentX = server.events.cursorX
        let currentY = server.events.cursorY
        var points = [(currentX, currentY)]
        if let previousX, let previousY,
            previousX != currentX
                || previousY != currentY
        {
            points.append((previousX, previousY))
        }
        let cursor = server.cursor
        for display in server.layout.displays
        where points.contains(where: {
            cursorIntersects(
                display: display, x: $0.0, y: $0.1,
                width: cursor.width,
                height: cursor.height,
                hotspotX: cursor.hotSpotX,
                hotspotY: cursor.hotSpotY)
        }) {
            requestFrame(
                outputId: display.id, reason: .cursor)
        }
    }

    private static func cursorIntersects(
        display: Display,
        x: Double,
        y: Double,
        width: UInt32,
        height: UInt32,
        hotspotX: Int32,
        hotspotY: Int32
    ) -> Bool {
        let output = display.logicalRect
        if width == 0 || height == 0 {
            return x >= output.x && x < output.maxX
                && y >= output.y && y < output.maxY
        }
        let scale = max(0.01, display.fractionalScale)
        let left = x - Double(hotspotX) / scale
        let top = y - Double(hotspotY) / scale
        let right = left + Double(width) / scale
        let bottom = top + Double(height) / scale
        return left < output.maxX
            && right > output.x
            && top < output.maxY
            && bottom > output.y
    }

    /// The importable (DRM fourcc, modifier) pairs for client dmabuf buffers.
    /// Empty before bring-up. The set is small (≤ 3 formats × 128 modifiers), so
    /// a single fixed buffer always holds it.
    static func dmabufSupportedFormats() -> [DmabufFormat] {
        let cap = 512
        var formats = [UInt32](repeating: 0, count: cap)
        var modifiers = [UInt64](repeating: 0, count: cap)
        guard let sink = NucleusCompositorServer.shared.renderUpload else { return [] }
        let total = formats.withUnsafeMutableBufferPointer { fp in
            modifiers.withUnsafeMutableBufferPointer { mp in
                Int(sink.dmabufFormats(fp.baseAddress!, mp.baseAddress!, UInt32(cap)))
            }
        }
        let count = min(total, cap)
        return (0..<count).map { DmabufFormat(format: formats[$0], modifier: modifiers[$0]) }
    }

    /// The render-node dev_t advertised as the dmabuf-feedback main device
    /// (0 before bring-up / if unavailable).
    static func dmabufMainDevice() -> UInt64 {
        NucleusCompositorServer.shared.renderUpload?.dmabufMainDevice() ?? 0
    }

    static func presentationClockID() -> UInt32 {
        NucleusCompositorServer.shared.renderUpload?.presentationClockID()
            ?? UInt32(CLOCK_MONOTONIC)
    }

    static func gammaRampSize(outputID: UInt64) -> UInt32 {
        NucleusCompositorServer.shared.renderUpload?.gammaRampSize(outputID) ?? 0
    }

    static func applyGamma(
        outputID: UInt64,
        red: [UInt16],
        green: [UInt16],
        blue: [UInt16]
    ) -> Bool {
        NucleusCompositorServer.shared.renderUpload?.gammaApply(
            outputID, red, green, blue) ?? false
    }

    static func clearGamma(outputID: UInt64) {
        NucleusCompositorServer.shared.renderUpload?.gammaClear(outputID)
    }

    static func probeDmabuf(_ snapshot: DmabufProbeSnapshot) -> Bool {
        guard let sink = NucleusCompositorServer.shared.renderUpload else {
            return false
        }
        let fds = snapshot.planes.map(\.fd)
        let offsets = snapshot.planes.map(\.offset)
        let strides = snapshot.planes.map(\.stride)
        return fds.withUnsafeBufferPointer { fdBuffer in
            offsets.withUnsafeBufferPointer { offsetBuffer in
                strides.withUnsafeBufferPointer { strideBuffer in
                    sink.dmabufProbe(
                        snapshot.width,
                        snapshot.height,
                        snapshot.format,
                        snapshot.modifier,
                        UInt32(snapshot.planes.count),
                        fdBuffer.baseAddress!,
                        offsetBuffer.baseAddress!,
                        strideBuffer.baseAddress!)
                }
            }
        }
    }

    /// Import a client DRM syncobj timeline fd into a kernel handle, or nil on
    /// failure / before bring-up.
    static func syncobjImportTimeline(fd: Int32) -> UInt32? {
        guard let handle = NucleusCompositorServer.shared.renderUpload?.syncobjImportTimeline(fd) else { return nil }
        return handle != 0 ? handle : nil
    }

    static func syncobjDestroyTimeline(handle: UInt32) {
        guard handle != 0 else { return }
        NucleusCompositorServer.shared.renderUpload?.syncobjDestroyTimeline(handle)
    }

    /// The screencopy buffer params (shm format + dims + stride + DRM fourcc) for
    /// `outputId`, or nil if the output is unknown / has no pixel size yet. Derived
    /// from the Swift display layout's pixel size, advertising the default xrgb8888
    /// scanout format (capture converts at copy time if needed); the Swift render
    /// runtime owns scanout, so there is no separate display registry to consult.
    static func screencopyParams(outputId: UInt64) -> ScreencopyParams? {
        guard let display = NucleusCompositorServer.shared.layout.display(id: outputId) else { return nil }
        let width = display.pixelSize.width
        let height = display.pixelSize.height
        guard width != 0, height != 0 else { return nil }
        // wl_shm.format XRGB8888 = 1; DRM fourcc 'XR24' (0x34325258).
        return ScreencopyParams(
            shmFormat: 1, width: width, height: height,
            stride: width &* 4, drmFourcc: 0x3432_5258)
    }

    /// Read back `outputId`'s composited frame as tightly-packed BGRA8888 (matching the
    /// advertised XRGB8888 shm format) for a screencopy capture. nil if unavailable
    /// (no render runtime installed, or no frame yet).
    static func screencopyCapture(outputId: UInt64) -> (pixels: [UInt8], width: Int, height: Int)? {
        NucleusCompositorServer.shared.renderUpload?.screencopyCapture(outputId)
    }

    static func surfaceReadback(
        iosurfaceId: UInt32
    ) -> (pixels: [UInt8], width: Int, height: Int)? {
        NucleusCompositorServer.shared.renderUpload?.surfaceReadback(iosurfaceId)
    }

    /// Blit `outputId`'s composited frame into a client dmabuf render target. Returns
    /// false if no render runtime is installed or the blit fails. Plane arrays are
    /// `nPlanes`-long; the fds are borrowed (the import dups).
    static func screencopyCaptureDmabuf(
        outputId: UInt64, width: UInt32, height: UInt32, drmFormat: UInt32, modifier: UInt64,
        nPlanes: UInt32, fds: UnsafePointer<Int32>, offsets: UnsafePointer<UInt32>,
        strides: UnsafePointer<UInt32>, sourceX: Int32, sourceY: Int32,
        sourceWidth: Int32, sourceHeight: Int32, overlayCursor: Bool
    ) -> Bool {
        NucleusCompositorServer.shared.renderUpload?.screencopyCaptureDmabuf(
            outputId, width, height, drmFormat, modifier, nPlanes, fds, offsets, strides,
            sourceX, sourceY, sourceWidth, sourceHeight, overlayCursor) ?? false
    }

}
