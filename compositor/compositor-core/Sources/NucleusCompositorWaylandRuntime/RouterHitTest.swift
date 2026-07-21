// Router-side pointer hit-testing against the authoritative Swift window model.
//
// The input feed calls `nucleus_runtime_hit_test` with a logical
// cursor position; this resolves which window — and which surface within that
// window's subsurface tree — is under the point, returning the surface's wire id
// (the same id space `nucleus_runtime_seat_*` delivery uses) plus surface-local
// coordinates, the owning window id + source, and (when the point lands on
// server-drawn chrome) the chrome region + resize edges. This is the single call
// that replaces the substrate `LayerHitTest` scene walk + per-window chrome
// classification, neither of which can see router-authored windows.
//
// Coordinate model: `sx`/`sy` are logical screen pixels. A window's frame is the
// exact last successfully authored presented rect, widened by the resize-grab outset so the invisible
// resize border just outside the frame still claims the window. Chrome wins at the
// frame boundary: a point is classified against `WindowFrameView` first, and only a
// `content` classification falls through to the client surface tree (the root
// surface fills the content area = frame inset by `chromeInsets`; subsurfaces are
// positioned at parent-local `subsurfaceX/Y`, each accepting input over its
// `set_input_region` if set, else its committed content extent). A content point
// covered by no client surface falls through to the window below, matching the
// substrate scene walk.

import WaylandServerC
import NucleusCompositorServer

/// How far outside the frame edge the invisible resize-grab band reaches (the macOS
/// all-edge resize border). Mirrors the substrate `chrome_grab_outset`.
private let chromeGrabOutset: Double = 6

/// The result of a hit-test against the window model. Computed on the main actor;
/// the request boundary writes it into the caller's out-params off the isolated
/// closure (Swift 6 region isolation forbids writing through the borrowed pointers
/// inside the closure). The Swift input dispatch consumes it directly.
struct HitResult {
    var surfaceId: UInt64 = 0
    var windowId: UInt64 = 0
    var windowSource: UInt32 = 0
    var chromeRegion: UInt32 = 0
    var chromeEdges: UInt32 = 0
    var localX: Double = 0
    var localY: Double = 0
}

/// Hit-test the window model at logical point (`sx`, `sy`), returning the topmost
/// client surface under the point (surfaceId 0 = over chrome / miss), the owning
/// window id + source, surface-local coordinates on a surface hit, and the chrome
/// region/edges on a chrome hit. The single Swift-native walk both the input
/// dispatch and the `nucleus_runtime_hit_test` crossing share.
@MainActor
func routerHitTest(sx: Double, sy: Double) -> HitResult {
    guard let runtime = RouterHost.shared.runtime else { return HitResult() }
    let compositor = runtime.compositor
    let server = NucleusCompositorServer.shared
    guard let feeder = RouterHost.shared.feeder else { return HitResult() }

    let occluded = server.fullscreenOccludedWindowIDs()
    for presented in feeder.presentedWindows(atX: sx, y: sy) {
        guard let window = server.window(id: presented.windowID) else { continue }
        guard window.eligibleForInput() else { continue }
        if occluded.contains(window.id) { continue }

        let frame = presented.frame
        // The frame claim is widened by the resize-grab outset so the band just
        // outside the edge is still classified (as a resize edge).
        guard sx >= frame.x - chromeGrabOutset, sx < frame.x + frame.w + chromeGrabOutset,
            sy >= frame.y - chromeGrabOutset, sy < frame.y + frame.h + chromeGrabOutset
        else { continue }

        // Chrome wins at the frame boundary: classify the frame-local point before
        // consulting the client surface tree.
        let chrome = window.frameView.classify(
            x: sx - frame.x, y: sy - frame.y, frameWidth: frame.w, frameHeight: frame.h)
        if chrome.region != .content {
            return HitResult(
                windowId: presented.windowID, windowSource: presented.source,
                chromeRegion: chrome.region.rawValue, chromeEdges: chrome.edges.rawValue)
        }

        // Content: resolve to a client surface in the subsurface tree. A point over
        // the content area covered by no surface falls through to the window below
        // (matching the substrate scene walk).
        guard let root = compositor.surface(id: window.surfaceObjectId) else { continue }
        let insets = window.chromeInsets
        let rootLocalX = sx - (frame.x + insets.left)
        let rootLocalY = sy - (frame.y + insets.top)
        if let hit = hitTestSurfaceTree(root, localX: rootLocalX, localY: rootLocalY) {
            return HitResult(
                surfaceId: UInt64(hit.surfaceId), windowId: presented.windowID,
                windowSource: presented.source, localX: hit.localX, localY: hit.localY)
        }
    }
    return HitResult()
}

// The Swift input dispatch calls `routerHitTest` directly
// (InputDispatch.swift) and the popup-grab dismissal is
// Swift-direct. The `routerHitTest` walk + its surface-tree helpers run in-process.

/// Recursively resolve the topmost surface in `surface`'s subsurface tree that
/// accepts input at parent-local (`localX`, `localY`). Children stack above the
/// parent's own content, so they are tested topmost-first; the parent's content is
/// the fallthrough. Returns the hit surface's wire id and its surface-local point.
@MainActor
private func hitTestSurfaceTree(
    _ surface: WlSurface, localX: Double, localY: Double
) -> (surfaceId: UInt32, localX: Double, localY: Double)? {
    // `subsurfaceChildren` is bottom-to-top; iterate reversed for topmost-first.
    for child in surface.subsurfaceChildren.reversed() {
        let childX = localX - Double(child.subsurfaceX)
        let childY = localY - Double(child.subsurfaceY)
        if let hit = hitTestSurfaceTree(child, localX: childX, localY: childY) {
            return hit
        }
    }
    if surfaceAcceptsInput(surface, localX: localX, localY: localY) {
        return (surface.objectId, localX, localY)
    }
    return nil
}

/// A surface accepts input at a surface-local point if the point falls inside its
/// `set_input_region` (when set), else inside its committed content extent.
@MainActor
private func surfaceAcceptsInput(_ surface: WlSurface, localX: Double, localY: Double) -> Bool {
    if let region = surface.inputRegion {
        return region.contains(x: localX, y: localY)
    }
    return localX >= 0 && localX < surface.committedLogicalWidth
        && localY >= 0 && localY < surface.committedLogicalHeight
}
