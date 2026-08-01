// The render/DRM execution driver. Router protocol delegates call the Swift
// server's typed render service. `RenderBridge` retains only compositor-owned
// redraw and output-intersection policy.
//
// Libwayland request entry is isolated by the generated dispatch boundary; these
// delegate conformances therefore remain typed and main-actor-isolated throughout.

import Glibc
internal import NucleusCompositorServer
import NucleusCompositorServerTypes
import NucleusLinuxPrimitives
import NucleusRenderModel
import WaylandServer
import WaylandServerC
import WaylandServerDispatch

@MainActor
final class RouterRenderDriver {
    private unowned let server: NucleusCompositorServer

    init(server: NucleusCompositorServer) {
        self.server = server
    }
}

// wp_presentation: advertise the renderer-selected normalized clock domain.
extension RouterRenderDriver: PresentationDelegate {
    var presentationClockId: UInt32 {
        server.renderService?
            .presentationClockID ?? UInt32(CLOCK_MONOTONIC)
    }
}

extension RouterRenderDriver: GammaControlDelegate {
    func gammaRampSize(output: WlOutput?) -> UInt32 {
        let outputID = output?.outputId ?? 0
        return server.renderService?
            .gammaRampSize(outputID: outputID) ?? 0
    }

    func gammaApply(
        output: WlOutput?,
        red: [UInt16],
        green: [UInt16],
        blue: [UInt16]
    ) {
        let outputID = output?.outputId ?? 0
        if server.renderService?.applyGamma(
            RenderGammaRamp(
                outputID: outputID,
                red: red,
                green: green,
                blue: blue)) == true
        {
            RenderBridge.requestFrame(
                server: server,
                outputId: outputID,
                reason: .outputChange)
        }
    }

    func gammaClear(output: WlOutput?) {
        let outputID = output?.outputId ?? 0
        guard let renderService = server.renderService else { return }
        renderService.clearGamma(outputID: outputID)
        RenderBridge.requestFrame(
            server: server,
            outputId: outputID,
            reason: .outputChange)
    }
}

// zwp_linux_dmabuf: advertise the GPU's importable format/modifier table + the
// render-node device. Creation probes the real Vulkan import path synchronously;
// commit-time import still handles device loss and allocation failure.
extension RouterRenderDriver: DmabufDelegate {
    func dmabufSupportedFormats() -> [DmabufFormat] {
        server.renderService?
            .dmabufFormats()
            .map {
                DmabufFormat(
                    format: $0.format,
                    modifier: $0.modifier)
            } ?? []
    }

    func dmabufMainDevice() -> UInt64 {
        server.renderService?
            .dmabufMainDevice ?? 0
    }

    func dmabufImport(_ attrs: DmabufAttrs) -> Bool {
        guard let snapshot = DmabufProbeSnapshot(attrs) else { return false }
        return server.renderService?.probeDmabuf(
            RenderDmabufProbe(
                width: snapshot.width,
                height: snapshot.height,
                drmFormat: snapshot.format,
                modifier: snapshot.modifier,
                planes: snapshot.planes.map {
                    RenderDmabufPlane(
                        fd: $0.fd,
                        offset: $0.offset,
                        stride: $0.stride)
                })) ?? false
    }
}

// wp_linux_drm_syncobj: import a client timeline fd into a renderer-owned kernel
// handle. Per-commit acquire/release points latch onto the surface aux state in
// Syncobj.swift, then travel with the committed DMABUF upload to the renderer.
extension RouterRenderDriver: DrmSyncobjDelegate {
    func importSyncobjTimeline(fd: Int32) -> UInt32? {
        server.renderService?
            .importSyncobjTimeline(fd: fd)
    }

    func destroySyncobjTimeline(handle: UInt32) {
        server.renderService?
            .destroySyncobjTimeline(handle: handle)
    }

}

extension ScreencopyResult {
    /// The capture-failed sentinel — the router sends `failed` to the client.
    static var failed: ScreencopyResult {
        .init(ok: false, tvSecHi: 0, tvSecLo: 0, tvNsec: 0, flags: 0)
    }
}

