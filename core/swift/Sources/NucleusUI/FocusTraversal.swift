/// Keyboard focus traversal over a view tree.
///
/// AppKit's key-view loop is an explicit linked list authored per window
/// (`nextKeyView`). That is wrong for a tree that is rebuilt from a body
/// closure: every rebuild would have to re-thread the loop, and a builder that
/// forgot would silently strand a control. Order here is derived from tree
/// position instead, which is what a declarative-ish authoring model needs and
/// what the reference does.
extension View {
    /// Whether this view takes keyboard focus by tab.
    ///
    /// Separate from `acceptsFirstResponder`: a view can be focusable by click
    /// while staying out of the tab order — a list row that takes focus when
    /// selected should not be a tab stop between the search field and the
    /// buttons.
    public var isTabStop: Bool {
        get { explicitTabStop ?? acceptsFirstResponder }
        set { explicitTabStop = newValue }
    }

    /// Views under this one that can take tab focus, in tree order.
    ///
    /// Tree order is depth-first: a view precedes its own children, matching
    /// reading order for a form laid out top-to-bottom.
    public func tabOrder() -> [View] {
        var result: [View] = []
        collectTabOrder(into: &result)
        return result
    }

    private func collectTabOrder(into result: inout [View]) {
        guard !isHidden, !excludesSubtreeFromTabOrder else { return }
        if isTabStop && canTakeFocus { result.append(self) }
        for child in childViews {
            child.collectTabOrder(into: &result)
        }
    }

    /// A disabled control is not a tab stop. Tabbing to something that cannot be
    /// acted on is a dead end the user has to tab out of again.
    private var canTakeFocus: Bool {
        if let control = self as? Control { return control.isEnabled }
        return true
    }

    /// The next view after `current` in tab order, wrapping at the end.
    ///
    /// Wrapping rather than stopping: a form whose last field refuses to advance
    /// feels broken, and there is nowhere else for focus to go in a shell
    /// surface that owns its keyboard.
    public func tabStop(after current: View?, reverse: Bool = false) -> View? {
        let order = tabOrder()
        guard !order.isEmpty else { return nil }
        guard let current, let index = order.firstIndex(where: { $0 === current })
        else {
            return reverse ? order.last : order.first
        }
        let step = reverse ? -1 : 1
        let next = (index + step + order.count) % order.count
        return order[next]
    }

    /// The first view in this subtree that can take tab focus.
    public func firstTabStop() -> View? { tabOrder().first }
    public func lastTabStop() -> View? { tabOrder().last }

    /// Find a view by focus key, for restoring focus after a rebuild.
    public func view(withFocusKey key: String) -> View? {
        if focusKey == key { return self }
        for child in childViews {
            if let found = child.view(withFocusKey: key) { return found }
        }
        return nil
    }
}

extension Window {
    /// Move focus to the next tab stop, wrapping. Returns whether focus moved.
    @discardableResult
    public func advanceFocus(reverse: Bool = false) -> Bool {
        guard let root = activeFocusScopeRoot ?? root else { return false }
        let current = firstResponder as? View
        guard let next = root.tabStop(after: current, reverse: reverse),
              next !== current
        else { return false }
        return makeFirstResponder(next)
    }

    /// Enter a modal focus scope, preserving the prior responder for restoration.
    public func beginFocusScope(_ scope: View) {
        guard let windowRoot = root,
              scope === windowRoot || scope.isDescendant(of: windowRoot)
        else {
            preconditionFailure("focus scope must belong to this window")
        }
        scope.focusScopeBehavior = .modal
        focusScopeRecords.append(FocusScopeRecord(
            root: scope,
            previousResponder: firstResponder,
            previousFocusKey: focusedKey))
        if let current = firstResponder as? View,
           current === scope || current.isDescendant(of: scope)
        {
            return
        }
        _ = makeFirstResponder(scope.firstTabStop())
    }

    /// Leave this scope and any nested scopes, restoring stable focus.
    public func endFocusScope(_ scope: View) {
        guard let index = focusScopeRecords.lastIndex(where: {
            $0.root === scope
        }) else { return }
        let record = focusScopeRecords[index]
        focusScopeRecords.removeSubrange(index...)
        scope.focusScopeBehavior = .none

        if let responder = record.previousResponder,
           responderBelongsToWindow(responder)
        {
            _ = makeFirstResponder(responder)
        } else if let key = record.previousFocusKey {
            _ = restoreFocus(toKey: key)
        } else {
            _ = makeFirstResponder(root?.firstTabStop())
        }
    }

