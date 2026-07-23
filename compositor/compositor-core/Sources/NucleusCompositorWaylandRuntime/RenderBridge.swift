// The render-execution bridge: the Swift side of the narrow render-runtime
// crossings the runtime drivers call to turn a committed client buffer into GPU
// content the compositor scene samples.
//
// The Swift `WlSurface` owns the per-surface render-state (the IOSurface id);
// these crossings are the *execution* it drives — the GPU upload + the IOSurface
// registry. The layer-content publish is NOT here: it goes Swift→Swift through
// the scene feeder to the author, which owns the surface→layer mapping.
// GPU operations call the typed `CompositorRenderService` directly. This bridge
// retains only compositor-owned output intersection, redraw, and screencopy
// parameter policy.

internal import NucleusCompositorServer
import NucleusCompositorServerTypes

@MainActor
enum RenderBridge {
    /// Arm a hardware frame for `outputId` (0 = every output) after a router surface
    /// commits content, so the new content composites and pending frame callbacks
    /// complete — the router-driven analog of the substrate `requestFrameForSurface`.
    static func requestFrame(
        server: NucleusCompositorServer,
        outputId: UInt64,
        reason: RedrawReasons = .surfaceDamage
    ) {
        let layout = server.layout
        if outputId != 0 {
            guard let display = layout.display(id: outputId)
            else { return }
            server.renderService?
                .forcePresent(outputID: outputId)
            display.requestRedraw(reason)
            return
        }
        for display in layout.displays {
            server.renderService?
                .forcePresent(outputID: display.id)
            display.requestRedraw(reason)
        }
    }

    /// Queue the outputs touched by a model window's current frame and, for a
    /// geometry transition, its previous frame. Including both rectangles clears
    /// the vacated pixels while avoiding an all-output redraw for moves, maps,
    /// unmaps, stacking changes, and Xwayland ConfigureNotify traffic.
    static func requestFrame(
        server: NucleusCompositorServer,
        forWindowID windowID: UInt64,
        includingPreviousRect previousRect: WindowRect? = nil,
        reason: RedrawReasons = .surfaceDamage
    ) {
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
            requestFrame(server: server, outputId: outputID, reason: reason)
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
        server: NucleusCompositorServer,
        previousX: Double? = nil,
        previousY: Double? = nil
    ) {
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
                server: server, outputId: display.id, reason: .cursor)
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

    /// The screencopy buffer params (shm format + dims + stride + DRM fourcc) for
    /// `outputId`, or nil if the output is unknown / has no pixel size yet. Derived
    /// from the Swift display layout's pixel size, advertising the default xrgb8888
    /// scanout format (capture converts at copy time if needed); the Swift render
    /// runtime owns scanout, so there is no separate display registry to consult.
    static func screencopyParams(
        server: NucleusCompositorServer,
        outputId: UInt64
    ) -> ScreencopyParams? {
        guard let display = server.layout.display(id: outputId) else { return nil }
        let width = display.pixelSize.width
        let height = display.pixelSize.height
        let stride = width.multipliedReportingOverflow(by: 4)
        guard width != 0,
              height != 0,
              Int32(exactly: width) != nil,
              Int32(exactly: height) != nil,
              !stride.overflow
        else { return nil }
        // wl_shm.format XRGB8888 = 1; DRM fourcc 'XR24' (0x34325258).
        return ScreencopyParams(
            shmFormat: 1, width: width, height: height,
            stride: stride.partialValue, drmFourcc: 0x3432_5258)
    }

}
