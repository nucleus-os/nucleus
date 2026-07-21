import Testing
import NucleusUI

/// Popup placement. Pure geometry, and the part most likely to be wrong at a
/// screen edge — which is exactly where it is hardest to reproduce by hand.
@Suite(.uiContext) struct PopupPlacementTests {
    private let screen = Rect(x: 0, y: 0, width: 1000, height: 800)

    @Test func thePreferredEdgeIsUsedWhenItFits() {
        let placement = resolvePopupPlacement(
            anchor: Rect(x: 400, y: 300, width: 40, height: 20),
            size: Size(width: 200, height: 100),
            preferring: .below, within: screen)

        #expect(placement.edge == .below)
        #expect(placement.frame.origin.y == 326, "below the anchor, plus the gap")
        // Centred on the anchor: 400 + (40 - 200)/2.
        #expect(placement.frame.origin.x == 320)
    }

    /// A widget at the bottom of the screen opens upward instead.
    @Test func itFlipsWhenThePreferredEdgeDoesNotFit() {
        let placement = resolvePopupPlacement(
            anchor: Rect(x: 400, y: 760, width: 40, height: 20),
            size: Size(width: 200, height: 100),
            preferring: .below, within: screen)

        #expect(placement.edge == .above)
        #expect(placement.frame.origin.y == 654, "760 - 100 - 6")
    }

    /// Flipping into a worse position helps nobody: when neither side fits, the
    /// preferred edge is kept unless the opposite genuinely has more room.
    @Test func itDoesNotFlipIntoLessRoom() {
        // Anchor near the top: below has 700-ish, above has 10. A popup too tall
        // for either must still choose below.
        let placement = resolvePopupPlacement(
            anchor: Rect(x: 400, y: 10, width: 40, height: 20),
            size: Size(width: 200, height: 900),
            preferring: .below, within: screen)

        #expect(placement.edge == .below)
    }

    /// A popup anchored at the screen's edge slides along to stay inside,
    /// because running off the side is worse than being off-centre.
    @Test func itSlidesAlongToStayInside() {
        let atRight = resolvePopupPlacement(
            anchor: Rect(x: 980, y: 300, width: 20, height: 20),
            size: Size(width: 200, height: 100),
            preferring: .below, within: screen)
        #expect(atRight.frame.origin.x == 796, "1000 - 200 - 4 margin")
        #expect(atRight.frame.origin.x + atRight.frame.size.width <= 1000)

        let atLeft = resolvePopupPlacement(
            anchor: Rect(x: 0, y: 300, width: 20, height: 20),
            size: Size(width: 200, height: 100),
            preferring: .below, within: screen)
        #expect(atLeft.frame.origin.x == 4, "the margin")
    }

    @Test func horizontalEdgesPlaceAndSlideOnTheOtherAxis() {
        let placement = resolvePopupPlacement(
            anchor: Rect(x: 100, y: 400, width: 20, height: 20),
            size: Size(width: 150, height: 80),
            preferring: .trailing, within: screen)

        #expect(placement.edge == .trailing)
        #expect(placement.frame.origin.x == 126, "100 + 20 + 6")
        #expect(placement.frame.origin.y == 370, "centred: 400 + (20 - 80)/2")
    }

    @Test func aLeadingPopupFlipsToTrailingAtTheLeftEdge() {
        let placement = resolvePopupPlacement(
            anchor: Rect(x: 5, y: 400, width: 20, height: 20),
            size: Size(width: 150, height: 80),
            preferring: .leading, within: screen)
        #expect(placement.edge == .trailing)
    }

    /// A popup wider than the space available overflows off the far edge rather
    /// than the near one, so its leading content stays reachable.
    @Test func anOversizePopupKeepsItsNearEdgeVisible() {
        let placement = resolvePopupPlacement(
            anchor: Rect(x: 500, y: 300, width: 20, height: 20),
            size: Size(width: 2000, height: 100),
            preferring: .below, within: screen)
        #expect(placement.frame.origin.x == 4, "pinned to the near margin")
    }
}

/// Popovers: presentation, the dismissal cascade, and the policies.
@MainActor
@Suite(.uiContext) struct PopoverTests {
    private func makeScene() -> WindowScene {
        let root = View()
        root.frame = Rect(x: 0, y: 0, width: 400, height: 300)
        let window = Window(title: "Base")
        window.setContentView(root)
        window.orderFront()
        let scene = WindowScene(inMemoryWindows: [window])
        scene.makeKey(window)
        scene.displayBounds = Rect(x: 0, y: 0, width: 400, height: 300)
        scene.drawsToolTips = false
        return scene
    }

