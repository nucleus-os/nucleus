// The scene feeder: the per-frame + per-event bridge from the authoritative
// Swift window model (`NucleusCompositorServer`) to the scene author
// (`WindowSceneAuthor` in `NucleusCompositorWindowScene`). This is the live,
// sole scene authority for managed windows.
//
// Division of labor: the feeder is a policy→scene translator — it knows
// the window model, not layers; the author knows layers, not the model. The author
// owns every layer-id allocation and the compositor-root hosting; the feeder only
// supplies which windows exist, their back-to-front order, geometry, and the
// snapshot handle owned by the current model transition. The feeder holds no
// layer ids and never owns renderer resources independently of that transition.
//
// Lifecycle hooks (`windowMapped`/`windowUnmapped`/`surfaceContent`) are called by
// `RouterWindowDriver`; `authorFrame` is called once per output per frame by the
// compositor loop through `WaylandRuntime.authorSceneFrame`, Swift-direct. The
// per-frame eased layout samples the compositor-owned presentation state on the
// Swift model — the tiling spring (`Window.presentationActor`), the predicted-present
// clock (`Display.predictedPresentNs`), and the committed buffer geometry
// (`Window.committedBufferSize`/`contentOffsetInSlot`).

@_spi(NucleusCompositor) import NucleusLayers
internal import NucleusCompositorServer
import NucleusCompositorServerTypes
internal import NucleusCompositorWindowScene
import struct NucleusRenderModel.TextureHandle
import struct NucleusTypes.BufferPixelSize
import Tracy
import Glibc

@MainActor
final class SceneFeeder: BackgroundEffectDelegate, KdeBlurDelegate {
    struct PresentedWindow: Sendable, Equatable {
        let windowID: UInt64
        let surfaceID: UInt32
        let source: UInt32
        let frame: PresentationRect
    }

    struct TransitionMetrics: Sendable, Equatable {
        var acceptedRemovals: UInt64 = 0
        var snapshotRetirements: UInt64 = 0
    }

    /// The live scene author (the installed `WindowSceneHost` conformer). The
    /// feeder calls it directly, Swift→Swift, with no cross-language hop. The author owns
    /// every layer id + the compositor-root hosting; the feeder supplies only the
    /// surface id, geometry, content, and order.
    private let author: WindowSceneAuthor
    private unowned let host: RouterHost
    private var server: NucleusCompositorServer { host.server }
    private let injectedRenderService: (any CompositorRenderService)?
    private var reportedAuthorFailures: Set<String> = []
    /// Front-to-back input geometry from the same samples successfully authored
    /// for each output. Input never re-samples the presentation animation.
    private var presentedWindowsByOutput: [UInt64: [PresentedWindow]] = [:]
    private var pendingWindowsByOutput: [UInt64: [PresentedWindow]] = [:]
    private(set) var transitionMetrics = TransitionMetrics()

    /// Resolves router surfaces by wire id so the per-frame walk can push output
    /// membership (`wl_surface.enter`/`leave` + preferred scale) directly to the
    /// surface model. Weak: the runtime owns the compositor.
    weak var compositor: WlCompositor?

    init(
        author: WindowSceneAuthor,
        host: RouterHost,
        renderService: (any CompositorRenderService)? = nil
    ) {
        self.author = author
        self.host = host
        self.injectedRenderService = renderService
    }

    private var renderService: (any CompositorRenderService)? {
        injectedRenderService ?? server.renderService
    }

    func presentedWindows(atX x: Double, y: Double) -> [PresentedWindow] {
        let layout = server.layout
        let output = layout.displays.first { display in
            let rect = display.logicalRect
            return x >= Double(rect.x) && x < Double(rect.x + rect.width)
                && y >= Double(rect.y) && y < Double(rect.y + rect.height)
        }
        guard let output else { return [] }
        return presentedWindowsByOutput[output.id] ?? []
    }

    /// Geometry that actually reached a completed presentation. Input must not
    /// resample an animation ahead of what is currently on glass.
    func presentedWindow(surfaceID: UInt32) -> PresentedWindow? {
        for windows in presentedWindowsByOutput.values {
            if let window = windows.first(where: { $0.surfaceID == surfaceID }) { return window }
        }
        return nil
    }

