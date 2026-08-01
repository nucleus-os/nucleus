// The surface-import / scene-publish half of the router's window driving, split out
// of RouterWindowDriver (which keeps the xdg-shell configure / window-model adapter).
//
// A wl_surface commit with a newly attached buffer imports it (SHM via
// libwayland's wl_shm_buffer_*, DMA-BUF via the router's DmabufBuffer) through
// the server's typed render service. State-only commits republish the retained content without
// touching client memory. A subsurface/popup composites within its parent's scene,
// a window/root surface publishes to its own backing layer, and a zwlr layer
// surface is authored as its own output-anchored model window from the map commit.
// This concern is nearly state-disjoint from the configure/model half: it never
// touches the toplevel→WindowID table, resolving windows only through the O(1)
// surface-object-id index.
//
// RouterWindowDriver owns an instance of this and forwards its two
// SurfaceSceneDelegate calls here; `WlCompositor.sceneDelegate` stays wired to
// RouterWindowDriver.

import Glibc
internal import NucleusCompositorServer
internal import NucleusCompositorWindowManager
import NucleusDiagnostics
package import NucleusLayers
import NucleusRenderModel
import NucleusTypes
import WaylandServer
import WaylandServerC

@MainActor
final class RouterSurfaceSceneDriver {
    private unowned let host: RouterHost
    private var windowManager: WindowManager { host.windowManager }
    private var server: NucleusCompositorServer { host.server }
    /// Re-resolves surfaces by nominal ID at the model/indexing boundary.
    private let compositor: WlCompositor
    /// Scene author sink: per-commit content publish + layer-surface window authoring.
    /// nil in protocol-only fixtures, where scene publication is intentionally inert.
    private let feeder: SceneFeeder?
    private var reportedImports: Set<UInt32> = []
    private var reportedLayerMaps: Set<UInt32> = []
    private var reportedRootMaps: Set<UInt32> = []

    init(compositor: WlCompositor, feeder: SceneFeeder?, host: RouterHost) {
        self.host = host
        self.compositor = compositor
        self.feeder = feeder
    }

    private func diagnostic(_ message: String) {
        NucleusLogger(subsystem: "surface-scene").warning(message)
    }

    /// Resolve a surface's model window via the O(1) surface-object-id index (never the
    /// toplevel-token table, which the configure/model half owns).
    private func windowID(forSurfaceId id: UInt32) -> WindowID? {
        guard id != 0 else { return nil }
        return server.windows.window(bySurfaceObjectId: id)?.id
    }