    package var activeFocusScopeRoot: View? {
        while let last = focusScopeRecords.last, last.root == nil {
            focusScopeRecords.removeLast()
        }
        return focusScopeRecords.last?.root
    }

    package func responderBelongsToActiveFocusScope(
        _ responder: Responder
    ) -> Bool {
        guard let scope = activeFocusScopeRoot else { return true }
        guard let view = responder as? View else { return false }
        return view === scope || view.isDescendant(of: scope)
    }

    package func responderBelongsToWindow(_ responder: Responder) -> Bool {
        guard let view = responder as? View, let root else { return false }
        return view === root || view.isDescendant(of: root)
    }

    /// The focus key of whatever currently holds focus, to restore it later.
    public var focusedKey: String? {
        (firstResponder as? View)?.focusKey
    }

    /// Restore focus to the view now carrying `key`.
    ///
    /// The point of keys: the view that had focus before a rebuild no longer
    /// exists, and this finds whatever took over its role.
    @discardableResult
    public func restoreFocus(toKey key: String) -> Bool {
        guard let root, let target = root.view(withFocusKey: key) else { return false }
        return makeFirstResponder(target)
    }

    /// Handle Tab and Shift-Tab. Call from key handling before the responder
    /// chain, since a focused text field would otherwise insert a tab character.
    @discardableResult
    public func handleFocusTraversal(_ event: Event) -> EventHandling {
        guard event.type == .keyDown, event.keyCode == .tab else { return .notHandled }
        return advanceFocus(reverse: event.modifierFlags.contains(.shift))
            ? .handled : .notHandled
    }
}

/// Roving focus within a list: one tab stop for the whole list, arrow keys
/// moving inside it.
///
/// The accessibility pattern a listbox wants. A launcher with two hundred
/// results must not be two hundred tab stops, and arrow keys are how a list is
/// actually navigated.
@MainActor
public final class RovingFocus {
    public enum Axis: Sendable, Equatable {
        case vertical
        case horizontal
        case both
    }

    public var axis: Axis = .vertical
    /// Whether moving past an end wraps to the other. Off by default: in a list
    /// of search results, arrowing past the last one and landing on the first is
    /// disorienting.
    public var wraps = false

    public private(set) var index: Int = 0
    public private(set) var count: Int = 0

    /// Called when the index moves, so a list can scroll it into view and
    /// restyle.
    public var onChange: ((Int) -> Void)?

    public init() {}

    public func setCount(_ newCount: Int) {
        count = max(0, newCount)
        // Clamp rather than reset: a results list that shrinks should keep the
        // selection near where it was, not jump to the top.
        let clamped = min(index, max(0, count - 1))
        if clamped != index { setIndex(clamped) }
    }

    public func setIndex(_ newIndex: Int) {
        guard count > 0 else {
            index = 0
            return
        }
        let clamped = min(max(0, newIndex), count - 1)
        guard clamped != index else { return }
        index = clamped
        onChange?(index)
    }

    /// Apply a key event. Returns whether it was consumed.
    public func handle(_ event: Event) -> EventHandling {
        guard event.type == .keyDown, count > 0 else { return .notHandled }

        let back: Bool
        switch event.keyCode {
        case .upArrow where axis != .horizontal,
             .leftArrow where axis != .vertical:
            back = true
        case .downArrow where axis != .horizontal,
             .rightArrow where axis != .vertical:
            back = false
        case .home:
            setIndex(0)
            return .handled
        case .end:
            setIndex(count - 1)
            return .handled
        default:
            return .notHandled
        }

        let target = index + (back ? -1 : 1)
        if target < 0 || target >= count {
            guard wraps else { return .handled }
            setIndex(back ? count - 1 : 0)
            return .handled
        }
        setIndex(target)
        return .handled
    }
}
public enum FocusScopeBehavior: Sendable, Equatable {
    case none
    case group
    case modal
}

@MainActor
package final class FocusScopeRecord {
    package weak var root: View?
    package weak var previousResponder: Responder?
    package let previousFocusKey: String?

    package init(
        root: View,
        previousResponder: Responder?,
        previousFocusKey: String?
    ) {
        self.root = root
        self.previousResponder = previousResponder
        self.previousFocusKey = previousFocusKey
    }
}