    func presentedWindow(windowID: UInt64) -> PresentedWindow? {
        for windows in presentedWindowsByOutput.values {
            if let window = windows.first(where: { $0.windowID == windowID }) { return window }
        }
        return nil
    }

    /// Geometry authored for the frame currently being evaluated. Direct scanout
    /// eligibility must use this snapshot, not independently sample the animation.
    func pendingWindow(surfaceID: UInt32, outputID: UInt64) -> PresentedWindow? {
        pendingWindowsByOutput[outputID]?.first { $0.surfaceID == surfaceID }
    }

    func outputPresented(_ outputID: UInt64) {
        guard let pending = pendingWindowsByOutput.removeValue(forKey: outputID) else { return }
        presentedWindowsByOutput[outputID] = pending
    }

    @discardableResult
    private func authoring(
        _ operation: String, surfaceID: UInt64? = nil,
        _ body: () throws -> Void
    ) -> Bool {
        do {
            try body()
            return true
        } catch {
            let key = "\(operation):\(surfaceID.map(String.init) ?? "global"): \(error)"
            if reportedAuthorFailures.insert(key).inserted {
                let line = "scene feeder: \(key)\n"
                line.withCString { _ = write(STDERR_FILENO, $0, strlen($0)) }
            }
            return false
        }
    }

    /// A window's surface mapped: create its scene tree (self-allocating
    /// `surfaceAttached`, which also hosts it beneath the compositor root) and
    /// publish any content imported before the role's map callback. Wayland latches
    /// scene content before role state, so first-map content must land as part of
    /// this operation rather than waiting for a second client commit.
    func windowMapped(
        surfaceID: UInt32,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        iosurfaceID: UInt32 = 0,
        sample: ContentSample? = nil
    ) {
        authoring("attach window", surfaceID: UInt64(surfaceID)) {
            _ = try author.surfaceAttached(
                surfaceID: UInt64(surfaceID),
                frame: GeometryRect(x: x, y: y, width: width, height: height))
            if iosurfaceID != 0 {
                try author.setContent(
                    surfaceID: UInt64(surfaceID),
                    content: LayerContent(
                        kind: .external,
                        handle: UInt64(iosurfaceID)),
                    contentSample: sample)
            }
        }
    }

    /// Tear a window scene down immediately. Normal app-window unmap/close first
    /// goes through `beginClosing`; this is the failure, security, and special-
    /// surface path.
    func windowUnmapped(surfaceID: UInt32) {
        authoring("destroy window", surfaceID: UInt64(surfaceID)) {
            try author.surfaceDestroyed(surfaceID: UInt64(surfaceID))
        }
    }

    /// Capture the accepted live content, atomically replace any old overlay,
    /// install the new model generation, and begin the tile spring. Capture is
    /// synchronous and renderer-owned, so a client-content replacement after this
    /// call cannot mutate the transition image.
    func beginTileTransition(
        window: Window,
        finalRect: PresentationRect,
        slotGeneration: UInt64,
        iosurfaceID explicitIOSurfaceID: UInt32? = nil
    ) {
        guard !window.presentationActor.targetMatches(finalRect) else { return }
        defer {
            window.beginPresentationTileAnimation(
                finalRect: finalRect,
                slotGeneration: slotGeneration)
            RenderBridge.requestFrame(server: server, forWindowID: window.id)
        }
        guard window.surfaceObjectId != 0,
              let service = renderService,
              let iosurfaceID = explicitIOSurfaceID
                ?? compositor?.surface(
                    id: window.surfaceObjectId)?.renderIosurfaceId,
              iosurfaceID != 0,
              let snapshot = service.captureSurfaceSnapshot(
                iosurfaceID: iosurfaceID)
        else { return }

        let surfaceID = UInt64(window.surfaceObjectId)
        guard authoring("begin tile crossfade", surfaceID: surfaceID, {
            try author.beginContentCrossfade(
                surfaceID: surfaceID,
                snapshotHandle: snapshot.handle)
        }) else {
            service.releaseSnapshot(snapshot.handle)
            return
        }

        let installed = window.installTileCrossfade(
            snapshotHandle: snapshot.handle)
        Trace.plot(
            "swift.compositor.transition_generation",
            installed.generation)
        if let replaced = installed.replaced {
            service.releaseSnapshot(replaced.snapshotHandle)
            transitionMetrics.snapshotRetirements &+= 1
            Trace.plot(
                "swift.compositor.transition_snapshot_retirements",
                transitionMetrics.snapshotRetirements)
        }
    }

