import NucleusCompositorServerTypes

public struct Space: Sendable, Equatable {
    public var id: SpaceID
    public var name: String
    /// The output this workspace belongs to. Workspaces are per-output (niri-like):
    /// each display owns its own set, switched independently, and a workspace may
    /// only ever hold windows on its output.
    public var outputID: DisplayID
}

// `RequestedSpecialMode` is the generated wire type itself: its three flags are
// `Bool` accessors (the wire keeps `u8`), and the generated init defaults the
// reserved field, so `RequestedSpecialMode(activeMaximized:activeFullscreen:willSpecial:)`
// constructs directly.
public typealias RequestedSpecialMode = WireRequestedSpecialMode

public struct LayoutRects: Sendable, Equatable {
    public var fullscreen: WindowRect
    public var maximized: WindowRect
    public var `default`: WindowRect

    public init(fullscreen: WindowRect, maximized: WindowRect, default: WindowRect) {
        self.fullscreen = fullscreen
        self.maximized = maximized
        self.default = `default`
    }
}

@MainActor
public final class Spaces {
    public private(set) var spaces: [Space] = []
    private var activeSpaceByDisplay: [DisplayID: SpaceID] = [:]
    private var overlayDisplayID: DisplayID?
    private var spaceByWindow: [WindowID: SpaceID] = [:]
    private var windowsBySpace: [SpaceID: Set<WindowID>] = [:]
    private var nextSpaceID: SpaceID = 1
    /// Records space changes for the observation stream. Set by the owning
    /// `NucleusCompositorServer`; nil leaves the model silent.
    public var onChange: ((DesktopChange) -> Void)?

    // Workspaces are created per-output on `ensureDisplay`, not eagerly, so the
    // model starts empty and grows with the output topology.
    public init() {}

    @discardableResult
    public func createSpace(name: String, outputID: DisplayID) -> SpaceID {
        let id = nextSpaceID
        nextSpaceID &+= 1
        spaces.append(Space(id: id, name: name, outputID: outputID))
        windowsBySpace[id] = []
        onChange?(.spaceAdded(id))
        return id
    }

    /// All workspaces on an output, in creation order.
    public func spaces(forOutput outputID: DisplayID) -> [Space] {
        spaces.filter { $0.outputID == outputID }
    }

    /// Get-or-create the `index`-th (1-based) workspace on an output, creating any
    /// missing leading workspaces so the index is always reachable. Drives the
    /// Super+N keybind's create-on-demand (niri-like dynamic numbering). Index 0
    /// is invalid and returns 0.
    public func ensureWorkspace(onOutput outputID: DisplayID, index: Int) -> SpaceID {
        guard index >= 1 else { return 0 }
        var outputSpaces = spaces(forOutput: outputID)
        while outputSpaces.count < index {
            _ = createSpace(name: "\(outputSpaces.count + 1)", outputID: outputID)
            outputSpaces = spaces(forOutput: outputID)
        }
        return outputSpaces[index - 1].id
    }

    /// Append a new workspace to an output, numbered by its position. Drives the
    /// ext-workspace `create_workspace` request (the client's requested name is
    /// advisory and not honored — workspaces are numbered).
    @discardableResult
    public func appendWorkspace(onOutput outputID: DisplayID) -> SpaceID {
        let n = spaces(forOutput: outputID).count + 1
        return createSpace(name: "\(n)", outputID: outputID)
    }

    public func ensureDisplay(_ displayID: DisplayID) {
        if overlayDisplayID == nil { overlayDisplayID = displayID }
        if activeSpaceByDisplay[displayID] == nil {
            let existing = spaces.first { $0.outputID == displayID }?.id
            activeSpaceByDisplay[displayID] = existing ?? createSpace(name: "1", outputID: displayID)
        }
    }

    public func removeDisplay(_ displayID: DisplayID, layout: DesktopLayout) {
        activeSpaceByDisplay[displayID] = nil
        if overlayDisplayID == displayID {
            overlayDisplayID = layout.primaryOutputID ?? layout.displays.first?.id
        }
        // Drop this output's workspaces; any windows still on them are reassigned to
        // their new output's active space when they next map (windowSetMapped path).
        let removed = spaces.filter { $0.outputID == displayID }
        guard !removed.isEmpty else { return }
        spaces.removeAll { $0.outputID == displayID }
        for space in removed {
            for windowID in windowsBySpace[space.id] ?? [] { spaceByWindow[windowID] = nil }
            windowsBySpace[space.id] = nil
            onChange?(.spaceRemoved(space.id))
        }
    }

