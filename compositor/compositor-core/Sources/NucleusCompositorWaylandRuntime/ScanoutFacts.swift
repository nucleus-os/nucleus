// The DRM backend decides direct-scanout eligibility, but the evaluator's inputs
// live in this module's window model (WlCompositor / WlSurface / the session-lock
// gate / the layer-shell registry) and the shared server. The DRM module must not
// depend on the model, so — exactly as the session-lock composition does — this
// facade gathers the per-output facts into a neutral Sendable struct each frame,
// and the composition root translates them into the DRM module's `ScanoutCandidate`
// and pushes them down. No DRM type appears here.
//
// A per-output candidate exists only when a single, childless fullscreen toplevel
// owns the output: the primary-plane single-surface scanout can show exactly one
// surface, so a fullscreen window with any live popup is not a candidate (its
// `fullscreenRoot` is nil → the evaluator blocks it). Subsurface gating and the
// screencopy / notification-overlay inputs (no live source reachable here yet) are
// combined with shell-overlay facts by the composition root.

import WaylandServerC
import WaylandServer
import NucleusCompositorServer

/// The dmabuf attributes of a fullscreen root's committed buffer, neutral of the
/// DRM module's `ScanoutDmabufInfo`.
public struct DmabufFacts: Sendable, Equatable {
    public var format: UInt32
    public var modifier: UInt64
    public var width: UInt32
    public var height: UInt32

    public init(format: UInt32, modifier: UInt64, width: UInt32, height: UInt32) {
        self.format = format
        self.modifier = modifier
        self.width = width
        self.height = height
    }
}

/// The single childless fullscreen toplevel owning an output: its scanout buffer
/// id, its layout + eased geometry, and its committed surface attributes.
public struct FullscreenRootFacts: Sendable, Equatable {
    public var rootIOSurfaceID: UInt64
    public var layoutX: Double
    public var layoutY: Double
    public var layoutWidth: UInt32
    public var layoutHeight: UInt32
    public var animatedX: Double
    public var animatedY: Double
    public var hasViewportTransform: Bool
    public var currentWidth: UInt32
    public var currentHeight: UInt32
    public var dmabuf: DmabufFacts?

    public init(
        rootIOSurfaceID: UInt64,
        layoutX: Double, layoutY: Double, layoutWidth: UInt32, layoutHeight: UInt32,
        animatedX: Double, animatedY: Double,
        hasViewportTransform: Bool, currentWidth: UInt32, currentHeight: UInt32,
        dmabuf: DmabufFacts?
    ) {
        self.rootIOSurfaceID = rootIOSurfaceID
        self.layoutX = layoutX
        self.layoutY = layoutY
        self.layoutWidth = layoutWidth
        self.layoutHeight = layoutHeight
        self.animatedX = animatedX
        self.animatedY = animatedY
        self.hasViewportTransform = hasViewportTransform
        self.currentWidth = currentWidth
        self.currentHeight = currentHeight
        self.dmabuf = dmabuf
    }
}

/// One output's direct-scanout facts: the output-level block-reason inputs and the
/// fullscreen root candidate (nil when the output has no single childless fullscreen
/// toplevel). Output geometry is filled by the composition root from the `Display`.
public struct OutputScanoutFacts: Sendable, Equatable {
    public var sessionLocked = false
    public var screenshotCaptureActive = false
    public var notificationCount = 0
    public var hotkeyHasContent = false
    public var layerShellActiveOnOutput = false
    public var toplevelAnimationActiveOnOutput = false
    public var isShellOutput = false
    public var fullscreenRoot: FullscreenRootFacts?

    public init() {}
}

public extension WaylandRuntime {
    /// Gather the per-output direct-scanout facts from the live window model. Empty
    /// until the router is activated. `@MainActor`: the compositor loop calls it on
    /// the main thread each frame, before the render pass.
    func scanoutFacts() -> [UInt64: OutputScanoutFacts] {
        let server = host.server
        guard let runtime = host.runtime else { return [:] }
        let compositor = runtime.compositor
        let locked = host.sessionLockGate.isActive()
        let capturing = ScreencopyActivity.isCapturing
        guard !server.layout.displays.isEmpty else { return [:] }
        let shellOutputID = server.spaces.overlayDisplayID(layout: server.layout)

        var result: [UInt64: OutputScanoutFacts] = [:]
        for display in server.layout.displays {
            let outputID = display.id
            var facts = OutputScanoutFacts()
            facts.sessionLocked = locked
            facts.screenshotCaptureActive = capturing
            facts.isShellOutput = (outputID == shellOutputID)
            facts.layerShellActiveOnOutput = compositor.hasMappedLayerSurface(on: outputID)
            // notificationCount / hotkeyHasContent are the native-overlay inputs; the
            // overlay scene lives in the shell module (not reachable here), so the
            // composition root supplies the runtime-owned shell overlay activity
            // when it builds the candidate (they gate only the shell output).

            // The topmost fullscreen toplevel on this output + whether any toplevel on
            // it is mid-tile-animation (the per-window animation state, output-scoped —
            // the feeder's frame Bool is scene-global).
            var animating = false
            var fullscreenWindow: Window?
            for window in server.windows.windows where window.currentOutputID == outputID {
                if window.hasActiveTileAnimation()
                    || window.presentationActor.transition != nil
                {
                    animating = true
                }
                if window.activeFullscreen, fullscreenWindow == nil { fullscreenWindow = window }
            }
            facts.toplevelAnimationActiveOnOutput = animating

            // A candidate only when the fullscreen root is a single childless surface
            // (no live popup, no subsurface) — single-surface scanout shows exactly one
            // surface, so any child would be dropped.
            if let window = fullscreenWindow,
               let surface = compositor.surface(id: window.surfaceObjectId),
               compositor.popupCount(forParentSurfaceId: window.surfaceObjectId) == 0,
               surface.subsurfaceChildren.isEmpty,
               let authored = host.feeder?.pendingWindow(
                   surfaceID: surface.objectId, outputID: outputID) {
                facts.fullscreenRoot = Self.fullscreenRootFacts(
                    window: window, surface: surface, authored: authored)
            }
            result[outputID] = facts
        }
        return result
    }

    @MainActor private static func fullscreenRootFacts(
        window: Window, surface: WlSurface, authored: SceneFeeder.PresentedWindow
    ) -> FullscreenRootFacts {
        let layout = window.currentRect()
        let presented = authored.frame
        let hasViewport = surface.aux.viewportSource != nil || surface.aux.viewportDestination != nil

        var dmabuf: DmabufFacts?
        if let buffer = surface.currentBuffer,
           let owner = WaylandResource.owner(of: buffer, as: DmabufBuffer.self) {
            let attrs = owner.attrs
            dmabuf = DmabufFacts(
                format: attrs.format, modifier: attrs.modifier,
                width: UInt32(bitPattern: attrs.width), height: UInt32(bitPattern: attrs.height))
        }

        return FullscreenRootFacts(
            rootIOSurfaceID: UInt64(surface.renderIosurfaceId),
            layoutX: layout.x, layoutY: layout.y,
            layoutWidth: layout.width, layoutHeight: layout.height,
            animatedX: presented.x, animatedY: presented.y,
            hasViewportTransform: hasViewport,
            currentWidth: UInt32(surface.committedLogicalWidth.rounded()),
            currentHeight: UInt32(surface.committedLogicalHeight.rounded()),
            dmabuf: dmabuf)
    }
}
