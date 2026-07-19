import Testing
import NucleusUI

/// Keyboard focus traversal. Order is derived from tree position rather than
/// authored as a linked list, because a tree rebuilt from a body closure would
/// otherwise have to re-thread the loop on every rebuild.
@MainActor
@Suite struct FocusTraversalTests {
    private final class Focusable: View {
        override var acceptsFirstResponder: Bool { true }
    }

    private func makeWindow(root: View) -> (WindowScene, Window) {
        root.frame = Rect(x: 0, y: 0, width: 200, height: 200)
        let window = Window(title: "Focus")
        window.setContentView(root)
        window.orderFront()
        let scene = WindowScene(windows: [window])
        scene.makeKey(window)
        return (scene, window)
    }

    // MARK: - Order

    /// Depth-first, so a view precedes its own children — reading order for a
    /// form laid out top to bottom.
    @Test func orderFollowsTreePosition() {
        let root = View()
        let first = Focusable()
        let second = Focusable()
        let nested = Focusable()
        second.addSubview(nested)
        root.addSubview(first)
        root.addSubview(second)

        let order = root.tabOrder()
        #expect(order.count == 3)
        #expect(order[0] === first)
        #expect(order[1] === second)
        #expect(order[2] === nested)
    }

    /// A plain view is not a tab stop; a focusable one is, without being told.
    @Test func focusableViewsAreTabStopsByDefault() {
        #expect(!View().isTabStop)
        #expect(Focusable().isTabStop)
        #expect(Control().isTabStop)
    }

    /// Opting out is separate from refusing focus: a list row can take focus on
    /// click without becoming a tab stop between the field and the buttons.
    @Test func aViewCanBeFocusableWithoutBeingATabStop() {
        let root = View()
        let row = Focusable()
        row.isTabStop = false
        root.addSubview(row)

        #expect(root.tabOrder().isEmpty)
        #expect(row.acceptsFirstResponder, "still focusable by click")
    }

    /// A disabled control is skipped — tabbing to something that cannot be acted
    /// on is a dead end.
    @Test func disabledControlsAreSkipped() {
        let root = View()
        let enabled = Control()
        let disabled = Control()
        disabled.isEnabled = false
        root.addSubview(enabled)
        root.addSubview(disabled)

        let order = root.tabOrder()
        #expect(order.count == 1)
        #expect(order.first === enabled)
    }

    @Test func hiddenSubtreesAreSkipped() {
        let root = View()
        let group = View()
        group.addSubview(Focusable())
        group.isHidden = true
        root.addSubview(group)
        #expect(root.tabOrder().isEmpty)
    }

    /// One flag on a container, so a collapsed section leaves the order as a
    /// unit and rejoins as a unit.
    @Test func anExcludedSubtreeLeavesAsAUnit() {
        let root = View()
        let kept = Focusable()
        let group = View()
        group.addSubview(Focusable())
        group.addSubview(Focusable())
        root.addSubview(kept)
        root.addSubview(group)
        #expect(root.tabOrder().count == 3)

        group.excludesSubtreeFromTabOrder = true
        #expect(root.tabOrder().count == 1)

        group.excludesSubtreeFromTabOrder = false
        #expect(root.tabOrder().count == 3, "and rejoins whole")
    }

    // MARK: - Advancing

    @Test func tabAdvancesAndWraps() {
        let root = View()
        let a = Focusable()
        let b = Focusable()
        root.addSubview(a)
        root.addSubview(b)
        let (_, window) = makeWindow(root: root)

        #expect(window.makeFirstResponder(a))
        #expect(window.advanceFocus())
        #expect(window.firstResponder === b)

        // Wrapping: a form whose last field refuses to advance feels broken.
        #expect(window.advanceFocus())
        #expect(window.firstResponder === a)
    }

    @Test func shiftTabGoesBackwards() {
        let root = View()
        let a = Focusable()
        let b = Focusable()
        root.addSubview(a)
        root.addSubview(b)
        let (_, window) = makeWindow(root: root)

        #expect(window.makeFirstResponder(a))
        #expect(window.advanceFocus(reverse: true))
        #expect(window.firstResponder === b, "wrapped to the last")
    }

    @Test func advancingWithNothingFocusedTakesTheFirst() {
        let root = View()
        let a = Focusable()
        root.addSubview(a)
        let (_, window) = makeWindow(root: root)
        _ = window.makeFirstResponder(nil)

        #expect(window.advanceFocus())
        #expect(window.firstResponder === a)
    }

    @Test func advancingWithNoTabStopsDoesNothing() {
        let root = View()
        root.addSubview(View())
        let (_, window) = makeWindow(root: root)
        #expect(!window.advanceFocus())
    }

