// The render/DRM execution driver. Router protocol delegates call the Swift
// `RenderBridge`, which owns the live renderer/runtime integration.
//
// Isolation: libwayland invokes request handlers on the compositor's single
// main-actor thread, so each
// conformance method is `nonisolated` and re-enters the actor with
// `MainActor.assumeIsolated`, crossing only Sendable tokens (the output's u64
// DisplayID, plain value arrays).

import WaylandServerC
import WaylandServer
import NucleusCompositorServer
import Glibc

@MainActor
final class RouterRenderDriver {
    init() {}
}

// wp_presentation: advertise the renderer-selected normalized clock domain.
extension RouterRenderDriver: PresentationDelegate {
    nonisolated var presentationClockId: UInt32 {
        MainActor.assumeIsolated { RenderBridge.presentationClockID() }
    }
}

extension RouterRenderDriver: GammaControlDelegate {
    nonisolated func gammaRampSize(output: WlOutput?) -> UInt32 {
        let outputID = output?.outputId ?? 0
        return MainActor.assumeIsolated {
            RenderBridge.gammaRampSize(outputID: outputID)
        }
    }

    nonisolated func gammaApply(
        output: WlOutput?,
        red: [UInt16],
        green: [UInt16],
        blue: [UInt16]
    ) {
        let outputID = output?.outputId ?? 0
        MainActor.assumeIsolated {
            if RenderBridge.applyGamma(
                outputID: outputID,
                red: red,
                green: green,
                blue: blue)
            {
                RenderBridge.requestFrame(
                    outputId: outputID,
                    reason: .outputChange)
            }
        }
    }

    nonisolated func gammaClear(output: WlOutput?) {
        let outputID = output?.outputId ?? 0
        MainActor.assumeIsolated {
            RenderBridge.clearGamma(outputID: outputID)
            RenderBridge.requestFrame(
                outputId: outputID,
                reason: .outputChange)
        }
    }
}

// zwp_linux_dmabuf: advertise the GPU's importable format/modifier table + the
// render-node device. Creation probes the real Vulkan import path synchronously;
// commit-time import still handles device loss and allocation failure.
extension RouterRenderDriver: DmabufDelegate {
    nonisolated func dmabufSupportedFormats() -> [DmabufFormat] {
        MainActor.assumeIsolated { RenderBridge.dmabufSupportedFormats() }
    }

    nonisolated func dmabufMainDevice() -> UInt64 {
        MainActor.assumeIsolated { RenderBridge.dmabufMainDevice() }
    }

    nonisolated func dmabufImport(_ attrs: DmabufAttrs) -> Bool {
        guard let snapshot = DmabufProbeSnapshot(attrs) else { return false }
        return MainActor.assumeIsolated {
            RenderBridge.probeDmabuf(snapshot)
        }
    }
}

// wp_linux_drm_syncobj: import a client timeline fd into a renderer-owned kernel
// handle. Per-commit acquire/release points latch onto the surface aux state in
// Syncobj.swift, then travel with the committed DMABUF upload to the renderer.
extension RouterRenderDriver: DrmSyncobjDelegate {
    nonisolated func importSyncobjTimeline(fd: Int32) -> UInt32? {
        MainActor.assumeIsolated { RenderBridge.syncobjImportTimeline(fd: fd) }
    }

    nonisolated func destroySyncobjTimeline(handle: UInt32) {
        MainActor.assumeIsolated { RenderBridge.syncobjDestroyTimeline(handle: handle) }
    }

}

extension ScreencopyResult {
    /// The capture-failed sentinel — the router sends `failed` to the client.
    static var failed: ScreencopyResult { .init(ok: false, tvSecHi: 0, tvSecLo: 0, tvNsec: 0, flags: 0) }
}