    /// Begin a frozen closing presentation before the client IOSurface is
    /// detached. Returns false when no safe snapshot could be installed, in which
    /// case the caller must perform immediate topology teardown.
    @discardableResult
    func beginClosing(
        window: Window,
        iosurfaceID explicitIOSurfaceID: UInt32? = nil,
        destroyWindowOnCompletion: Bool
    ) -> Bool {
        if window.hasActiveClosingFade() {
            if destroyWindowOnCompletion {
                window.requireWindowDestructionAfterClosing()
            }
            return true
        }
        guard window.visibleInScene(),
              window.source == .xdg || window.source == .xwayland,
              window.surfaceObjectId != 0,
              let service = renderService
        else { return false }
        let iosurfaceID = explicitIOSurfaceID
            ?? compositor?.surface(id: window.surfaceObjectId)?.renderIosurfaceId
            ?? 0
        guard iosurfaceID != 0,
              let snapshot = service.captureSurfaceSnapshot(
                iosurfaceID: iosurfaceID)
        else { return false }

        let surfaceID = UInt64(window.surfaceObjectId)
        guard authoring("begin closing fade", surfaceID: surfaceID, {
            try author.beginContentCrossfade(
                surfaceID: surfaceID,
                snapshotHandle: snapshot.handle)
        }) else {
            service.releaseSnapshot(snapshot.handle)
            return false
        }

        let installed = window.installClosingFade(
            snapshotHandle: snapshot.handle,
            destroyWindowOnCompletion: destroyWindowOnCompletion)
        Trace.plot(
            "swift.compositor.transition_generation",
            installed.generation)
        if let replaced = installed.replaced {
            service.releaseSnapshot(replaced.snapshotHandle)
            transitionMetrics.snapshotRetirements &+= 1
            Trace.plot(
                "swift.compositor.transition_snapshot_retirements",
                transitionMetrics.snapshotRetirements)
        }
        RenderBridge.requestFrame(server: server, forWindowID: window.id)
        return true
    }

    /// Cancel a close because the same protocol object mapped again. The retained
    /// scene stays attached; only the overlay resource and transition generation
    /// are retired.
    func cancelClosingForRemap(window: Window) {
        guard window.hasActiveClosingFade() else { return }
        _ = finishTransition(window: window, preserveScene: true)
    }

    /// Security transition: no non-lock snapshot may remain retained after the
    /// lock gate activates. Mapped tile transitions keep their ordinary scene;
    /// closing scenes are removed immediately.
    func cancelTransitionsForSessionLock() {
        for window in server.windows.windows
        where window.source != .lock && window.presentationActor.transition != nil {
            window.presentationActor.cancelTileAnimation()
            _ = finishTransition(
                window: window,
                preserveScene: !window.hasActiveClosingFade())
        }
    }

    /// An output that owned the transition clock disappeared. Tile overlays are
    /// cancelled and closing scenes complete immediately so no transition waits
    /// forever for a presentation timestamp that can no longer arrive.
    func outputRemoved(_ outputID: UInt64) {
        for window in server.windows.windows
        where window.currentOutputID == outputID
            && window.presentationActor.transition != nil
        {
            window.presentationActor.cancelTileAnimation()
            _ = finishTransition(
                window: window,
                preserveScene: !window.hasActiveClosingFade())
        }
        presentedWindowsByOutput[outputID] = nil
        pendingWindowsByOutput[outputID] = nil
    }