    private func makePopover(
        anchor: Rect = Rect(x: 100, y: 100, width: 20, height: 20),
        dismissal: PopoverDismissal = .standard
    ) -> Popover {
        let content = View()
        content.frame = Rect(x: 0, y: 0, width: 80, height: 40)
        return Popover(content: content, anchor: anchor, dismissal: dismissal)
    }

    @Test func presentingPlacesAndOrdersTheWindow() {
        let scene = makeScene()
        let popover = makePopover()
        scene.present(popover)

        #expect(scene.popovers.count == 1)
        #expect(popover.window.isVisible)
        #expect(popover.placement.frame.origin.y == 126, "below the anchor")
    }

    @Test func dismissingRemovesTheWindowAndReports() {
        let scene = makeScene()
        let popover = makePopover()
        var dismissed = false
        popover.onDismiss = { dismissed = true }
        scene.present(popover)

        scene.dismiss(popover)
        #expect(scene.popovers.isEmpty)
        #expect(!popover.window.isVisible)
        #expect(dismissed)
    }

    /// Dismissing a popover takes everything opened on top of it: a submenu
    /// whose parent has gone is orphaned chrome nothing can close.
    @Test func dismissingCascadesToPopoversAboveIt() {
        let scene = makeScene()
        let menu = makePopover()
        let submenu = makePopover(anchor: Rect(x: 150, y: 150, width: 20, height: 20))
        scene.present(menu)
        scene.present(submenu)
        #expect(scene.popovers.count == 2)

        scene.dismiss(menu)
        #expect(scene.popovers.isEmpty, "the submenu went with its parent")
        #expect(!submenu.window.isVisible)
    }

    /// Dismissing the top one leaves its parent alone.
    @Test func dismissingTheTopLeavesTheRest() {
        let scene = makeScene()
        let menu = makePopover()
        let submenu = makePopover()
        scene.present(menu)
        scene.present(submenu)

        scene.dismiss(submenu)
        #expect(scene.popovers.count == 1)
        #expect(menu.window.isVisible)
    }

    // MARK: - Dismissal policies

    /// A click that closes a menu must not also press what was underneath it.
    @Test func anOutsideClickDismissesAndIsConsumed() {
        let scene = makeScene()
        let popover = makePopover()
        scene.present(popover)

        let handled = scene.dispatchEvent(
            Event(type: .pointerDown, location: Point(x: 5, y: 5)))
        #expect(handled == .handled, "consumed by the dismissal")
        #expect(scene.popovers.isEmpty)
    }

    @Test func aClickInsideDoesNotDismiss() {
        let scene = makeScene()
        let popover = makePopover()
        scene.present(popover)

        let inside = popover.placement.frame
        scene.dispatchEvent(Event(
            type: .pointerDown,
            location: Point(
                x: inside.origin.x + 5, y: inside.origin.y + 5)))
        #expect(scene.popovers.count == 1)
    }

    @Test func escapeDismissesWhenThePolicyAllows() {
        let scene = makeScene()
        scene.present(makePopover())

        let handled = scene.dispatchEvent(
            Event(type: .keyDown, location: .zero, keyCode: .escape))
        #expect(handled == .handled)
        #expect(scene.popovers.isEmpty)
    }

    @Test func escapeIsIgnoredWhenThePolicyOmitsIt() {
        let scene = makeScene()
        scene.present(makePopover(dismissal: .outsideClick))

        scene.dispatchEvent(
            Event(type: .keyDown, location: .zero, keyCode: .escape))
        #expect(scene.popovers.count == 1)
    }

    /// A tooltip describes what is under the pointer, so the click that cancels
    /// it must still reach the thing being described.
    @Test func aPassiveDismissalDoesNotConsumeTheClick() {
        let scene = makeScene()
        let tip = makePopover(dismissal: .anyClickPassively)
        scene.present(tip)

        let handled = scene.dispatchEvent(
            Event(type: .pointerDown, location: Point(x: 5, y: 5)))
        #expect(scene.popovers.isEmpty, "it went away")
        #expect(handled != .handled, "but the click carried on")
    }

    /// Movement is deliberately not a dismissal: hover tracking retires a
    /// tooltip when the pointer leaves its area, and dismissing on any motion
    /// would kill it on the first jitter.
    @Test func movementDoesNotDismiss() {
        let scene = makeScene()
        scene.present(makePopover(dismissal: .anyClickPassively))

        scene.dispatchEvent(
            Event(type: .pointerMoved, location: Point(x: 5, y: 5)))
        #expect(scene.popovers.count == 1)
    }