// zwlr_screencopy: advertise an output's capturable buffer, then copy the
// composited accumulator into the client's wl_buffer. The bound wl_output resolves
// to its live DRM output by the DisplayID it carries (WlOutput.info.outputId); the
// client buffer (shm, or the router's own DmabufBuffer) is resolved here and handed
// across as plain values, so no transport type crosses the `@c` boundary. A copy
// queues its target output and runs only from that output's accepted-submission
// callback, when the accumulator contains the newly produced frame.
extension RouterRenderDriver: ScreencopyDelegate {
    nonisolated func screencopyParams(output: WlOutput?, region: WlRect?) -> ScreencopyParams? {
        guard let id = output?.info.outputId, id != 0 else { return nil }
        return MainActor.assumeIsolated {
            guard var p = RenderBridge.screencopyParams(outputId: id) else { return nil }
            // A region capture advertises the clipped rect; otherwise the
            // full-output params stand. The requested region is clipped to the
            // output's extents (spec: "clipped to the output's extents") so a client
            // cannot force an oversized allocation or an out-of-bounds read — the
            // full-output dimensions are `p.width`/`p.height` before this override.
            if let region {
                let outW = Int32(bitPattern: p.width)
                let outH = Int32(bitPattern: p.height)
                let x = min(max(0, region.x), outW)
                let y = min(max(0, region.y), outH)
                let w = max(0, min(region.width, outW - x))
                let h = max(0, min(region.height, outH - y))
                p.width = UInt32(w)
                p.height = UInt32(h)
                p.stride = p.width * 4
            }
            return p
        }
    }

    nonisolated func screencopyRequestFrame(output: WlOutput?) {
        let outputID = output?.outputId ?? 0
        MainActor.assumeIsolated {
            RenderBridge.requestFrame(
                outputId: outputID, reason: .screencopy)
        }
    }

    nonisolated func screencopyCapture(
        output: WlOutput?, region: WlRect?, overlayCursor: Bool,
        buffer: UnsafeMutablePointer<wl_resource>, withDamage _: Bool
    ) -> ScreencopyResult {
        guard let id = output?.info.outputId, id != 0 else { return .failed }
        let bufferBits = UInt(bitPattern: buffer)
        return MainActor.assumeIsolated {
            self.captureImpl(
                outputId: id, region: region,
                overlayCursor: overlayCursor, bufferBits: bufferBits)
        }
    }

    /// Resolve the client wl_buffer (shm via libwayland, dmabuf via the router's
    /// DmabufBuffer) and copy the accumulator region into it. A nil region captures
    /// the whole output. Runs on the main actor (libwayland resource access).
    private func captureImpl(
        outputId: UInt64, region: WlRect?, overlayCursor: Bool, bufferBits: UInt
    ) -> ScreencopyResult {
        guard let buffer = UnsafeMutablePointer<wl_resource>(bitPattern: bufferBits) else { return .failed }

        // dmabuf target: blit the composited frame straight into the client buffer on the
        // GPU (no CPU round-trip), sampling either the whole accumulator or the
        // requested clipped source region into the client-sized target.
        if let dmabuf = WaylandResource.owner(of: buffer, as: DmabufBuffer.self) {
            let attrs = dmabuf.attrs
            var sx: Int32 = 0, sy: Int32 = 0, sw: Int32 = 0, sh: Int32 = 0
            if let region,
               let display = NucleusCompositorServer.shared.layout.display(id: outputId) {
                let outW = Int32(bitPattern: display.pixelSize.width)
                let outH = Int32(bitPattern: display.pixelSize.height)
                sx = min(max(0, region.x), outW)
                sy = min(max(0, region.y), outH)
                sw = max(0, min(region.width, outW - sx))
                sh = max(0, min(region.height, outH - sy))
            }
            let fds = attrs.planes.map { $0.fd }
            let offsets = attrs.planes.map { $0.offset }
            let strides = attrs.planes.map { $0.stride }
            guard !fds.isEmpty else { return .failed }
            let ok = fds.withUnsafeBufferPointer { fp in
                offsets.withUnsafeBufferPointer { op in
                    strides.withUnsafeBufferPointer { sp in
                        RenderBridge.screencopyCaptureDmabuf(
                            outputId: outputId,
                            width: UInt32(bitPattern: attrs.width), height: UInt32(bitPattern: attrs.height),
                            drmFormat: attrs.format, modifier: attrs.modifier, nPlanes: UInt32(fds.count),
                            fds: fp.baseAddress!, offsets: op.baseAddress!, strides: sp.baseAddress!,
                            sourceX: sx, sourceY: sy, sourceWidth: sw, sourceHeight: sh,
                            overlayCursor: overlayCursor)
                    }
                }
            }
            return ok ? Self.captureResult() : .failed
        }

        // SHM target: read the composited frame back (whole output, BGRA8888 = the wl_shm
        // XRGB8888 byte order — the block forces composition so this is current content),
        // then copy the requested region into the client buffer.
        guard let shm = wl_shm_buffer_get(buffer) else { return .failed }
        guard var capture = RenderBridge.screencopyCapture(outputId: outputId) else { return .failed }
        if overlayCursor {
            Self.compositeCursor(into: &capture.pixels, outputId: outputId,
                                 width: capture.width, height: capture.height)
        }
        let outW = capture.width
        let outH = capture.height
        guard outW > 0, outH > 0, capture.pixels.count >= outW * outH * 4 else { return .failed }

        // The region within the output, clipped to its extents (matching the advertised
        // params); a nil region is the whole output.
        let rx = Int(min(max(0, region?.x ?? 0), Int32(outW)))
        let ry = Int(min(max(0, region?.y ?? 0), Int32(outH)))
        let rw = region.map { Int(max(0, min($0.width, Int32(outW) - Int32(rx)))) } ?? outW
        let rh = region.map { Int(max(0, min($0.height, Int32(outH) - Int32(ry)))) } ?? outH

        wl_shm_buffer_begin_access(shm)
        defer { wl_shm_buffer_end_access(shm) }
        guard let dst = wl_shm_buffer_get_data(shm) else { return .failed }
        let dstStride = Int(wl_shm_buffer_get_stride(shm))
        let dstH = Int(wl_shm_buffer_get_height(shm))
        let copyW = min(rw, Int(wl_shm_buffer_get_width(shm)))
        let copyH = min(rh, dstH)
        guard copyW > 0, copyH > 0 else { return .failed }
        let rowBytes = copyW * 4
        let dstCount = dstStride * dstH
        capture.pixels.withUnsafeBytes { src in
            guard let srcBase = src.baseAddress else { return }
            for row in 0..<copyH {
                let srcOff = ((ry + row) * outW + rx) * 4
                let dstOff = row * dstStride
                guard srcOff + rowBytes <= src.count, dstOff + rowBytes <= dstCount else { break }
                dst.advanced(by: dstOff).copyMemory(from: srcBase.advanced(by: srcOff), byteCount: rowBytes)
            }
        }
        return Self.captureResult()
    }