    /// Tear down retained scene state while the renderer service is still alive.
    /// Compositor shutdown calls this before renderer shutdown so snapshot handles
    /// are retired through their normal owner instead of being orphaned by process
    /// teardown order.
    func shutdown() {
        let windows = server.windows.windows
        for window in windows {
            window.presentationActor.cancelTileAnimation()
            if window.presentationActor.transition != nil {
                _ = finishTransition(
                    window: window,
                    preserveScene: false)
            } else if window.surfaceObjectId != 0 {
                windowUnmapped(
                    surfaceID: window.surfaceObjectId)
            }
        }
        presentedWindowsByOutput.removeAll()
        pendingWindowsByOutput.removeAll()
    }

    /// Remove the currently-authored overlay/topology, then retire exactly the
    /// matching model generation and renderer resource. Failed author commits
    /// leave the model obligation live so the next frame can retry.
    @discardableResult
    private func finishTransition(
        window: Window,
        preserveScene: Bool
    ) -> Bool {
        guard let generation = window.activeTransitionGeneration(),
              window.surfaceObjectId != 0
        else { return true }
        let surfaceID = UInt64(window.surfaceObjectId)
        guard authoring("end snapshot transition", surfaceID: surfaceID, {
            try author.endContentCrossfade(surfaceID: surfaceID)
        }) else { return false }
        if !preserveScene {
            guard authoring("remove closing scene", surfaceID: surfaceID, {
                try author.surfaceDestroyed(surfaceID: surfaceID)
            }) else { return false }
        }
        guard let retirement = window.takePresentationTransition(
            generation: generation)
        else { return false }
        transitionMetrics.acceptedRemovals &+= 1
        Trace.plot(
            "swift.compositor.transition_accepted_removals",
            transitionMetrics.acceptedRemovals)
        renderService?.releaseSnapshot(retirement.snapshotHandle)
        transitionMetrics.snapshotRetirements &+= 1
        Trace.plot(
            "swift.compositor.transition_snapshot_retirements",
            transitionMetrics.snapshotRetirements)
        if retirement.wasClosing {
            window.mapped = false
        }
        if retirement.destroyWindow {
            _ = server.destroyWindow(id: window.id)
        }
        return true
    }

    /// Repaint a window's traffic-light cluster (keyed by its root surface id) for a
    /// chrome hover/press transition, independent of layout. The input
    /// dispatch drives this directly.
    func setChromeButtonState(rootSurfaceID: UInt64, hovered: UInt32, pressed: UInt32) {
        authoring("update chrome buttons", surfaceID: rootSurfaceID) {
            try author.setChromeButtonState(
                surfaceID: rootSurfaceID, hovered: hovered, pressed: pressed)
        }
    }

    /// The layer-context ids of the mapped ext-session-lock surfaces on `outputID` (a
    /// surface with no resolved output is included as a defensive fallback).
    ///
    /// This is the enumeration for the session-lock security boundary: the render core
    /// restricts a locked output's scanout to exactly these contexts over an opaque
    /// ground, at the single composition choke point, independent of every scene
    /// authority that wrote to the tree (windows, overlay, cursor, …). Context ids
    /// round-trip unchanged through the layers→render-model lowering, so the render
    /// walk matches surfaces by the same id the author minted. The author-time filter
    /// in `authorFrame` is a complementary efficiency measure — it keeps hidden windows
    /// from being animated — not the boundary. An empty set blanks the output.
    func lockSurfaceContexts(outputID: UInt64) -> Set<UInt32> {
        var contexts: Set<UInt32> = []
        for window in server.windows.windows
        where window.source == .lock && window.mapped && window.surfaceObjectId != 0 {
            let onOutput = window.currentOutputID == nil || window.currentOutputID == outputID
            guard onOutput,
                let context = author.contextID(forSurface: UInt64(window.surfaceObjectId))
            else { continue }
            contexts.insert(context.rawValue)
        }
        return contexts
    }

    /// Publish a surface's freshly-uploaded GPU content (an IOSurface id) as its
    /// backing-layer content. Replaces option-b's `nucleus_render_layer_set_content`
    /// `@c` round-trip with a direct author call — the author resolves the surface's
    /// backing layer from its scene map.
    func surfaceContent(
        surfaceID: UInt32,
        iosurfaceID: UInt32,
        sample: ContentSample? = nil
    ) {
        guard iosurfaceID != 0 else { return }
        authoring("publish content", surfaceID: UInt64(surfaceID)) {
            try author.setContent(
                surfaceID: UInt64(surfaceID),
                content: LayerContent(kind: .external, handle: UInt64(iosurfaceID)),
                contentSample: sample)
        }
    }