    /// Import the committed buffer to the surface's IOSurface and publish it to the
    /// surface's backing scene layer. SHM buffers are read through libwayland's
    /// `wl_shm_buffer_*`; DMA-BUF buffers carry their planes on the router's own
    /// `DmabufBuffer`. The render service swaps the GPU texture with one-frame deferred
    /// release and returns the (stable) IOSurfaceID the surface holds across commits.
    func importCommit(_ commit: SurfaceCommit) {
        let surfaceID = commit.surfaceID
        let surfaceId = surfaceID.rawValue
        guard let surface = compositor.surface(id: surfaceId) else { return }
        // A client cursor surface (wl_pointer.set_cursor): its committed buffer is the
        // cursor image, not window content — route it to the cursor model and stop.
        if surfaceId == host.pointerCursorSurface.surfaceId {
            if commit.bufferAttached {
                host.pointerCursorSurface.applyCommittedImage(
                    surface)
            }
            RenderBridge.requestCursorFrame(server: server)
            return
        }
        if !commit.bufferAttached {
            surface.committedLogicalWidth =
                commit.logicalContentSize.width
            surface.committedLogicalHeight =
                commit.logicalContentSize.height
            if surface.renderIosurfaceId != 0 {
                publishContent(surface, commit: commit)
                requestRedraw(for: surface)
            }
            return
        }
        defer { requestRedraw(for: surface) }
        guard let buffer = commit.buffer, buffer.isLive
        else {
            // Capture before releasing the renderer texture. The role callback
            // that follows this scene commit flips `mapped` off and clears input;
            // this preserves only immutable visual content for the close fade.
            if let windowID = windowID(forSurfaceId: surfaceId),
                let window = server.window(id: windowID),
                window.mapped
            {
                _ = feeder?.beginClosing(
                    window: window,
                    iosurfaceID: surface.renderIosurfaceId,
                    destroyWindowOnCompletion: false)
            }
            if surface.renderIosurfaceId != 0 {
                server.renderService?
                    .releaseIOSurface(surface.renderIosurfaceId)
                surface.renderIosurfaceId = 0
            }
            surface.committedLogicalWidth = 0
            surface.committedLogicalHeight = 0
            feeder?.surfaceContentDetached(surfaceID: surfaceId)
            return
        }

        if buffer.shmMetadata != nil {
            let newId: UInt32 =
                (try? buffer.withShmBytes {
                    metadata, bytes -> UInt32 in
                    guard let renderService = server.renderService
                    else { return UInt32(0) }
                    return unsafe bytes.withUnsafeBytes { rawBytes in
                        guard let data = rawBytes.baseAddress
                        else { return UInt32(0) }
                        let pixels = unsafe Span<UInt8>(
                            _unsafeStart:
                                data.assumingMemoryBound(to: UInt8.self),
                            count: rawBytes.count)
                        return renderService.importShm(
                            previousIOSurfaceID: surface.renderIosurfaceId,
                            width: UInt32(metadata.width),
                            height: UInt32(metadata.height),
                            drmFormat: Self.drmFormat(
                                fromShm: metadata.format),
                            stride: UInt32(metadata.stride),
                            pixels: pixels)
                    }
                }) ?? 0
            guard newId != 0 else {
                importFailed(surface)
                return
            }
            surface.renderIosurfaceId = newId
            surface.didImportContent(generation: commit.bufferGeneration)
            // SHM pixels are copied by uploadShm; neither Vulkan nor KMS retains the
            // client allocation after this call.
            surface.releaseCurrentBufferImmediately()
            if reportedImports.insert(surfaceId).inserted,
                let metadata = buffer.shmMetadata
            {
                diagnostic(
                    "surface=\(surfaceId) shm=\(metadata.width)x\(metadata.height) texture=\(newId) generation=\(surface.renderContentGeneration)"
                )
            }
            if let metadata = buffer.shmMetadata {
                recordBufferSize(
                    surfaceId: surfaceId,
                    width: UInt32(metadata.width),
                    height: UInt32(metadata.height))
            }
            publishContent(surface, commit: commit)
            return
        }

        if let dmabuf = buffer.retainedSemanticOwner(
            as: DmabufBuffer.self)
        {
            let attrs = dmabuf.attrs
            // The plane fds are borrowed (owned by DmabufBuffer); the renderer
            // duplicates them before this synchronous call returns.
            guard let renderService = server.renderService
            else {
                importFailed(surface)
                return
            }
            let newId = renderService.importDmabuf(
                Self.renderDmabufImport(
                    previousIOSurfaceID: surface.renderIosurfaceId,
                    attrs: attrs,
                    acquire: commit.aux.syncAcquire,
                    release: commit.aux.syncRelease))
            guard newId != 0 else {
                importFailed(surface)
                return
            }
            surface.renderIosurfaceId = newId
            surface.didImportContent(generation: commit.bufferGeneration)
            if reportedImports.insert(surfaceId).inserted {
                diagnostic(
                    "surface=\(surfaceId) dmabuf=\(attrs.width)x\(attrs.height) format=\(attrs.format) modifier=\(attrs.modifier) texture=\(newId) generation=\(surface.renderContentGeneration)"
                )
            }
            recordBufferSize(
                surfaceId: surfaceId, width: UInt32(attrs.width), height: UInt32(attrs.height))
            publishContent(surface, commit: commit)
            return
        }
        importFailed(surface)
    }