// zwlr_screencopy: advertise an output's capturable buffer, then copy the
// composited accumulator into the client's wl_buffer. The bound wl_output resolves
// to its live DRM output by the DisplayID it carries (WlOutput.info.outputId); the
// client buffer (shm, or the router's own DmabufBuffer) is resolved here and handed
// across as plain values, so no transport type crosses the render-service seam. A copy
// queues its target output and runs only from that output's accepted-submission
// callback, when the accumulator contains the newly produced frame.
extension RouterRenderDriver: ScreencopyDelegate {
    func screencopyConfiguration(
        output: WlOutput?, region: WlRect?
    ) -> ScreencopyConfiguration? {
        guard let output, output.info.outputId != 0,
            var params = RenderBridge.screencopyParams(
                server: server,
                outputId: output.info.outputId)
        else { return nil }
        guard let region else {
            return ScreencopyConfiguration(
                params: params, sourceRegion: nil)
        }

        // The protocol region is output-local logical geometry. Project its
        // clipped intersection into the actual pixel extent once, then retain
        // that exact source rectangle with the advertised frame parameters.
        let logical = output.logicalRect
        guard
            let projectedX = Self.projectCaptureAxis(
                origin: region.x,
                length: region.width,
                logicalExtent: logical.width,
                pixelExtent: params.width),
            let projectedY = Self.projectCaptureAxis(
                origin: region.y,
                length: region.height,
                logicalExtent: logical.height,
                pixelExtent: params.height)
        else { return nil }
        let sourceRegion = WlRect(
            x: projectedX.origin,
            y: projectedY.origin,
            width: projectedX.length,
            height: projectedY.length)
        params.width = UInt32(projectedX.length)
        params.height = UInt32(projectedY.length)
        let stride = params.width.multipliedReportingOverflow(by: 4)
        guard !stride.overflow else { return nil }
        params.stride = stride.partialValue
        return ScreencopyConfiguration(
            params: params,
            sourceRegion: sourceRegion)
    }

    static func projectCaptureAxis(
        origin: Int32,
        length: Int32,
        logicalExtent: Int32,
        pixelExtent: UInt32
    ) -> (origin: Int32, length: Int32)? {
        guard length > 0,
            logicalExtent > 0,
            let pixelExtent = Int32(exactly: pixelExtent)
        else { return nil }
        let requestedStart = Int64(origin)
        let requestedEnd = requestedStart + Int64(length)
        let logicalExtent64 = Int64(logicalExtent)
        let clippedStart = min(max(0, requestedStart), logicalExtent64)
        let clippedEnd = min(max(0, requestedEnd), logicalExtent64)
        guard clippedEnd > clippedStart else { return nil }

        let pixelExtent64 = Int64(pixelExtent)
        let startProduct = clippedStart * pixelExtent64
        let endProduct = clippedEnd * pixelExtent64
        let pixelStart = startProduct / logicalExtent64
        var pixelEnd = endProduct / logicalExtent64
        if endProduct % logicalExtent64 != 0 { pixelEnd += 1 }
        guard pixelEnd > pixelStart,
            let projectedStart = Int32(exactly: pixelStart),
            let projectedLength = Int32(exactly: pixelEnd - pixelStart)
        else { return nil }
        return (projectedStart, projectedLength)
    }

    func screencopyRequestFrame(output: WlOutput?) {
        let outputID = output?.outputId ?? 0
        RenderBridge.requestFrame(
            server: server,
            outputId: outputID, reason: .screencopy)
    }

    func screencopyCapture(
        output: WlOutput?, configuration: ScreencopyConfiguration,
        overlayCursor: Bool,
        buffer: WaylandResourceReference<WlBufferServer>,
        withDamage _: Bool,
        preferRegionReadback: Bool,
        completion: @escaping @MainActor (ScreencopyResult) -> Void
    ) -> UInt64? {
        guard let id = output?.info.outputId, id != 0 else { return nil }
        return captureImpl(
            outputId: id, configuration: configuration,
            overlayCursor: overlayCursor,
            preferRegionReadback: preferRegionReadback,
            buffer: buffer,
            completion: completion)
    }