    /// Tab must move focus before anything sees it: a focused text field would
    /// otherwise insert a tab character and focus would never leave it.
    @Test func tabIsInterceptedBeforeTheResponderChain() {
        let root = View()
        let field = TextField(string: "")
        field.frame = Rect(x: 0, y: 0, width: 100, height: 20)
        let other = Focusable()
        root.addSubview(field)
        root.addSubview(other)
        let (scene, window) = makeWindow(root: root)

        #expect(window.makeFirstResponder(field))
        let handled = scene.dispatchEvent(
            Event(type: .keyDown, location: .zero, keyCode: .tab))

        #expect(handled == .handled)
        #expect(window.firstResponder === other)
        #expect(field.stringValue == "", "no tab character was typed")
    }

    // MARK: - Focus keys

    /// The point of keys: the view that had focus no longer exists after a
    /// rebuild, and focus is restored to whatever took over its role.
    @Test func focusSurvivesASubtreeRebuild() {
        let root = View()
        let original = Focusable()
        original.focusKey = "search"
        root.addSubview(original)
        let (_, window) = makeWindow(root: root)

        #expect(window.makeFirstResponder(original))
        #expect(window.focusedKey == "search")

        // Rebuild: the old view is gone, a new one occupies its role.
        original.removeFromSuperview()
        let replacement = Focusable()
        replacement.focusKey = "search"
        root.addSubview(replacement)

        #expect(window.restoreFocus(toKey: "search"))
        #expect(window.firstResponder === replacement)
    }

    @Test func restoringAnAbsentKeyFails() {
        let root = View()
        let (_, window) = makeWindow(root: root)
        #expect(!window.restoreFocus(toKey: "nothing"))
    }

    @Test func lookupFindsNestedKeys() {
        let root = View()
        let deep = Focusable()
        deep.focusKey = "deep"
        let middle = View()
        middle.addSubview(deep)
        root.addSubview(middle)
        #expect(root.view(withFocusKey: "deep") === deep)
        #expect(root.view(withFocusKey: "missing") == nil)
    }
}

/// Roving focus: one tab stop for a whole list, arrow keys moving inside it.
@MainActor
@Suite struct RovingFocusTests {
    private func makeRoving(count: Int) -> RovingFocus {
        let roving = RovingFocus()
        roving.setCount(count)
        return roving
    }

    private func key(_ code: KeyCode) -> Event {
        Event(type: .keyDown, location: .zero, keyCode: code)
    }

    @Test func arrowsMoveTheIndex() {
        let roving = makeRoving(count: 5)
        #expect(roving.handle(key(.downArrow)) == .handled)
        #expect(roving.index == 1)
        #expect(roving.handle(key(.upArrow)) == .handled)
        #expect(roving.index == 0)
    }

    @Test func homeAndEndJumpToTheEnds() {
        let roving = makeRoving(count: 10)
        #expect(roving.handle(key(.end)) == .handled)
        #expect(roving.index == 9)
        #expect(roving.handle(key(.home)) == .handled)
        #expect(roving.index == 0)
    }

    /// Off by default: arrowing past the last result and landing on the first is
    /// disorienting in a search list.
    @Test func itDoesNotWrapUnlessAsked() {
        let roving = makeRoving(count: 3)
        roving.setIndex(2)
        #expect(roving.handle(key(.downArrow)) == .handled)
        #expect(roving.index == 2, "stayed at the end")

        roving.wraps = true
        #expect(roving.handle(key(.downArrow)) == .handled)
        #expect(roving.index == 0)
    }

    /// The axis decides which arrows apply, so a horizontal strip does not
    /// swallow up and down.
    @Test func theAxisGatesWhichArrowsApply() {
        let vertical = makeRoving(count: 5)
        #expect(vertical.handle(key(.rightArrow)) == .notHandled)

        let horizontal = makeRoving(count: 5)
        horizontal.axis = .horizontal
        #expect(horizontal.handle(key(.downArrow)) == .notHandled)
        #expect(horizontal.handle(key(.rightArrow)) == .handled)

        let both = makeRoving(count: 5)
        both.axis = .both
        #expect(both.handle(key(.downArrow)) == .handled)
        #expect(both.handle(key(.rightArrow)) == .handled)
    }

    /// A results list that shrinks keeps the selection near where it was rather
    /// than jumping to the top.
    @Test func shrinkingClampsRatherThanResets() {
        let roving = makeRoving(count: 100)
        roving.setIndex(50)
        roving.setCount(10)
        #expect(roving.index == 9)
    }

    @Test func anEmptyListConsumesNothing() {
        let roving = makeRoving(count: 0)
        #expect(roving.handle(key(.downArrow)) == .notHandled)
        #expect(roving.index == 0)
    }

    @Test func changesAreReportedOnce() {
        let roving = makeRoving(count: 5)
        var changes: [Int] = []
        roving.onChange = { changes.append($0) }

        roving.setIndex(2)
        roving.setIndex(2)
        #expect(changes == [2], "an identical index is not a change")
    }
}