    /// Clear a detached surface's backing without tearing down its topology. Root
    /// window scenes may be removed immediately afterward; subsurfaces remain
    /// attached and can map again on a later buffer commit.
    func surfaceContentDetached(surfaceID: UInt32) {
        authoring("detach content", surfaceID: UInt64(surfaceID)) {
            try author.setContent(
                surfaceID: UInt64(surfaceID), content: .none,
                contentSample: ContentSample())
        }
    }

    /// Publish a subsurface's committed content: ensure its backing layer exists
    /// under the parent window's content viewport, position/size it at the
    /// subsurface offset, then set its content. Idempotent attach, so safe to call
    /// on every subsurface commit. No-ops until the parent window has a scene.
    func subsurfaceCommitted(
        surfaceID: UInt32, parentSurfaceID: UInt32,
        x: Double, y: Double, width: Double, height: Double,
        iosurfaceID: UInt32, sample: ContentSample? = nil
    ) {
        guard iosurfaceID != 0 else { return }
        let frame = GeometryRect(x: x, y: y, width: max(1, width), height: max(1, height))
        authoring("commit subsurface", surfaceID: UInt64(surfaceID)) {
            try author.childSurfaceAttached(
                surfaceID: UInt64(surfaceID), parentSurfaceID: UInt64(parentSurfaceID),
                kind: .subsurface, frame: frame)
            try author.layoutChildSurface(surfaceID: UInt64(surfaceID), frame: frame)
            try author.setContent(
                surfaceID: UInt64(surfaceID),
                content: LayerContent(kind: .external, handle: UInt64(iosurfaceID)),
                contentSample: sample)
        }
    }

    /// Publish an xdg popup's committed content: ensure its backing layer exists
    /// under the parent window's popup layer (above the window content), position it
    /// at the parent-local placement, then set its content. Idempotent attach.
    func popupCommitted(
        surfaceID: UInt32, parentSurfaceID: UInt32,
        x: Double, y: Double, width: Double, height: Double,
        iosurfaceID: UInt32, sample: ContentSample? = nil
    ) {
        guard iosurfaceID != 0 else { return }
        let frame = GeometryRect(x: x, y: y, width: max(1, width), height: max(1, height))
        authoring("commit popup", surfaceID: UInt64(surfaceID)) {
            try author.childSurfaceAttached(
                surfaceID: UInt64(surfaceID), parentSurfaceID: UInt64(parentSurfaceID),
                kind: .popup, frame: frame)
            try author.layoutChildSurface(surfaceID: UInt64(surfaceID), frame: frame)
            try author.setContent(
                surfaceID: UInt64(surfaceID),
                content: LayerContent(kind: .external, handle: UInt64(iosurfaceID)),
                contentSample: sample)
        }
    }

    /// Tear down a child surface's (subsurface/popup) backing layer. No-ops for a
    /// window or unknown id, so it is safe to call on every surface destruction.
    func childSurfaceDestroyed(surfaceID: UInt32) {
        authoring("detach child surface", surfaceID: UInt64(surfaceID)) {
            try author.childSurfaceDetached(surfaceID: UInt64(surfaceID))
        }
    }

    /// Compute the displays `window`'s presented frame overlaps, update its router
    /// surface's entered-output set (the surface owns the enter/leave diff + the
    /// preferred-scale recompute), and record the dominant (largest-overlap) output
    /// on a managed window — the Swift-side replacement for the substrate
    /// `updateSurfaceOutputState` / `noteSurfaceOutput` affinity computation. A
    /// layer-shell window keeps its pinned output (set at content publish).
    private func updateSurfaceMembership(window: Window, x: Double, y: Double, w: Double, h: Double) {
        var ids: Set<UInt64> = []
        var dominantID: UInt64?
        var dominantArea = 0.0
        for display in server.layout.displays {
            let r = display.logicalRect
            let area = Self.overlapArea(x: x, y: y, w: w, h: h, rx: r.x, ry: r.y, rw: r.width, rh: r.height)
            guard area > 0 else { continue }
            ids.insert(display.id)
            if area > dominantArea { dominantArea = area; dominantID = display.id }
        }
        if window.isManagedAppWindow() { window.currentOutputID = dominantID }
        if window.surfaceObjectId != 0, let surface = compositor?.surface(id: window.surfaceObjectId) {
            surface.updateEnteredOutputs(ids)
        }
    }