    func screencopyCancelCapture(_ requestID: UInt64) {
        server.renderService?
            .cancelCapture(requestID)
    }

    /// Resolve the client wl_buffer (shm via libwayland, dmabuf via the router's
    /// DmabufBuffer) and copy the accumulator region into it. A nil region captures
    /// the whole output. Runs on the main actor (libwayland resource access).
    private func captureImpl(
        outputId: UInt64,
        configuration: ScreencopyConfiguration,
        overlayCursor: Bool,
        preferRegionReadback: Bool,
        buffer: WaylandResourceReference<WlBufferServer>,
        completion: @escaping @MainActor (ScreencopyResult) -> Void
    ) -> UInt64? {
        guard buffer.isLive else { return nil }
        guard
            let currentParams = RenderBridge.screencopyParams(
                server: server,
                outputId: outputId)
        else { return nil }
        if let source = configuration.sourceRegion {
            let endX = Int64(source.x) + Int64(source.width)
            let endY = Int64(source.y) + Int64(source.height)
            guard source.x >= 0,
                source.y >= 0,
                source.width > 0,
                source.height > 0,
                UInt32(source.width) == configuration.params.width,
                UInt32(source.height) == configuration.params.height,
                endX <= Int64(currentParams.width),
                endY <= Int64(currentParams.height)
            else { return nil }
        } else {
            guard currentParams.width == configuration.params.width,
                currentParams.height == configuration.params.height
            else { return nil }
        }

        // dmabuf target: blit the composited frame straight into the client buffer on the
        // GPU (no CPU round-trip), sampling either the whole accumulator or the
        // requested clipped source region into the client-sized target.
        if let dmabuf = buffer.retainedSemanticOwner(
            as: DmabufBuffer.self)
        {
            let attrs = dmabuf.attrs
            let sourceRegion = configuration.sourceRegion.map {
                RenderCaptureRegion(
                    x: $0.x, y: $0.y,
                    width: $0.width, height: $0.height)
            }
            guard !attrs.planes.isEmpty else { return nil }
            return self.server.renderService?.beginCaptureOutput(
                to: Self.renderDmabufCapture(
                    outputID: outputId,
                    attrs: attrs,
                    sourceRegion: sourceRegion,
                    overlaysCursor: overlayCursor)
            ) { succeeded in
                completion(succeeded ? Self.captureResult() : .failed)
            }
        }

        // SHM target: read the composited frame back (whole output, BGRA8888 = the wl_shm
        // XRGB8888 byte order — the block forces composition so this is current content),
        // then copy the requested region into the client buffer.
        guard buffer.shmMetadata != nil else { return nil }
        let sourceRegion =
            preferRegionReadback
            ? configuration.sourceRegion.map {
                RenderCaptureRegion(
                    x: $0.x, y: $0.y,
                    width: $0.width, height: $0.height)
            }
            : nil
        let server = self.server
        return server.renderService?.beginCaptureOutput(
            outputID: outputId,
            sourceRegion: sourceRegion
        ) { capture in
            guard var capture else {
                completion(.failed)
                return
            }
            if overlayCursor {
                Self.compositeCursor(
                    server: server,
                    into: &capture.pixels,
                    outputId: outputId,
                    width: capture.width,
                    height: capture.height,
                    captureOriginX: capture.originX,
                    captureOriginY: capture.originY)
            }
            let copied = Self.copyCapture(
                capture,
                configuration: configuration,
                toShmResource: buffer)
            completion(copied ? Self.captureResult() : .failed)
        }
    }

