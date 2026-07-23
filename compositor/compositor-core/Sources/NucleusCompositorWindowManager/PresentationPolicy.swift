public import NucleusCompositorServer

@MainActor
extension WindowManager {
    public func shouldFocusOnMap(windowID: UInt64) -> Bool {
        guard let window = server.window(id: windowID), window.wantsKeyboardFocus else {
            return false
        }
        // Focus is allowed unless the window is occluded by its output's fullscreen
        // owner. Reuse the server's authoritative owner + occlusion predicates rather
        // than a local copy — the previous private activeFullscreenOwner omitted the
        // `!minimized` check the occlusion path enforces, so a minimized fullscreen
        // window wrongly blocked focus-on-map. (owner nil / owner == window both
        // resolve to "not occluded" → focus allowed.)
        let outputID = server.spaces.policyOutputID(for: window, layout: server.layout)
        let owner = server.fullscreenOwner(onOutput: outputID)
        return !server.isOccludedByFullscreen(window, owner: owner)
    }

    public func fullscreenRelinquishPlan(outputID: DisplayID, exceptID: UInt64, max: Int) -> [UInt64] {
        var ids: [UInt64] = []
        ids.reserveCapacity(min(max, server.windows.windows.count))
        for window in server.windows.windows {
            if window.id == exceptID { continue }
            if !window.isManagedAppWindow() { continue }
            if !window.requestedFullscreen && !window.activeFullscreen { continue }

            let requestedOutputID = server.spaces.resolveSpecialOutputID(
                for: window,
                layout: server.layout,
                nextActiveFullscreen: true,
                nextActiveMaximized: false
            )
            let policyOutputID = server.spaces.policyOutputID(for: window, layout: server.layout)
            if (requestedOutputID == nil || requestedOutputID != outputID) && policyOutputID != outputID {
                continue
            }

            ids.append(window.id)
            if ids.count == max { break }
        }
        return ids
    }
}

// The old exported `nucleus_compositor_window_manager_should_focus_on_map`
// wrapper previously lived here; it migrated to
// `WindowManager.evaluateFocusOnMap` in `WindowManager+CompositorPolicy.swift`.
// The Bool-returning impl on `WindowManager.shouldFocusOnMap` stays;
// the protocol method delegates to it.