    /// Translate the Wayland-owned buffer snapshot into the neutral render-service
    /// request. Plane descriptors and sync points remain in wire order.
    static func renderDmabufImport(
        previousIOSurfaceID: UInt32,
        attrs: DmabufAttrs,
        acquire: SyncPoint?,
        release: SyncPoint?
    ) -> RenderDmabufImport {
        RenderDmabufImport(
            previousIOSurfaceID: previousIOSurfaceID,
            width: UInt32(attrs.width),
            height: UInt32(attrs.height),
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
            acquire: acquire.map {
                RenderSyncPoint(handle: $0.handle, point: $0.point)
            },
            release: release.map {
                RenderSyncPoint(handle: $0.handle, point: $0.point)
            })
    }

    /// Reject a committed buffer that could not become renderer content. Any old
    /// IOSurface is retired through the normal serial-safe renderer path, while the
    /// new wl_buffer is immediately reusable because no GPU submission references it.
    /// The scene is detached so stale pixels cannot masquerade as the failed commit.
    private func importFailed(_ surface: WlSurface) {
        if surface.renderIosurfaceId != 0 {
            server.renderService?
                .releaseIOSurface(surface.renderIosurfaceId)
            surface.renderIosurfaceId = 0
        }
        surface.releaseCurrentBufferImmediately()
        surface.committedLogicalWidth = 0
        surface.committedLogicalHeight = 0
        feeder?.surfaceContentDetached(surfaceID: surface.objectId)
    }

    /// Resolve the smallest safe output set for a surface commit. Presentation
    /// membership is authoritative once known; role pins and model output affinity
    /// cover first-map commits before the presentation walk has populated it.
    private func requestRedraw(for surface: WlSurface) {
        var outputIDs = surface.enteredOutputIDs
        if let layer = surface.role as? ZwlrLayerSurface {
            outputIDs.insert(layer.outputID)
        } else if let lock =
            surface.role as? ExtSessionLockSurface
        {
            outputIDs.insert(lock.outputID)
        } else if let parent = surface.subsurfaceParent {
            outputIDs.formUnion(parent.enteredOutputIDs)
        } else if let xdg = surface.role as? XdgSurface,
            let popup = xdg.popup,
            let parent = popup.grabOriginSurface
        {
            outputIDs.formUnion(parent.enteredOutputIDs)
        }
        if outputIDs.isEmpty,
            let windowID = windowID(
                forSurfaceId: surface.objectId),
            let outputID = server.window(
                id: windowID)?.currentOutputID
        {
            outputIDs.insert(outputID)
        }
        if outputIDs.isEmpty {
            RenderBridge.requestFrame(server: server, outputId: 0)
            return
        }
        for outputID in outputIDs {
            RenderBridge.requestFrame(
                server: server,
                outputId: outputID,
                reason: .surfaceDamage)
        }
    }

    /// Scene teardown for a destroyed surface: release its IOSurface, tear down a
    /// child-surface (subsurface/popup) scene layer, and tear down a layer surface's
    /// model window + scene. The seat/model unmap stays on RouterWindowDriver.
    func surfaceDestroyed(surfaceId: UInt32, iosurfaceId: UInt32) {
        // A client may destroy wl_surface without first issuing the ordinary
        // null-buffer unmap. Capture while the IOSurface is still registered;
        // root app-window topology is retained by the close transition.
        var retainedRootWindow = false
        if let windowID = windowID(forSurfaceId: surfaceId),
            let window = server.window(id: windowID),
            window.source == .xdg || window.source == .xwayland
        {
            retainedRootWindow =
                feeder?.beginClosing(
                    window: window,
                    iosurfaceID: iosurfaceId,
                    destroyWindowOnCompletion: true) ?? false
            window.mapped = false
        }
        server.renderService?
            .releaseIOSurface(iosurfaceId)
        // Tear down a child-surface (subsurface/popup) scene layer; no-ops for a
        // window or unknown id. xdg-toplevel teardown runs through `willDestroyImpl`.
        feeder?.childSurfaceDestroyed(surfaceID: surfaceId)
        if !retainedRootWindow {
            // A layer surface is its own window (no toplevelWillDestroy), so its
            // model window + scene tear down here. A failed app-window capture
            // takes this immediate path too.
            if let windowID = windowID(forSurfaceId: surfaceId),
                let window = server.window(id: windowID),
                window.source == .xdg || window.source == .xwayland
            {
                feeder?.windowUnmapped(surfaceID: surfaceId)
                _ = server.destroyWindow(id: windowID)
            } else {
                destroyLayerSurface(surfaceId: surfaceId)
            }
        }
    }