    @Test func repeatedPopoverLifecycleKeepsVisualResourcesBounded() throws {
        let scene = makeScene()
        _ = try scene.publish()
        var maximumLayers = scene.publishedVisualLayerCount
        var maximumPaintRegistrations =
            scene.retainedPaintRegistrationCount

        for iteration in 0..<200 {
            let label = Label("Tooltip \(iteration)")
            label.frame = Rect(x: 0, y: 0, width: 100, height: 24)
            let popover = Popover.withChrome(
                content: label,
                anchor: Rect(
                    x: Double(iteration % 200),
                    y: 50,
                    width: 10,
                    height: 10),
                dismissal: .anyClickPassively)
            scene.present(popover)
            _ = try scene.publish()
            maximumLayers = max(
                maximumLayers,
                scene.publishedVisualLayerCount)
            maximumPaintRegistrations = max(
                maximumPaintRegistrations,
                scene.retainedPaintRegistrationCount)

            scene.dismiss(popover)
            _ = try scene.publish()
        }

        #expect(scene.popovers.isEmpty)
        #expect(maximumLayers <= 4)
        #expect(maximumPaintRegistrations <= 3)
        #expect(scene.publishedVisualLayerCount == 1)
        #expect(scene.retainedPaintRegistrationCount <= 1)
        try scene.disconnect()
    }

    @Test func disconnectDismissesAndReleasesOpenPopovers() throws {
        let scene = makeScene()
        var popover: Popover? = makePopover()
        var dismissCount = 0
        popover!.onDismiss = { dismissCount += 1 }
        scene.present(popover!)
        _ = try scene.publish()
        weak let weakPopover = popover

        try scene.disconnect()
        popover = nil

        #expect(scene.popovers.isEmpty)
        #expect(scene.windows.isEmpty)
        #expect(dismissCount == 1)
        #expect(weakPopover == nil)
    }

    // MARK: - Reflow

    @Test func changingTheAnchorRepositions() {
        let scene = makeScene()
        let popover = makePopover()
        scene.present(popover)
        let before = popover.placement.frame.origin

        popover.anchor = Rect(x: 200, y: 50, width: 20, height: 20)
        #expect(popover.placement.frame.origin != before)
        #expect(popover.window.frame.origin == popover.placement.frame.origin)
    }

    /// A display that resizes reflows what is already open, rather than leaving
    /// a popover hanging off the new edge.
    @Test func resizingTheDisplayReflowsOpenPopovers() {
        let scene = makeScene()
        let popover = makePopover(anchor: Rect(x: 380, y: 100, width: 20, height: 20))
        scene.present(popover)

        scene.displayBounds = Rect(x: 0, y: 0, width: 200, height: 300)
        let frame = popover.placement.frame
        #expect(frame.origin.x + frame.size.width <= 200)
    }

    // MARK: - Tooltips through the popup layer

    /// The tooltip seam from the tracking work now has a renderer.
    @Test func aToolTipAppearsAsAPopover() {
        let root = View()
        root.frame = Rect(x: 0, y: 0, width: 400, height: 300)
        let target = View()
        target.frame = Rect(x: 50, y: 50, width: 40, height: 20)
        target.addTracking(toolTip: "Battery 73%")
        root.addSubview(target)

        let window = Window(title: "Base")
        window.setContentView(root)
        window.orderFront()
        let scene = WindowScene(inMemoryWindows: [window])
        scene.makeKey(window)
        scene.displayBounds = Rect(x: 0, y: 0, width: 400, height: 300)

        scene.dispatchEvent(Event(
            type: .pointerMoved, location: Point(x: 60, y: 55),
            timestampNanoseconds: 0))
        #expect(scene.popovers.isEmpty, "not yet")

        scene.updateToolTip(atNanoseconds: scene.toolTipDelayNanoseconds)
        #expect(scene.popovers.count == 1, "the tooltip is drawn as a popover")
        #expect(!scene.popovers[0].window.participatesInHitTesting,
                "it must never sit between the pointer and what it describes")
    }

    /// Leaving the area retires the tooltip's popover with it.
    @Test func leavingTheAreaRemovesTheToolTipPopover() {
        let root = View()
        root.frame = Rect(x: 0, y: 0, width: 400, height: 300)
        let target = View()
        target.frame = Rect(x: 50, y: 50, width: 40, height: 20)
        target.addTracking(toolTip: "Battery 73%")
        root.addSubview(target)

        let window = Window(title: "Base")
        window.setContentView(root)
        window.orderFront()
        let scene = WindowScene(inMemoryWindows: [window])
        scene.makeKey(window)
        scene.displayBounds = Rect(x: 0, y: 0, width: 400, height: 300)

        scene.dispatchEvent(Event(
            type: .pointerMoved, location: Point(x: 60, y: 55),
            timestampNanoseconds: 0))
        scene.updateToolTip(atNanoseconds: scene.toolTipDelayNanoseconds)
        #expect(scene.popovers.count == 1)

        scene.dispatchEvent(Event(
            type: .pointerMoved, location: Point(x: 300, y: 200),
            timestampNanoseconds: 10_000_000_000))
        #expect(scene.popovers.isEmpty)
    }
}