    private static func copyCapture(
        _ capture: RenderPixelCapture,
        configuration: ScreencopyConfiguration,
        toShmResource buffer: WaylandResourceReference<WlBufferServer>
    ) -> Bool {
        let outW = capture.width
        let outH = capture.height
        let pixelCount = outW.multipliedReportingOverflow(by: outH)
        let byteCount = pixelCount.partialValue.multipliedReportingOverflow(by: 4)
        guard outW > 0,
            outH > 0,
            !pixelCount.overflow,
            !byteCount.overflow,
            capture.pixels.count >= byteCount.partialValue
        else { return false }

        guard let copyWidth = Int(exactly: configuration.params.width),
            let copyHeight = Int(exactly: configuration.params.height)
        else { return false }
        let sourceRegion =
            configuration.sourceRegion
            ?? WlRect(
                x: 0, y: 0,
                width: Int32(clamping: outW),
                height: Int32(clamping: outH))
        let rx = Int(sourceRegion.x) - capture.originX
        let ry = Int(sourceRegion.y) - capture.originY
        guard rx >= 0,
            ry >= 0,
            Int(sourceRegion.width) == copyWidth,
            Int(sourceRegion.height) == copyHeight,
            rx <= outW - copyWidth,
            ry <= outH - copyHeight
        else { return false }

        return
            (try? buffer.withMutableShmBytes { metadata, destination in
                guard copyWidth == metadata.width,
                    copyHeight == metadata.height,
                    copyWidth > 0,
                    copyHeight > 0,
                    metadata.stride >= copyWidth * 4
                else { return false }
                let rowBytes = copyWidth * 4
                return destination.copyRows(
                    from: capture.pixels,
                    sourceOffset: (ry * outW + rx) * 4,
                    sourceStride: outW * 4,
                    destinationStride: metadata.stride,
                    rowBytes: rowBytes,
                    rowCount: copyHeight)
            }) ?? false
    }

    /// Translate a Wayland-owned destination buffer into the neutral capture
    /// request without losing plane order or confusing crop and cursor fields.
    static func renderDmabufCapture(
        outputID: UInt64,
        attrs: DmabufAttrs,
        sourceRegion: RenderCaptureRegion?,
        overlaysCursor: Bool
    ) -> RenderDmabufCapture {
        RenderDmabufCapture(
            outputID: outputID,
            width: UInt32(bitPattern: attrs.width),
            height: UInt32(bitPattern: attrs.height),
            drmFormat: attrs.format,
            modifier: attrs.modifier,
            planes: attrs.planes.map { plane in
                plane.withBorrowedDescriptor {
                    RenderDmabufPlane(
                        fd: $0.rawValue,
                        offset: plane.offset,
                        stride: plane.stride)
                }
            },
            sourceRegion: sourceRegion,
            overlaysCursor: overlaysCursor)
    }

    private static func compositeCursor(
        server: NucleusCompositorServer,
        into pixels: inout [UInt8], outputId: UInt64, width: Int, height: Int,
        captureOriginX: Int, captureOriginY: Int
    ) {
        guard let output = server.layout.display(id: outputId) else { return }
        let cursor = server.cursor
        let cw = Int(cursor.width)
        let ch = Int(cursor.height)
        guard cw > 0, ch > 0, cursor.pixels.count >= cw * ch * 4 else { return }
        let scale = output.fractionalScale
        let originX =
            Int(((server.events.cursorX - output.logicalRect.x) * scale).rounded())
            - Int(cursor.hotSpotX) - captureOriginX
        let originY =
            Int(((server.events.cursorY - output.logicalRect.y) * scale).rounded())
            - Int(cursor.hotSpotY) - captureOriginY
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
        let now = LinuxMonotonicClock.nowNanoseconds()
        let sec = now / 1_000_000_000
        return ScreencopyResult(
            ok: true,
            tvSecHi: UInt32(truncatingIfNeeded: sec >> 32),
            tvSecLo: UInt32(truncatingIfNeeded: sec),
            tvNsec: UInt32(truncatingIfNeeded: now % 1_000_000_000),
            flags: 0)
    }
}
