@_spi(NucleusCompositor) @testable import NucleusUI
import Testing

@MainActor
@Suite(.uiContext, .serialized)
struct MenuTests {
    private func makeScene() -> (WindowScene, Window, TextField) {
        let field = TextField(string: "")
        field.frame = Rect(x: 0, y: 0, width: 120, height: 28)
        let window = Window(
            title: "Base",
            frame: Rect(x: 0, y: 0, width: 500, height: 400))
        window.setContentView(field)
        window.orderFront()
        let scene = WindowScene(inMemoryWindows: [window])
        scene.displayBounds = Rect(x: 0, y: 0, width: 500, height: 400)
        scene.makeKey(window)
        #expect(window.makeFirstResponder(field))
        return (scene, window, field)
    }

    private func key(
        _ code: KeyCode,
        modifiers: EventModifierFlags = [],
        characters: String? = nil
    ) -> Event {
        Event(
            type: .keyDown,
            modifierFlags: modifiers,
            keyCode: code,
            characters: characters)
    }

    @Test
    func validationUpdatesRetainedRowsAndRunsAgainBeforeActivation() throws {
        let (scene, _, _) = makeScene()
        var validations = 0
        var activations = 0
        let item = MenuItem(
            id: "build",
            title: "Build",
            validation: { item in
                validations += 1
                item.title = "Build \(validations)"
            }
        ) {
            activations += 1
        }
        let menu = Menu(items: [item])
        let presentation = scene.present(
            menu,
            anchor: Rect(x: 20, y: 20, width: 1, height: 1))

        #expect(validations == 1)
        #expect(item.title == "Build 1")
        let retainedID = try #require(
            presentation.retainedViewIDForTesting(itemID: item.id))