    private static func compositeCursor(
        into pixels: inout [UInt8], outputId: UInt64, width: Int, height: Int
    ) {
        let server = NucleusCompositorServer.shared
        guard let output = server.layout.display(id: outputId) else { return }
        let cursor = server.cursor
        let cw = Int(cursor.width), ch = Int(cursor.height)
        guard cw > 0, ch > 0, cursor.pixels.count >= cw * ch * 4 else { return }
        let scale = output.fractionalScale
        let originX = Int(((server.events.cursorX - output.logicalRect.x) * scale).rounded())
            - Int(cursor.hotSpotX)
        let originY = Int(((server.events.cursorY - output.logicalRect.y) * scale).rounded())
            - Int(cursor.hotSpotY)
        for cy in 0..<ch {
            let dy = originY + cy
            guard dy >= 0, dy < height else { continue }
            for cx in 0..<cw {
                let dx = originX + cx
                guard dx >= 0, dx < width else { continue }
                let si = (cy * cw + cx) * 4
                let di = (dy * width + dx) * 4
                let a = UInt32(cursor.pixels[si + 3])
                if a == 0 { continue }
                let inv = 255 - a
                for channel in 0..<3 {
                    let source = UInt32(cursor.pixels[si + channel])
                    let destination = UInt32(pixels[di + channel])
                    // Wayland ARGB8888 cursor pixels are premultiplied.
                    pixels[di + channel] = UInt8(min(255, source + (destination * inv + 127) / 255))
                }
                pixels[di + 3] = 255
            }
        }
    }

    /// A successful capture's result with a monotonic timestamp. Top-down readback, so
    /// no y_invert flag.
    private static func captureResult() -> ScreencopyResult {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        let sec = UInt64(ts.tv_sec)
        return ScreencopyResult(
            ok: true,
            tvSecHi: UInt32(truncatingIfNeeded: sec >> 32),
            tvSecLo: UInt32(truncatingIfNeeded: sec),
            tvNsec: UInt32(truncatingIfNeeded: ts.tv_nsec),
            flags: 0)
    }
}