    /// Switch an output's active workspace. Emits `spaceActivated`; the scene
    /// visibility refresh and focus move are driven by the caller
    /// (`activateSpace`).
    @discardableResult
    public func setActiveSpace(_ spaceID: SpaceID, forDisplay displayID: DisplayID) -> Bool {
        guard let space = spaces.first(where: { $0.id == spaceID }), space.outputID == displayID else { return false }
        guard activeSpaceByDisplay[displayID] != spaceID else { return true }
        activeSpaceByDisplay[displayID] = spaceID
        onChange?(.spaceActivated(output: displayID, space: spaceID))
        return true
    }

    /// Rename a workspace. Emits `spaceChanged`.
    @discardableResult
    public func renameSpace(_ spaceID: SpaceID, to name: String) -> Bool {
        guard let index = spaces.firstIndex(where: { $0.id == spaceID }) else { return false }
        guard spaces[index].name != name else { return true }
        spaces[index].name = name
        onChange?(.spaceChanged(spaceID))
        return true
    }

    /// Remove a workspace. Refuses an output's active workspace or a non-empty one,
    /// so removal is safe and never strands windows. Emits `spaceRemoved`.
    @discardableResult
    public func removeSpace(_ spaceID: SpaceID) -> Bool {
        guard let space = spaces.first(where: { $0.id == spaceID }) else { return false }
        if activeSpaceByDisplay[space.outputID] == spaceID { return false }
        if !(windowsBySpace[spaceID] ?? []).isEmpty { return false }
        spaces.removeAll { $0.id == spaceID }
        windowsBySpace[spaceID] = nil
        onChange?(.spaceRemoved(spaceID))
        return true
    }

    public func overlayDisplayID(layout: DesktopLayout) -> DisplayID {
        if let id = overlayDisplayID, layout.display(id: id) != nil {
            return id
        }
        if let id = layout.primaryOutputID ?? layout.displays.first?.id {
            return id
        }
        preconditionFailure("overlay display requested with no displays")
    }

    public func activeSpace(forDisplay displayID: DisplayID) -> SpaceID? {
        activeSpaceByDisplay[displayID]
    }

    public func assign(window windowID: WindowID, toSpace spaceID: SpaceID) -> Bool {
        guard spaces.contains(where: { $0.id == spaceID }) else { return false }
        if let previous = spaceByWindow[windowID] {
            windowsBySpace[previous]?.remove(windowID)
        }
        spaceByWindow[windowID] = spaceID
        windowsBySpace[spaceID, default: []].insert(windowID)
        onChange?(.windowSpaceChanged(window: windowID, space: spaceID))
        return true
    }

    public func assignedSpace(forWindow windowID: WindowID) -> SpaceID? {
        spaceByWindow[windowID]
    }

    /// Whether a window is hidden by workspace state: it is assigned to a
    /// workspace that is not its output's active one. A window with no assignment
    /// (layer-shell, never-mapped, unmanaged) is never space-hidden. This is the
    /// single source of truth the scene author mirrors into `Window.space_hidden`.
    public func isSpaceHidden(window windowID: WindowID) -> Bool {
        guard let spaceID = spaceByWindow[windowID],
              let space = spaces.first(where: { $0.id == spaceID }) else { return false }
        return activeSpaceByDisplay[space.outputID] != spaceID
    }

    /// Assign a window to its output's active workspace when it maps. Keeps an
    /// existing explicit assignment on the *same* output (so a deliberate
    /// move-to-workspace sticks across remaps), but a window that has moved to a
    /// new output joins that output's active workspace.
    public func assignToActiveSpace(window windowID: WindowID, outputID: DisplayID) {
        let activeID: SpaceID
        if let id = activeSpaceByDisplay[outputID] {
            activeID = id
        } else {
            activeID = createSpace(name: "1", outputID: outputID)
            activeSpaceByDisplay[outputID] = activeID
        }
        if let current = spaceByWindow[windowID],
           let currentSpace = spaces.first(where: { $0.id == current }),
           currentSpace.outputID == outputID
        {
            return
        }
        _ = assign(window: windowID, toSpace: activeID)
    }