    /// Record the committed buffer's pixel extent onto the surface's model window
    /// (resolved by surface id), the backing layer's source size the scene feeder
    /// scales onto the eased presented frame. No-ops for a surface with no window.
    private func recordBufferSize(surfaceId: UInt32, width: UInt32, height: UInt32) {
        guard let windowID = windowID(forSurfaceId: surfaceId),
            let window = server.window(id: windowID)
        else { return }
        window.committedBufferSize = RenderSize(w: Double(width), h: Double(height))
    }

    /// Create a root window scene with the surface content that was imported earlier
    /// in the same Wayland commit. `WlSurface.applyLatch` intentionally publishes
    /// scene state before invoking the role callback, so a first-map root has no
    /// scene during `publishContent`; mapping must bind the retained texture itself.
    func mapRootSurface(
        surfaceID: UInt32,
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) {
        guard let surface = compositor.surface(id: surfaceID) else {
            feeder?.windowMapped(
                surfaceID: surfaceID,
                x: x,
                y: y,
                width: width,
                height: height)
            return
        }
        if reportedRootMaps.insert(surfaceID).inserted {
            diagnostic(
                "root-map surface=\(surfaceID) frame=\(x),\(y) "
                    + "\(width)x\(height) texture=\(surface.renderIosurfaceId)")
        }
        feeder?.windowMapped(
            surfaceID: surfaceID,
            x: x,
            y: y,
            width: width,
            height: height,
            iosurfaceID: surface.renderIosurfaceId,
            sample: contentSample(for: surface))
        publishAlpha(surface)
        // The role callback publishes this root after the commit import's redraw
        // request. Arm the intersecting physical output from the completed
        // first-map state so the retained root and its content land together.
        if let windowID = windowID(
            forSurfaceId: surfaceID)
        {
            RenderBridge.requestFrame(
                server: server,
                forWindowID: windowID,
                reason: .surfaceDamage)
        } else {
            RenderBridge.requestFrame(
                server: server,
                outputId: 0,
                reason: .surfaceDamage)
        }
    }

    /// Publish the surface's freshly-uploaded IOSurface as its backing layer's
    /// content through the scene feeder. A subsurface composites within its parent
    /// window's scene at its offset (its own backing layer under the parent content);
    /// a window/root surface publishes to its own backing layer. The author resolves
    /// the backing layer from its scene map and no-ops until the scene exists — so
    /// this is safe to call on every commit.
    private func publishContent(_ surface: WlSurface, commit: SurfaceCommit) {
        defer { publishAlpha(surface) }
        let bufferWidth = commit.bufferPixelSize.width
        let bufferHeight = commit.bufferPixelSize.height
        // Stash the surface's own content extent (surface-local logical px) so the
        // router hit-test can bound a hit on this surface when it has no input region.
        let logicalSize = commit.logicalContentSize
        surface.committedLogicalWidth = logicalSize.width
        surface.committedLogicalHeight = logicalSize.height
        if let parent = surface.subsurfaceParent {
            let logicalW = surface.committedLogicalWidth
            let logicalH = surface.committedLogicalHeight
            feeder?.subsurfaceCommitted(
                surfaceID: surface.objectId,
                parentSurfaceID: parent.objectId,
                x: Double(surface.subsurfaceX), y: Double(surface.subsurfaceY),
                width: logicalW, height: logicalH,
                iosurfaceID: surface.renderIosurfaceId,
                sample: subsurfaceContentSample(
                    for: surface, bufferWidth: bufferWidth, bufferHeight: bufferHeight,
                    logicalW: logicalW, logicalH: logicalH))
            return
        }
        // An xdg popup composites under its parent window's popup layer at its
        // resolved parent-local placement (logical coordinates).
        if let xdg = surface.role as? XdgSurface, let popup = xdg.popup,
            let parentSurface = popup.parent?.surface
        {
            let place = popup.placement
            let logicalW = Double(max(1, place.width))
            let logicalH = Double(max(1, place.height))
            feeder?.popupCommitted(
                surfaceID: surface.objectId,
                parentSurfaceID: parentSurface.objectId,
                x: Double(place.x), y: Double(place.y),
                width: logicalW, height: logicalH,
                iosurfaceID: surface.renderIosurfaceId,
                sample: subsurfaceContentSample(
                    for: surface, bufferWidth: bufferWidth, bufferHeight: bufferHeight,
                    logicalW: logicalW, logicalH: logicalH))
            return
        }
        // A zwlr layer surface is an independent, output-anchored window (panel /
        // wallpaper / overlay) at its arranged geometry and layer z-band.
        if let layerSurface = surface.role as? ZwlrLayerSurface {
            publishLayerSurfaceContent(
                surface, layerSurface, bufferWidth: bufferWidth, bufferHeight: bufferHeight)
            return
        }
        feeder?.surfaceContent(
            surfaceID: surface.objectId,
            iosurfaceID: surface.renderIosurfaceId,
            sample: contentSample(for: surface))
    }

