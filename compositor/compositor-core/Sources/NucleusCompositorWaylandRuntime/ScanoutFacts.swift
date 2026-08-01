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

internal import NucleusCompositorServer
import WaylandServer
import WaylandServerC

/// The dmabuf attributes of a fullscreen root's committed buffer, neutral of the
/// DRM module's `ScanoutDmabufInfo`.
package struct DmabufFacts: Sendable, Equatable {
    package var format: UInt32
    package var modifier: UInt64
    package var width: UInt32
    package var height: UInt32

    package init(format: UInt32, modifier: UInt64, width: UInt32, height: UInt32) {
        self.format = format
        self.modifier = modifier
        self.width = width
        self.height = height
    }
}

/// The single childless fullscreen toplevel owning an output: its scanout buffer
/// id, its layout + eased geometry, and its committed surface attributes.
package struct FullscreenRootFacts: Sendable, Equatable {
    package var rootIOSurfaceID: UInt64
    package var layoutX: Double
    package var layoutY: Double
    package var layoutWidth: UInt32
    package var layoutHeight: UInt32
    package var animatedX: Double
    package var animatedY: Double
    package var hasViewportTransform: Bool
    package var hasAlphaModifier: Bool
    package var currentWidth: UInt32
    package var currentHeight: UInt32
    package var dmabuf: DmabufFacts?

    package init(
        rootIOSurfaceID: UInt64,
        layoutX: Double, layoutY: Double, layoutWidth: UInt32, layoutHeight: UInt32,
        animatedX: Double, animatedY: Double,
        hasViewportTransform: Bool,
        hasAlphaModifier: Bool = false,
        currentWidth: UInt32, currentHeight: UInt32,
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
        self.hasAlphaModifier = hasAlphaModifier
        self.currentWidth = currentWidth
        self.currentHeight = currentHeight
        self.dmabuf = dmabuf
    }
}

/// One output's direct-scanout facts: the output-level block-reason inputs and the
/// fullscreen root candidate (nil when the output has no single childless fullscreen
/// toplevel). Output geometry is filled by the composition root from the `Display`.
package struct OutputScanoutFacts: Sendable, Equatable {
    package var sessionLocked = false
    package var screenshotCaptureActive = false
    package var notificationCount = 0
    package var hotkeyHasContent = false
    package var layerShellActiveOnOutput = false
    package var toplevelAnimationActiveOnOutput = false
    package var isShellOutput = false
    package var fullscreenRoot: FullscreenRootFacts?

    package init() {}
}

extension WaylandRuntime {
    /// Gather the per-output direct-scanout facts from the live window model. Empty
    /// until the router is activated. `@MainActor`: the compositor loop calls it on
    /// the main thread each frame, before the render pass.
    package func scanoutFacts() -> [UInt64: OutputScanoutFacts] {
        let server = host.server
        guard let runtime = host.runtime else { return [:] }
        let compositor = runtime.compositor
        let locked = host.sessionLockGate.isActive()
        guard !server.layout.displays.isEmpty else { return [:] }
        let shellOutputID = server.spaces.overlayDisplayID(layout: server.layout)

        var result: [UInt64: OutputScanoutFacts] = [:]
        for display in server.layout.displays {
            let outputID = display.id
            var facts = OutputScanoutFacts()
            facts.sessionLocked = locked
            facts.screenshotCaptureActive =
                runtime.screencopy.isCapturing(outputID: outputID)
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
                    surfaceID: surface.objectId, outputID: outputID)
            {
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
        let hasViewport =
            surface.aux.viewportSource != nil || surface.aux.viewportDestination != nil

        var dmabuf: DmabufFacts?
        if let buffer = surface.currentBuffer,
            let owner = buffer.retainedSemanticOwner(
                as: DmabufBuffer.self)
        {
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
            hasAlphaModifier:
                surface.aux.alphaMultiplier != .max,
            currentWidth: UInt32(surface.committedLogicalWidth.rounded()),
            currentHeight: UInt32(surface.committedLogicalHeight.rounded()),
            dmabuf: dmabuf)
    }
}