    public func windowIDs(inSpace spaceID: SpaceID) -> Set<WindowID> {
        windowsBySpace[spaceID] ?? []
    }

    public func validOutputID(_ outputID: DisplayID?, layout: DesktopLayout) -> DisplayID? {
        guard let outputID, layout.display(id: outputID) != nil else { return nil }
        return outputID
    }

    public func fallbackOutput(for window: Window?, layout: DesktopLayout) -> Display {
        if let window {
            for candidate in [window.currentOutputID, window.preferredOutputID, window.restoreOutputID, window.specialOutputID] {
                if let id = validOutputID(candidate, layout: layout), let display = layout.display(id: id) {
                    return display
                }
            }
        }
        guard let primary = (layout.primaryOutputID.flatMap { layout.display(id: $0) } ?? layout.displays.first) else {
            preconditionFailure("fallback output requested with no displays")
        }
        return primary
    }

    public func policyOutputID(for window: Window, layout: DesktopLayout) -> DisplayID {
        if !window.isManagedAppWindow() {
            return fallbackOutput(for: window, layout: layout).id
        }
        if let pending = window.protocolState.latest,
           pending.activeFullscreen || pending.activeMaximized,
           let outputID = validOutputID(pending.specialOutputID, layout: layout)
        {
            return outputID
        }
        if window.activeFullscreen || window.activeMaximized,
           let outputID = validOutputID(window.specialOutputID, layout: layout)
        {
            return outputID
        }
        return fallbackOutput(for: window, layout: layout).id
    }

    public func resolveRequestedFullscreenOutputID(for window: Window, layout: DesktopLayout) -> DisplayID {
        if !window.isManagedAppWindow() {
            return fallbackOutput(for: window, layout: layout).id
        }
        switch window.fullscreenTarget {
        case .automatic:
            break
        case .output(let outputID):
            if layout.display(id: outputID) != nil { return outputID }
        }
        if window.activeFullscreen, let outputID = validOutputID(window.specialOutputID, layout: layout) {
            return outputID
        }
        if let pending = window.protocolState.latest,
           pending.activeFullscreen,
           let outputID = validOutputID(pending.specialOutputID, layout: layout)
        {
            return outputID
        }
        return fallbackOutput(for: window, layout: layout).id
    }

    public func resolveSpecialOutputID(for window: Window, layout: DesktopLayout, nextActiveFullscreen: Bool, nextActiveMaximized: Bool) -> DisplayID? {
        if nextActiveFullscreen {
            return resolveRequestedFullscreenOutputID(for: window, layout: layout)
        }
        if nextActiveMaximized {
            if let pending = window.protocolState.latest,
               pending.activeMaximized,
               let outputID = validOutputID(pending.specialOutputID, layout: layout)
            {
                return outputID
            }
            if let outputID = validOutputID(window.specialOutputID, layout: layout) {
                return outputID
            }
            return fallbackOutput(for: window, layout: layout).id
        }
        return nil
    }

    public func placementOutput(for window: Window?, layout: DesktopLayout, fullscreen: Bool) -> Display {
        if let window {
            if fullscreen {
                return layout.display(id: resolveRequestedFullscreenOutputID(for: window, layout: layout)) ??
                    fallbackOutput(for: window, layout: layout)
            }
            if window.activeMaximized || window.requestedMaximized,
               let outputID = validOutputID(window.specialOutputID, layout: layout),
               let output = layout.display(id: outputID)
            {
                return output
            }
            return fallbackOutput(for: window, layout: layout)
        }
        guard let primary = (layout.primaryOutputID.flatMap { layout.display(id: $0) } ?? layout.displays.first) else {
            preconditionFailure("placement output requested with no displays")
        }
        return primary
    }

    public func placementOutputID(for window: Window?, layout: DesktopLayout, fullscreen: Bool) -> DisplayID {
        placementOutput(for: window, layout: layout, fullscreen: fullscreen).id
    }

