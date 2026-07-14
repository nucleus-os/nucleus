// The scene feeder: the per-frame + per-event bridge from the authoritative
// Swift window model (`NucleusCompositorServer`) to the scene author
// (`WindowSceneAuthor` in `NucleusCompositorWindowScene`). This is the live,
// sole scene authority for managed windows.
//
// Division of labor: the feeder is a stateless policy→scene translator — it knows
// the window model, not layers; the author knows layers, not the model. The author
// owns every layer-id allocation and the compositor-root hosting; the feeder only
// supplies which windows exist, their back-to-front order, and their geometry. So
// the feeder holds no layer ids.
//
// Lifecycle hooks (`windowMapped`/`windowUnmapped`/`surfaceContent`) are called by
// `RouterWindowDriver`; `authorFrame` is called once per output per frame by the
// compositor loop through `WaylandRuntime.authorSceneFrame`, Swift-direct. The
// per-frame eased layout samples the compositor-owned presentation state on the
// Swift model — the tiling spring (`Window.presentationActor`), the predicted-present
// clock (`Display.predictedPresentNs`), and the committed buffer geometry
// (`Window.committedBufferSize`/`contentOffsetInSlot`). The closing fade +
// content-crossfade *snapshot* are not yet driven from here (the opacity-animation
// primitive already lives on the author, awaiting a feeder call-site).

@_spi(NucleusCompositor) import NucleusLayers
import NucleusCompositorServer
import NucleusCompositorWindowScene
import Glibc

@MainActor
final class SceneFeeder: BackgroundEffectDelegate {
    struct PresentedWindow: Sendable, Equatable {
        let windowID: UInt64
        let surfaceID: UInt32
        let source: UInt32
        let frame: PresentationRect
    }

    /// The live scene author (the installed `WindowSceneHost` conformer). The
    /// feeder calls it directly, Swift→Swift, with no cross-language hop. The author owns
    /// every layer id + the compositor-root hosting; the feeder supplies only the
    /// surface id, geometry, content, and order.
    private let author: WindowSceneAuthor
    private var reportedAuthorFailures: Set<String> = []
    /// Front-to-back input geometry from the same samples successfully authored
    /// for each output. Input never re-samples the presentation animation.
    private var presentedWindowsByOutput: [UInt64: [PresentedWindow]] = [:]
    private var pendingWindowsByOutput: [UInt64: [PresentedWindow]] = [:]

    /// Resolves router surfaces by wire id so the per-frame walk can push output
    /// membership (`wl_surface.enter`/`leave` + preferred scale) directly to the
    /// surface model. Weak: the runtime owns the compositor.
    weak var compositor: WlCompositor?

    init(author: WindowSceneAuthor = currentWindowSceneAuthor()) {
        self.author = author
    }

    func presentedWindows(atX x: Double, y: Double) -> [PresentedWindow] {
        let layout = NucleusCompositorServer.shared.layout
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
    /// `surfaceAttached`, which also hosts it beneath the compositor root). The
    /// author mints the layer ids; nothing flows back to the surface (the author
    /// owns the surface-id → backing-layer map the content publish resolves).
    func windowMapped(surfaceID: UInt32, x: Double, y: Double, width: Double, height: Double) {
        authoring("attach window", surfaceID: UInt64(surfaceID)) {
            _ = try author.surfaceAttached(
                surfaceID: UInt64(surfaceID),
                frame: GeometryRect(x: x, y: y, width: width, height: height))
        }
    }

    /// A window's surface unmapped or destroyed: unhost + tear its scene down.
    func windowUnmapped(surfaceID: UInt32) {
        authoring("destroy window", surfaceID: UInt64(surfaceID)) {
            try author.surfaceDestroyed(surfaceID: UInt64(surfaceID))
        }
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
        for window in NucleusCompositorServer.shared.windows.windows
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
    func surfaceContent(surfaceID: UInt32, iosurfaceID: UInt32, generation: UInt64, sample: ContentSample? = nil) {
        guard iosurfaceID != 0 else { return }
        authoring("publish content", surfaceID: UInt64(surfaceID)) {
            try author.setContent(
                surfaceID: UInt64(surfaceID),
                content: LayerContent(kind: .external, handle: UInt64(iosurfaceID), generation: UInt64(generation)),
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
        iosurfaceID: UInt32, generation: UInt64, sample: ContentSample? = nil
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
                content: LayerContent(kind: .external, handle: UInt64(iosurfaceID), generation: UInt64(generation)),
                contentSample: sample)
        }
    }

    /// Publish an xdg popup's committed content: ensure its backing layer exists
    /// under the parent window's popup layer (above the window content), position it
    /// at the parent-local placement, then set its content. Idempotent attach.
    func popupCommitted(
        surfaceID: UInt32, parentSurfaceID: UInt32,
        x: Double, y: Double, width: Double, height: Double,
        iosurfaceID: UInt32, generation: UInt64, sample: ContentSample? = nil
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
                content: LayerContent(kind: .external, handle: UInt64(iosurfaceID), generation: UInt64(generation)),
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
        for display in NucleusCompositorServer.shared.layout.displays {
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
        _ = MainActor.assumeIsolated {
            authoring("update background effect", surfaceID: UInt64(surfaceID)) {
                try author.setBackgroundEffect(
                    surfaceID: UInt64(surfaceID),
                    enabled: region != nil,
                    regions: Self.backgroundEffectRegions(from: region))
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
    /// safe. Returns whether any window's tile animation is still in flight, so the
    /// frame loop keeps requesting frames (the `actor_geometry_changed` signal). The
    /// render-server-coupled closing fade + content-crossfade *snapshot* still land
    /// at the swap (the opacity primitive already lives in the author).
    @discardableResult
    func authorFrame(outputID: UInt64, predictedPresentNs: UInt64) -> Bool {
        // Refresh this output's predicted-present clock; the spring samples it.
        // Hardware frame-request arming stays in the reactor.
        if let display = NucleusCompositorServer.shared.layout.display(id: outputID) {
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
        let locked = SessionLockGate.isActive()
        let windows = NucleusCompositorServer.shared.windows.windows.filter {
            $0.visibleInScene() && (!locked || $0.source == .lock)
        }
        let order = windows.map { UInt64($0.surfaceObjectId) }.filter { $0 != 0 }
        authoring("set window order") { try author.setWindowOrder(order) }

        let focusedID = NucleusCompositorServer.shared.windows.focusedWindow?.id
        var anyInFlight = false
        var authoredWindows: [PresentedWindow] = []
        for window in windows {
            let surfaceID = UInt64(window.surfaceObjectId)
            guard surfaceID != 0 else { continue }
            // Ease the presented frame one step toward the tile target, then author it.
            if window.advanceTileAnimation(presentTimeSeconds: presentSeconds) {
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
                // Snapshot-overlay opacity for an in-flight content crossfade (1 = inert).
                overlayOpacity: window.tileCrossfadeOpacity())
            }
            if authored {
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