    private func publishAlpha(_ surface: WlSurface) {
        feeder?.surfaceContentOpacity(
            surfaceID: surface.objectId,
            opacity:
                Double(surface.aux.alphaMultiplier)
                / Double(UInt32.max))
    }

    /// Author a layer surface's content: ensure its model window + scene exist at the
    /// arranged geometry (z-banded by layer), then publish its IOSurface. The window
    /// is borderless and fixed-position — the scene feeder lays it out at the arranged
    /// rect with no chrome and no tile animation. Runs on the map commit (the router's
    /// `applyLatch` publishes content before the role's `layerSurfaceMapped` fires).
    private func publishLayerSurfaceContent(
        _ surface: WlSurface, _ layerSurface: ZwlrLayerSurface,
        bufferWidth: UInt32, bufferHeight: UInt32
    ) {
        let wm = windowManager
        let windowID = wm.layerShellCreated(
            surfaceObjectId: surface.objectId, layer: layerSurface.layer)
        guard let window = wm.server.window(id: windowID) else { return }
        let x = Double(layerSurface.arrangedX)
        let y = Double(layerSurface.arrangedY)
        let w = Double(layerSurface.configuredWidth)
        let h = Double(layerSurface.configuredHeight)
        if reportedLayerMaps.insert(surface.objectId).inserted {
            diagnostic(
                "layer-map surface=\(surface.objectId) output=\(layerSurface.outputID) layer=\(layerSurface.layer) frame=\(x),\(y) \(w)x\(h) buffer=\(bufferWidth)x\(bufferHeight) texture=\(surface.renderIosurfaceId)"
            )
        }
        window.committedBufferSize = RenderSize(w: Double(bufferWidth), h: Double(bufferHeight))
        window.committedLogicalSize = RenderSize(w: max(1, w), h: max(1, h))
        window.currentOutputID = layerSurface.outputID
        window.setGeometry(
            WindowRect(
                x: x, y: y, width: UInt32(max(1, w)), height: UInt32(max(1, h))))
        if !window.mapped {
            window.mapped = true
            window.seedPresentationActorToRect(
                PresentationRect(x: x, y: y, w: max(1, w), h: max(1, h)),
                slotGeneration: window.presentationActor.currentSlotGeneration)
            feeder?.windowMapped(
                surfaceID: surface.objectId,
                x: x,
                y: y,
                width: w,
                height: h,
                iosurfaceID: surface.renderIosurfaceId,
                sample: contentSample(for: surface))
        } else {
            feeder?.surfaceContent(
                surfaceID: surface.objectId,
                iosurfaceID: surface.renderIosurfaceId,
                sample: contentSample(for: surface))
        }
    }