    public func fullscreenLayoutRect(for output: Display) -> WindowRect {
        WindowRect(
            x: output.logicalRect.x,
            y: output.logicalRect.y,
            width: UInt32(max(1, output.logicalRect.width.rounded(.up))),
            height: UInt32(max(1, output.logicalRect.height.rounded(.up)))
        )
    }

    public func maximizedLayoutRect(for output: Display, usable: UsableArea) -> WindowRect {
        WindowRect(
            x: output.logicalRect.x + Double(usable.x),
            y: output.logicalRect.y + Double(usable.y),
            width: UInt32(max(1, usable.w)),
            height: UInt32(max(1, usable.h))
        )
    }

    public func defaultWindowRect(for output: Display, usable: UsableArea) -> WindowRect {
        let defaultWidth = UInt32(max(1, min(usable.w, 800)))
        let defaultHeight = UInt32(max(1, min(usable.h, 600)))
        let maxX = max(0, usable.w - Int32(defaultWidth))
        let maxY = max(0, usable.h - Int32(defaultHeight))
        return WindowRect(
            x: output.logicalRect.x + Double(usable.x) + Double(maxX / 2),
            y: output.logicalRect.y + Double(usable.y) + Double(maxY / 2),
            width: defaultWidth,
            height: defaultHeight
        )
    }

    public func translateRectToOutput(
        _ rect: WindowRect,
        fromOutputID: DisplayID?,
        fromUsable: UsableArea?,
        toOutput: Display,
        toUsable: UsableArea,
        layout: DesktopLayout
    ) -> WindowRect {
        let newWidth = UInt32(max(1, min(Int32(rect.width), toUsable.w)))
        let newHeight = UInt32(max(1, min(Int32(rect.height), toUsable.h)))
        let maxCenteredX = max(0, toUsable.w - Int32(newWidth))
        let maxCenteredY = max(0, toUsable.h - Int32(newHeight))
        var newX = toOutput.logicalRect.x + Double(toUsable.x) + Double(maxCenteredX / 2)
        var newY = toOutput.logicalRect.y + Double(toUsable.y) + Double(maxCenteredY / 2)

        if let fromOutputID = validOutputID(fromOutputID, layout: layout),
           let oldOutput = layout.display(id: fromOutputID),
           let fromUsable
        {
            let relativeX = rect.x - (oldOutput.logicalRect.x + Double(fromUsable.x))
            let relativeY = rect.y - (oldOutput.logicalRect.y + Double(fromUsable.y))
            let maxX = max(0, toUsable.w - Int32(newWidth))
            let maxY = max(0, toUsable.h - Int32(newHeight))
            newX = toOutput.logicalRect.x + Double(toUsable.x) + min(max(relativeX, 0), Double(maxX))
            newY = toOutput.logicalRect.y + Double(toUsable.y) + min(max(relativeY, 0), Double(maxY))
        }

        return WindowRect(x: newX, y: newY, width: newWidth, height: newHeight)
    }

    public func requestedSpecialMode(for window: Window) -> RequestedSpecialMode {
        let activeFullscreen = window.requestedFullscreen
        let activeMaximized = !activeFullscreen && window.requestedMaximized
        return RequestedSpecialMode(
            activeMaximized: activeMaximized,
            activeFullscreen: activeFullscreen,
            willSpecial: activeFullscreen || activeMaximized
        )
    }

    public func desiredLayoutRect(for window: Window, rects: LayoutRects) -> WindowRect {
        if window.requestedFullscreen { return rects.fullscreen }
        if window.requestedMaximized { return rects.maximized }
        if let restore = window.restoreRect { return restore }
        // An unmapped window has no committed size yet. The default rect provides
        // the provisional placement; for a self-sizing xdg window the compositor
        // sends 0x0 on the wire (it owns its size) and recenters the committed
        // size at first commit, so this rect's size is only a fallback.
        if !window.mapped { return rects.default }
        return window.currentRect()
    }

    public func reset() {
        spaces.removeAll(keepingCapacity: true)
        activeSpaceByDisplay.removeAll(keepingCapacity: true)
        overlayDisplayID = nil
        spaceByWindow.removeAll(keepingCapacity: true)
        windowsBySpace.removeAll(keepingCapacity: true)
        nextSpaceID = 1
    }
}