    /// Intersection area of two logical rects (0 when disjoint).
    private static func overlapArea(
        x: Double, y: Double, w: Double, h: Double,
        rx: Double, ry: Double, rw: Double, rh: Double
    ) -> Double {
        let ix = max(0, min(x + w, rx + rw) - max(x, rx))
        let iy = max(0, min(y + h, ry + rh) - max(y, ry))
        return ix * iy
    }

    nonisolated func backgroundBlurRegionUpdated(surfaceID: UInt32, region: RegionSnapshot?) {
        MainActor.assumeIsolated {
            host.traceProtocol(
                "ext-background-effect surface=\(surfaceID) "
                    + "rectangles=\(region?.rectangleCount ?? 0)")
            authoring("update background effect", surfaceID: UInt64(surfaceID)) {
                try author.setBackgroundEffect(
                    surfaceID: UInt64(surfaceID),
                    enabled: region != nil,
                    regions: Self.backgroundEffectRegions(from: region))
            }
        }
    }

    nonisolated func kdeBlurUpdated(
        _ surface: WlSurface,
        region: RegionSnapshot?,
        wholeSurface: Bool
    ) {
        let surfaceID = surface.objectId
        MainActor.assumeIsolated {
            host.traceProtocol(
                "kde-blur surface=\(surfaceID) whole=\(wholeSurface) "
                    + "rectangles=\(region?.rectangleCount ?? 0)")
            authoring("update KDE blur", surfaceID: UInt64(surfaceID)) {
                try author.setBackgroundEffect(
                    surfaceID: UInt64(surfaceID),
                    enabled: true,
                    regions: wholeSurface
                        ? BackgroundEffectRegions(
                            rects: [], wholeSurface: true)
                        : Self.backgroundEffectRegions(from: region))
            }
        }
    }

    nonisolated func kdeBlurCleared(_ surface: WlSurface) {
        let surfaceID = surface.objectId
        MainActor.assumeIsolated {
            host.traceProtocol("kde-blur-clear surface=\(surfaceID)")
            authoring("clear KDE blur", surfaceID: UInt64(surfaceID)) {
                try author.setBackgroundEffect(
                    surfaceID: UInt64(surfaceID),
                    enabled: false,
                    regions: BackgroundEffectRegions())
            }
        }
    }

    private static func backgroundEffectRegions(from region: RegionSnapshot?) -> BackgroundEffectRegions {
        guard let region else { return BackgroundEffectRegions() }
        guard region.rectangleCount <= BackgroundEffectRegions.maxRects else {
            return BackgroundEffectRegions(rects: [], wholeSurface: true)
        }
        let rects = region.rectangles.map { rect in
            BackgroundEffectRect(
                x: Float(rect.x), y: Float(rect.y),
                width: Float(rect.width), height: Float(rect.height))
        }
        return BackgroundEffectRegions(rects: rects, wholeSurface: false)
    }