    /// Tear down a layer surface's model window + scene on surface destruction.
    /// No-ops for a non-layer surface id. Also reached from
    /// `RouterWindowDriver.layerSurfaceUnmapped` (idempotent).
    func destroyLayerSurface(surfaceId: UInt32) {
        let wm = windowManager
        guard let window = wm.server.windows.window(bySurfaceObjectId: surfaceId),
            window.source == .layerShell
        else { return }
        feeder?.windowUnmapped(surfaceID: surfaceId)
        wm.layerShellPolicy.unregister(id: UInt64(surfaceId))
        host.xwaylandHost?.updateScale()
        _ = wm.server.destroyWindow(id: window.id)
    }

    /// A content sample for a subsurface (no model window): the source rect is the
    /// committed buffer (or its viewport crop) and the logical size is the buffer
    /// scaled down, with the viewport destination override applied when present.
    private func subsurfaceContentSample(
        for surface: WlSurface, bufferWidth: UInt32, bufferHeight: UInt32,
        logicalW: Double, logicalH: Double
    ) -> NucleusLayers.ContentSample {
        let src = surface.aux.viewportSource
        let dst = surface.aux.viewportDestination
        return NucleusLayers.ContentSample(
            sourceSurfaceID: UInt64(surface.objectId),
            srcX: Float(src?.x ?? 0),
            srcY: Float(src?.y ?? 0),
            srcWidth: Float(src?.width ?? Double(max(1, bufferWidth))),
            srcHeight: Float(src?.height ?? Double(max(1, bufferHeight))),
            logicalWidth: Float(dst.map { Double($0.width) } ?? max(1, logicalW)),
            logicalHeight: Float(dst.map { Double($0.height) } ?? max(1, logicalH)),
            opaqueFullSurface: Self.opaqueRegionCoversSurface(
                surface.opaqueRegion, width: logicalW, height: logicalH))
    }

    private func contentSample(for surface: WlSurface) -> NucleusLayers.ContentSample? {
        guard let windowID = windowID(forSurfaceId: surface.objectId),
            let window = server.window(id: windowID)
        else { return nil }
        let buffer = window.committedBufferSize
        let logical = window.committedLogicalSize
        let src = surface.aux.viewportSource
        let dst = surface.aux.viewportDestination
        return NucleusLayers.ContentSample(
            sourceSurfaceID: UInt64(surface.objectId),
            srcX: Float(src?.x ?? 0),
            srcY: Float(src?.y ?? 0),
            srcWidth: Float(src?.width ?? max(1, buffer.w)),
            srcHeight: Float(src?.height ?? max(1, buffer.h)),
            logicalWidth: Float(dst.map { Double($0.width) } ?? max(1, logical.w)),
            logicalHeight: Float(dst.map { Double($0.height) } ?? max(1, logical.h)),
            opaqueFullSurface: Self.opaqueRegionCoversSurface(
                surface.opaqueRegion, width: logical.w, height: logical.h))
    }

    private static func opaqueRegionCoversSurface(
        _ region: RegionSnapshot?, width: Double, height: Double
    ) -> Bool {
        guard let region, width > 0, height > 0 else { return false }
        let coverW = Int32(max(1, width.rounded(.up)))
        let coverH = Int32(max(1, height.rounded(.up)))
        return region.region.contains(RegionRect(x: 0, y: 0, width: coverW, height: coverH))
    }

    /// wl_shm format → DRM fourcc. Only the two special values differ; every other
    /// wl_shm format value already is its DRM fourcc.
    private static func drmFormat(fromShm wlFormat: UInt32) -> UInt32 {
        switch wlFormat {
        case 0: return 0x3432_5241  // WL_SHM_FORMAT_ARGB8888 → DRM_FORMAT_ARGB8888
        case 1: return 0x3432_5258  // WL_SHM_FORMAT_XRGB8888 → DRM_FORMAT_XRGB8888
        default: return wlFormat
        }
    }
}