        item.glyph = "hammer"
        item.title = "Compile"
        #expect(
            presentation.retainedViewIDForTesting(itemID: item.id)
                == retainedID)

        #expect(scene.dispatchEvent(key(.downArrow)) == .handled)
        #expect(scene.dispatchEvent(key(.return)) == .handled)
        #expect(validations == 2)
        #expect(activations == 1)
        #expect(presentation.result == .activated(item.id))
        #expect(scene.menuPresentation == nil)
        #expect(scene.popovers.isEmpty)
    }

    @Test
    func validationCanRejectAnActivationWithoutClosingTheMenu() {
        let (scene, _, _) = makeScene()
        var validationCount = 0
        var activations = 0
        let item = MenuItem(
            id: "delete",
            title: "Delete",
            validation: { item in
                validationCount += 1
                item.isEnabled = validationCount == 1
            }
        ) {
            activations += 1
        }
        let presentation = scene.present(
            Menu(items: [item]),
            anchor: Rect(x: 10, y: 10, width: 1, height: 1))

        _ = scene.dispatchEvent(key(.downArrow))
        _ = scene.dispatchEvent(key(.return))

        #expect(validationCount == 2)
        #expect(activations == 0)
        #expect(presentation.result == nil)
        #expect(scene.menuPresentation === presentation)
        presentation.dismiss()
    }

    @Test
    func keyboardTraversalOwnsTheCascadePlacementAndFocusRestoration() throws {
        let (scene, originalWindow, originalField) = makeScene()
        let child = MenuItem(id: "child", title: "Child") {}
        let parent = MenuItem(
            id: "parent",
            title: "Parent",
            submenu: Menu(items: [child])
        ) {}
        let presentation = scene.present(
            Menu(items: [parent]),
            anchor: Rect(x: 485, y: 385, width: 1, height: 1))

        _ = scene.dispatchEvent(key(.downArrow))
        _ = scene.dispatchEvent(key(.rightArrow))
        #expect(presentation.panelCountForTesting() == 2)
        #expect(scene.popovers.count == 2)
        #expect(presentation.selectedItemIDForTesting() == child.id)
        for frame in presentation.popoverFramesForTesting() {
            #expect(frame.origin.x >= scene.displayBounds.origin.x)
            #expect(frame.origin.y >= scene.displayBounds.origin.y)
            #expect(frame.origin.x + frame.size.width
                <= scene.displayBounds.origin.x + scene.displayBounds.size.width)
            #expect(frame.origin.y + frame.size.height
                <= scene.displayBounds.origin.y + scene.displayBounds.size.height)
        }

        _ = scene.dispatchEvent(key(.leftArrow))
        #expect(presentation.panelCountForTesting() == 1)
        _ = scene.dispatchEvent(key(.escape))
        #expect(scene.menuPresentation == nil)
        #expect(scene.keyWindow === originalWindow)
        #expect(originalWindow.firstResponder === originalField)
        #expect(originalField.isFocused)
    }

    @Test
    func checkedRadioAlternateMnemonicAndKeyEquivalentBehaveSemantically() throws {
        let (scene, _, _) = makeScene()
        var alternateActivations = 0
        let toggle = MenuItem(
            id: "toggle",
            title: "Show Sidebar",
            activationBehavior: .toggle
        ) {}
        let group = MenuItemID("sort")
        let ascending = MenuItem(
            id: "ascending",
            title: "Ascending",
            state: .on,
            activationBehavior: .radio(group: group)
        ) {}
        let descending = MenuItem(
            id: "descending",
            title: "Descending",
            activationBehavior: .radio(group: group)
        ) {}
        let ordinary = MenuItem(id: "ordinary", title: "Export") {}
        let alternate = MenuItem(
            id: "alternate",
            title: "Export and Reveal",
            isAlternate: true,
            alternateModifiers: .option,
            mnemonic: "r",
            action: { alternateActivations += 1 })
        let shortcut = MenuItem(
            id: "shortcut",
            title: "Refresh",
            keyEquivalent: MenuKeyEquivalent(
                keyCode: .letterR,
                modifiers: .command,
                displayText: "⌘R")
        ) {
            alternateActivations += 10
        }
        let menu = Menu(items: [
            toggle, ascending, descending, ordinary, alternate, shortcut,
        ])

        var presentation = scene.present(
            menu,
            anchor: Rect(x: 30, y: 30, width: 1, height: 1))
        _ = scene.dispatchEvent(key(.downArrow))
        _ = scene.dispatchEvent(key(.return))
        #expect(toggle.state == .on)

        presentation = scene.present(
            menu,
            anchor: Rect(x: 30, y: 30, width: 1, height: 1))
        _ = scene.dispatchEvent(key(.downArrow))
        _ = scene.dispatchEvent(key(.downArrow))
        _ = scene.dispatchEvent(key(.downArrow))
        _ = scene.dispatchEvent(key(.return))
        #expect(ascending.state == .off)
        #expect(descending.state == .on)

        presentation = scene.present(
            menu,
            anchor: Rect(x: 30, y: 30, width: 1, height: 1))
        let ordinaryViewID = try #require(
            presentation.retainedViewIDForTesting(itemID: ordinary.id))
        _ = scene.dispatchEvent(Event(
            type: .flagsChanged,
            modifierFlags: .option))
        #expect(
            presentation.retainedViewIDForTesting(itemID: alternate.id)
                != nil)
        _ = scene.dispatchEvent(Event(type: .flagsChanged))
        #expect(
            presentation.retainedViewIDForTesting(itemID: ordinary.id)
                == ordinaryViewID)

        _ = scene.dispatchEvent(key(
            .letterR,
            modifiers: .option,
            characters: "r"))
        #expect(alternateActivations == 1)

        _ = scene.present(
            menu,
            anchor: Rect(x: 30, y: 30, width: 1, height: 1))
        _ = scene.dispatchEvent(key(.letterR, modifiers: .command))
        #expect(alternateActivations == 11)
    }

    @Test
    func pointerOpeningSupportsStickyClickDragActivationAndOutsideDismissal() throws {
        let (scene, _, _) = makeScene()
        var activations = 0
        let item = MenuItem(id: "open", title: "Open") {
            activations += 1
        }
        var presentation = scene.present(
            Menu(items: [item]),
            anchor: Rect(x: 80, y: 80, width: 1, height: 1),
            stickyOpeningGesture: true)

        _ = scene.dispatchEvent(Event(
            type: .pointerUp,
            location: Point(x: 5, y: 5)))
        #expect(scene.menuPresentation === presentation)

        let row = try #require(
            presentation.itemFrameInSceneForTesting(itemID: item.id))
        let point = Point(
            x: row.origin.x + row.size.width * 0.5,
            y: row.origin.y + row.size.height * 0.5)
        _ = scene.dispatchEvent(Event(
            type: .pointerDown,
            location: point,
            button: .left))
        _ = scene.dispatchEvent(Event(
            type: .pointerUp,
            location: point,
            button: .left))
        #expect(activations == 1)
        #expect(scene.menuPresentation == nil)

        presentation = scene.present(
            Menu(items: [item]),
            anchor: Rect(x: 80, y: 80, width: 1, height: 1),
            stickyOpeningGesture: true)
        let dragRow = try #require(
            presentation.itemFrameInSceneForTesting(itemID: item.id))
        let dragPoint = Point(
            x: dragRow.origin.x + 10,
            y: dragRow.origin.y + 10)
        _ = scene.dispatchEvent(Event(
            type: .pointerDragged,
            location: dragPoint,
            activeButtons: .left))
        _ = scene.dispatchEvent(Event(
            type: .pointerUp,
            location: dragPoint,
            button: .left))
        #expect(activations == 2)

        presentation = scene.present(
            Menu(items: [item]),
            anchor: Rect(x: 80, y: 80, width: 1, height: 1))
        _ = scene.dispatchEvent(Event(
            type: .pointerDown,
            location: Point(x: 499, y: 399),
            button: .left))
        #expect(presentation.result == .cancelled)
        #expect(scene.menuPresentation == nil)
    }

    @Test
    func pointerHoverOpensSubmenuAfterDelay() async throws {
        let (scene, _, _) = makeScene()
        let child = MenuItem(id: "child", title: "Child") {}
        let parent = MenuItem(
            id: "parent",
            title: "Parent",
            submenu: Menu(items: [child])
        ) {}
        let presentation = scene.present(
            Menu(items: [parent]),
            anchor: Rect(x: 30, y: 30, width: 1, height: 1))
        let frame = try #require(
            presentation.itemFrameInSceneForTesting(itemID: parent.id))
        _ = scene.dispatchEvent(Event(
            type: .pointerMoved,
            location: Point(
                x: frame.origin.x + 10,
                y: frame.origin.y + 10)))

        #expect(presentation.panelCountForTesting() == 1)
        await Task.yield()
        #expect(testUIClock().waiterCount == 1)
        testUIClock().advance(by: .milliseconds(179))
        await Task.yield()
        #expect(presentation.panelCountForTesting() == 1)
        testUIClock().advance(by: .milliseconds(1))
        for _ in 0..<32 where presentation.panelCountForTesting() != 2 {
            await Task.yield()
        }
        #expect(presentation.panelCountForTesting() == 2)
        presentation.dismiss()
    }

    @Test
    func dismissalCancelsPendingSubmenuDeadlineExactlyOnce() async throws {
        let (scene, _, _) = makeScene()
        let parent = MenuItem(
            id: "parent",
            title: "Parent",
            submenu: Menu(items: [
                MenuItem(id: "child", title: "Child") {},
            ])) {}
        let presentation = scene.present(
            Menu(items: [parent]),
            anchor: Rect(x: 30, y: 30, width: 1, height: 1))
        let frame = try #require(
            presentation.itemFrameInSceneForTesting(itemID: parent.id))
        _ = scene.dispatchEvent(Event(
            type: .pointerMoved,
            location: Point(x: frame.origin.x + 10, y: frame.origin.y + 10)))
        await waitForClockWaiters(1)

        presentation.dismiss()
        await waitForClockWaiters(0)
        testUIClock().advance(by: .seconds(1))
        #expect(presentation.panelCountForTesting() == 0)
        #expect(scene.menuPresentation == nil)
        #expect(testUIClock().waiterCount == 0)
    }

    @Test
    func accessibilityExportsMenuTopologyStateActionAndFocus() throws {
        let (scene, _, _) = makeScene()
        var activations = 0
        let checked = MenuItem(
            id: "checked",
            title: "Show Status",
            state: .on,
            activationBehavior: .toggle
        ) {
            activations += 1
        }
        let presentation = scene.present(
            Menu(items: [
                checked,
                .separator(id: "separator"),
            ]),
            anchor: Rect(x: 40, y: 40, width: 1, height: 1))
        _ = scene.dispatchEvent(key(.downArrow))
        _ = scene.accessibilityTree.publish()

        let nodes = Array(scene.accessibilityTree.snapshot.nodes.values)
        #expect(nodes.contains { $0.role == .menu })
        let row = try #require(nodes.first {
            $0.role == .menuItem && $0.label == "Show Status"
        })
        #expect(row.state.contains(.checked))
        #expect(row.state.contains(.focused))
        #expect(row.actions.contains(.press))
        #expect(scene.accessibilityTree.perform(.init(
            target: row.id,
            action: .press)))
        #expect(activations == 1)
        #expect(presentation.result == .activated(checked.id))
    }

    @Test
    func repeatedPresentationAndSceneTeardownReturnOwnershipToBaseline() throws {
        let baseline = MenuPresentationController.liveCount
        let (scene, originalWindow, _) = makeScene()
        let item = MenuItem(id: "item", title: "Item") {}
        let menu = Menu(items: [item])

        for _ in 0..<100 {
            let presentation = scene.present(
                menu,
                anchor: Rect(x: 20, y: 20, width: 1, height: 1))
            presentation.dismiss()
        }

        #expect(scene.popovers.isEmpty)
        #expect(scene.windows.count == 1)
        #expect(scene.windows.first === originalWindow)
        #expect(scene.menuPresentation == nil)
        #expect(MenuPresentationController.liveCount == baseline)

        _ = scene.present(
            menu,
            anchor: Rect(x: 20, y: 20, width: 1, height: 1))
        try scene.disconnect()
        #expect(scene.menuPresentation == nil)
        #expect(scene.popovers.isEmpty)
        #expect(MenuPresentationController.liveCount == baseline)
    }

    private func waitForClockWaiters(_ count: Int) async {
        for _ in 0..<32 where testUIClock().waiterCount != count {
            await Task.yield()
        }
        #expect(testUIClock().waiterCount == count)
    }
}
