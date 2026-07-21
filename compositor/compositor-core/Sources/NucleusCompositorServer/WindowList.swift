@MainActor
public final class WindowList {
    private var items: [Window] = []
    /// Identity index over `items`. The authoritative `id -> Window` map (the server
    /// delegates `window(id:)` here rather than keeping a parallel dictionary), which
    /// also makes the family-tree walks O(1) per hop instead of O(n).
    private var byID: [WindowID: Window] = [:]
    /// `surfaceObjectId -> Window` index for the hot per-commit / per-input-event
    /// surface→window resolution. Maintained on add/remove and, when a window's
    /// `surfaceObjectId` is (re)assigned after add, through `onSurfaceObjectIdChange`.
    private var bySurfaceObjectId: [UInt32: Window] = [:]
    private var focusedWindowID: WindowID?
    /// Records lifecycle/focus changes for the observation stream. Set by the
    /// owning `NucleusCompositorServer`; nil leaves the list silent.
    public var onChange: ((DesktopChange) -> Void)?

    public init() {}

    public var windows: [Window] { items }
    public var windowCount: Int { items.count }
    public var focusedWindow: Window? { focusedWindowID.flatMap(window(id:)) }

    public func window(id: WindowID) -> Window? {
        byID[id]
    }

    /// Resolve the window backing a Wayland surface wire id (`Window.surfaceObjectId`).
    /// The router's input/session-lock crossings use this to answer "which window owns
    /// this surface" without holding a window pointer across the `@c` boundary.
    public func window(bySurfaceObjectId surfaceObjectId: UInt32) -> Window? {
        guard surfaceObjectId != 0 else { return nil }
        return bySurfaceObjectId[surfaceObjectId]
    }

    public func add(_ window: Window) {
        if byID[window.id] != nil { return }
        items.insert(window, at: insertionIndex(forLevel: window.level))
        byID[window.id] = window
        if window.surfaceObjectId != 0 { bySurfaceObjectId[window.surfaceObjectId] = window }
        // The callbacks are installed only while this list strongly owns the
        // window and are cleared on every detach path. An unowned capture
        // expresses that invariant without allocating a weak-reference side
        // table for the process-lifetime compositor list.
        window.onSurfaceObjectIdChange = { [unowned self] w, old in
            if old != 0, self.bySurfaceObjectId[old] === w { self.bySurfaceObjectId[old] = nil }
            if w.surfaceObjectId != 0 { self.bySurfaceObjectId[w.surfaceObjectId] = w }
        }
        // A level change after add must re-sort the window into its new band, or the
        // level-sorted `items` invariant breaks (e.g. an Xwayland _NET_WM_STATE_ABOVE
        // toggle that previously mutated `level` without restacking).
        window.onLevelChange = { [unowned self] w in
            _ = self.restackByLevel(id: w.id)
        }
        onChange?(.windowAdded(window.id))
    }