    /// One presentation frame for the output predicted to present at
    /// `predictedPresentNs`: publish the back-to-front z-order of the scene-visible
    /// windows, then advance + author each window's eased layout. The compositor
    /// owns the timeline AND the frame — it eases the PRESENTED frame (position +
    /// size) toward the tile target at the display rate, scaling the client's buffer
    /// onto it, independent of the client's commit cadence.
    ///
    /// Ordering is output-independent — every output composes the same compositor
    /// root. The spring is sampled fresh per
    /// output (closed-form, no integration state), so multiple per-frame calls are
    /// safe. Returns whether any geometry, tile-overlay, or closing opacity can
    /// still change, so the frame loop keeps requesting frames.
    @discardableResult
    func authorFrame(outputID: UInt64, predictedPresentNs: UInt64) -> Bool {
        // Refresh this output's predicted-present clock; the spring samples it.
        // Hardware frame-request arming stays in the reactor.
        if let display = server.layout.display(id: outputID) {
            display.predictedPresentNs = predictedPresentNs
        }
        let presentSeconds = Double(predictedPresentNs) / 1_000_000_000

        // Session-lock filtering: while a lock is active, only ext-session-lock
        // surfaces are authored into the window scene. This is an efficiency measure,
        // NOT the security boundary — it covers only the window-scene authority, not
        // the overlay/cursor/other authorities. The complete blank is the intended
        // render-time locked composition (see `lockSurfaceLayers`). The `locked` event
        // is emitted from the present-ack path (`SessionLockGate.noteOutputPresented`)
        // once a post-lock frame has actually presented.
        let locked = host.sessionLockGate.isActive()
        let windows = server.windows.windows.filter {
            $0.visibleInScene() && (!locked || $0.source == .lock)
        }
        let order = windows.map { UInt64($0.surfaceObjectId) }.filter { $0 != 0 }
        authoring("set window order") { try author.setWindowOrder(order) }

        let focusedID = server.windows.focusedWindow?.id
        var anyInFlight = false
        var authoredWindows: [PresentedWindow] = []
        for window in windows {
            let surfaceID = UInt64(window.surfaceObjectId)
            guard surfaceID != 0 else { continue }
            let hadTileTransition: Bool
            if case .tile = window.presentationActor.transition {
                hadTileTransition = true
            } else {
                hadTileTransition = false
            }
            let tileInFlight = window.advanceTileAnimation(
                presentTimeSeconds: presentSeconds)
            let closingInFlight = window.advanceClosingFade(
                presentTimeSeconds: presentSeconds)
            if tileInFlight || closingInFlight {
                anyInFlight = true
            }
            let presented = window.currentAnimatedRect()
            // Push the surface's output membership from its presented frame (the
            // router emits wl_surface.enter/leave + preferred scale) and update the
            // managed window's dominant output. Idempotent, so the redundant per-
            // output calls of this walk collapse to one diff.
            updateSurfaceMembership(
                window: window, x: presented.x, y: presented.y, w: presented.w, h: presented.h)
            let base = window.logicalSize()
            let buffer = window.committedBufferSize
            let offset = window.contentOffsetInSlot
            let insets = window.chromeInsets
            let authored = authoring("apply window layout", surfaceID: surfaceID) {
                try author.applyLayout(
                surfaceID: surfaceID,
                // The eased PRESENTED outer frame (root authored crisp at this size).
                frame: GeometryRect(x: presented.x, y: presented.y, width: presented.w, height: presented.h),
                // The client's committed visible extent — the only layer carrying the
                // presented/base scale, so it settles to identity.
                baseSize: GeometrySize(width: max(1, base.w), height: max(1, base.h)),
                // The full committed buffer, shifted by the negated geometry origin so
                // the visible sub-rect aligns with the content viewport.
                backingFrame: GeometryRect(
                    x: offset.x, y: offset.y,
                    width: max(1, buffer.w), height: max(1, buffer.h)),
                chromeInsets: NucleusCompositorWindowScene.WindowEdgeInsets(
                    top: insets.top, left: insets.left, bottom: insets.bottom, right: insets.right),
                chromeFocused: window.id == focusedID,
                windowOpacity: window.windowPresentationOpacity(),
                overlayOpacity: window.transitionOverlayOpacity())
            }
            if authored {
                if window.hasActiveClosingFade(), !closingInFlight {
                    if !finishTransition(
                        window: window,
                        preserveScene: false)
                    {
                        anyInFlight = true
                    }
                    continue
                }
                if hadTileTransition, !tileInFlight,
                   !finishTransition(
                    window: window,
                    preserveScene: true)
                {
                    anyInFlight = true
                }
                authoredWindows.append(PresentedWindow(
                    windowID: window.id,
                    surfaceID: window.surfaceObjectId,
                    source: window.source.rawValue,
                    frame: presented))
            }
        }
        pendingWindowsByOutput[outputID] = authoredWindows.reversed()
        return anyInFlight
    }
}