    @discardableResult
    public func remove(id: WindowID) -> Window? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = items.remove(at: index)
        byID[id] = nil
        if removed.surfaceObjectId != 0, bySurfaceObjectId[removed.surfaceObjectId] === removed {
            bySurfaceObjectId[removed.surfaceObjectId] = nil
        }
        removed.onSurfaceObjectIdChange = nil
        removed.onLevelChange = nil
        let clearedFocus = focusedWindowID == id
        if clearedFocus { focusedWindowID = nil }
        onChange?(.windowRemoved(id))
        if clearedFocus { onChange?(.focusChanged(nil)) }
        return removed
    }

    @discardableResult
    public func raise(id: WindowID) -> Bool {
        guard byID[id] != nil else { return false }
        // Raise the whole window family (the clicked window's root ancestor and
        // all of its descendants), not just the one window, so a parent and its
        // dialogs travel together and a child is never left below its parent.
        // Re-inserting root-first then descendants in their existing back-to-front
        // order puts every child above its parent and preserves intra-family order.
        let root = familyRoot(of: id)
        for member in familyMembers(rootID: root) {
            guard let index = items.firstIndex(where: { $0.id == member }) else { continue }
            let window = items.remove(at: index)
            items.insert(window, at: insertionIndex(forLevel: window.level))
        }
        return true
    }

    /// Walk `parentWindowID` up to the topmost ancestor still present in the
    /// list. A dangling parent (closed) or a cycle terminates the walk, so the
    /// window becomes its own root.
    private func familyRoot(of id: WindowID) -> WindowID {
        var current = id
        var guardCount = 0
        while guardCount < items.count {
            guard let window = window(id: current),
                  let parent = window.parentWindowID,
                  byID[parent] != nil
            else { return current }
            current = parent
            guardCount += 1
        }
        return current
    }

    /// `rootID` followed by every window whose family root is `rootID`, the
    /// descendants kept in current back-to-front order.
    private func familyMembers(rootID: WindowID) -> [WindowID] {
        var members: [WindowID] = [rootID]
        for window in items where window.id != rootID && familyRoot(of: window.id) == rootID {
            members.append(window.id)
        }
        return members
    }

    @discardableResult
    public func restackByLevel(id: WindowID) -> Bool {
        raise(id: id)
    }

    @discardableResult
    public func place(id: WindowID, below siblingID: WindowID) -> Bool {
        guard let windowIndex = items.firstIndex(where: { $0.id == id }),
              let siblingIndex = items.firstIndex(where: { $0.id == siblingID })
        else { return false }
        let window = items.remove(at: windowIndex)
        let adjustedSiblingIndex = windowIndex < siblingIndex ? siblingIndex - 1 : siblingIndex
        // Keep the window within its own level band: placing purely by sibling index
        // could drop it into a different band and corrupt the level-sorted invariant
        // that insertionIndex/raise rely on. Clamp the target to [bandStart, bandEnd].
        var bandStart = 0
        while bandStart < items.count && items[bandStart].level < window.level { bandStart += 1 }
        var bandEnd = bandStart
        while bandEnd < items.count && items[bandEnd].level == window.level { bandEnd += 1 }
        let target = min(max(adjustedSiblingIndex, bandStart), bandEnd)
        items.insert(window, at: target)
        return true
    }

    @discardableResult
    public func focus(id: WindowID) -> Bool {
        guard byID[id] != nil else { return false }
        guard focusedWindowID != id else { return true }
        focusedWindowID = id
        onChange?(.focusChanged(id))
        return true
    }

    public func orderedIDs() -> [WindowID] {
        items.map(\.id)
    }

    public func frontToBackOrderedIDs() -> [WindowID] {
        items.reversed().map(\.id)
    }

    /// Windows ordered front-most first (top of the z-order first). The inverse
    /// of the back-to-front `windows` accessor.
    public var windowsFrontToBack: [Window] { items.reversed() }

    /// Back-to-front z-order index of `id` (0 = farthest back), or nil if absent.
    /// The tiebreak coordinate the fullscreen-occlusion predicate compares.
    public func backToFrontIndex(of id: WindowID) -> Int? {
        items.firstIndex { $0.id == id }
    }

    public func reset() {
        for window in items {
            window.onSurfaceObjectIdChange = nil
            window.onLevelChange = nil
        }
        items.removeAll(keepingCapacity: true)
        byID.removeAll(keepingCapacity: true)
        bySurfaceObjectId.removeAll(keepingCapacity: true)
        focusedWindowID = nil
    }

    isolated deinit {
        for window in items {
            window.onSurfaceObjectIdChange = nil
            window.onLevelChange = nil
        }
    }

    private func insertionIndex(forLevel level: Int32) -> Int {
        var index = 0
        while index < items.count && items[index].level <= level {
            index += 1
        }
        return index
    }
}

public struct WindowTransition: Sendable, Equatable {
    public var id: UInt64 = 0
    public var outputID: DisplayID?
    public var participantCount: UInt32 = 0

    public var isActive: Bool { id != 0 }
}
