@_spi(NucleusCompositor) @testable import NucleusUI
import Testing

@MainActor
@Suite(.uiContext) struct AccessibilityTests {
    @Test func viewAccessibilityDefaultsAreEnumerable() throws {
        let view = View()

        #expect(!view.isAccessibilityElement)
        #expect(view.accessibilityLabel == nil)
        #expect(view.accessibilityHint == nil)
        #expect(view.accessibilityValue == nil)
        #expect(view.accessibilityRole == nil)
        #expect(view.accessibilityTraits == [])
        #expect(view.accessibilityChildren == nil)
        #expect(view.accessibilityProperties == AccessibilityProperties())
    }

    @Test func viewAccessibilityIndividualSettersUpdateProperties() throws {
        let view = View()

        view.isAccessibilityElement = true
        view.accessibilityLabel = "Continue"
        view.accessibilityHint = "Moves to the next page"
        view.accessibilityValue = "Ready"
        view.accessibilityRole = .button
        view.accessibilityTraits = [.button, .selected]

        #expect(view.accessibilityProperties == AccessibilityProperties(
            isElement: true,
            label: "Continue",
            hint: "Moves to the next page",
            value: "Ready",
            role: .button,
            traits: [.button, .selected]
        ))
    }

    @Test func viewAccessibilityBatchSetterUpdatesIndividualAccessors() throws {
        let view = View()

        view.accessibilityProperties = AccessibilityProperties(
            isElement: true,
            label: "Preview",
            hint: "Shows the selected image",
            value: "Image 3 of 5",
            role: .image,
            traits: [.image, .updatesFrequently]
        )

        #expect(view.isAccessibilityElement)
        #expect(view.accessibilityLabel == "Preview")
        #expect(view.accessibilityHint == "Shows the selected image")
        #expect(view.accessibilityValue == "Image 3 of 5")
        #expect(view.accessibilityRole == .image)
        #expect(view.accessibilityTraits == [.image, .updatesFrequently])
    }

    @Test func accessibilityChildrenAreExplicitAndNotInherited() throws {
        let parent = View()
        let child = View()

        parent.addSubview(child)
        parent.accessibilityChildren = [child]

        #expect(parent.accessibilityChildren?.count == 1)
        #expect(child.accessibilityChildren == nil)
        #expect(child.accessibilityProperties == AccessibilityProperties())
    }

    @Test func buttonUsesBaseAccessibilitySurface() throws {
        let button = Button(title: "Install")

        button.accessibilityProperties = AccessibilityProperties(
            isElement: true,
            label: "Install",
            role: .button,
            traits: [.button]
        )

        #expect(button.isAccessibilityElement)
        #expect(button.accessibilityLabel == "Install")
        #expect(button.accessibilityRole == .button)
        #expect(button.accessibilityTraits == [.button])
    }

    private func makeScene(
        root: View,
        frame: Rect = Rect(x: 100, y: 50, width: 300, height: 200)
    ) -> (WindowScene, Window) {
        let window = Window(title: "Accessible", frame: frame)
        window.setContentView(root)
        window.orderFront()
        return (WindowScene(inMemoryWindows: [window]), window)
    }

    @Test func treeFramesAndActionsUseStableSemanticIdentity() throws {
        let root = View()
        let button = Button(title: "Install")
        button.frame = Rect(x: 10, y: 20, width: 80, height: 30)
        root.addSubview(button)
        let (scene, _) = makeScene(root: root)
        var presses = 0
        button.onPress { _ in presses += 1 }

        let first = scene.accessibilityTree.publish()
        let node = try #require(
            scene.accessibilityTree.snapshot.nodes[button.accessibilityID])
        #expect(node.frameInScene
            == Rect(x: 110, y: 70, width: 80, height: 30))
        #expect(node.label == "Install")
        #expect(node.actions.contains(.press))
        #expect(scene.accessibilityTree.perform(.init(
            target: button.accessibilityID,
            action: .press)))
        #expect(presses == 1)

        let second = scene.accessibilityTree.publish()
        #expect(first.inserted.contains { $0.id == button.accessibilityID })
        #expect(second.inserted.isEmpty)
        #expect(second.removed.isEmpty)
        #expect(scene.accessibilityTree.lastMetrics.nodesVisited == 1)
        #expect(
            scene.accessibilityTree.lastMetrics.cachedSubtreesReused == 1)
    }

    @Test func valueChangesPublishAnIncrementalNodeAndNotification() {
        let slider = Slider()
        slider.frame = Rect(x: 0, y: 0, width: 120, height: 24)
        let (scene, _) = makeScene(root: slider)
        _ = scene.accessibilityTree.publish()

        slider.value = 0.5
        let update = scene.accessibilityTree.publish()
        #expect(update.inserted.isEmpty)
        #expect(update.removed.isEmpty)
        #expect(update.updated.map(\.id) == [slider.accessibilityID])
        #expect(update.notifications.contains {
            $0.kind == .value && $0.target == slider.accessibilityID
        })
    }

    @Test func virtualizedOffscreenItemsRemainDiscoverableAndStable()
        throws
    {
        let list = ListView()
        list.frame = Rect(x: 0, y: 0, width: 200, height: 84)
        list.makeRow = { View() }
        list.accessibilityItemProperties = { _, index in
            AccessibilityProperties(
                isElement: true,
                label: "Result \(index)",
                role: .listItem)
        }
        try list.applySnapshot(CollectionSnapshot(ids: Array(0..<100)))
        list.layoutIfNeeded()
        let (scene, _) = makeScene(root: list)
        _ = scene.accessibilityTree.publish()
        let itemNodes = scene.accessibilityTree.snapshot.nodes.values
            .filter { $0.role == .listItem }
        #expect(itemNodes.count == 100)
        #expect(list.materializedRowCount < 100)
        let itemFifty = try #require(
            itemNodes.first { $0.label == "Result 50" })

        let reordered = [50] + Array(0..<50) + Array(51..<100)
        try list.applySnapshot(CollectionSnapshot(ids: reordered))
        _ = scene.accessibilityTree.publish()
        let moved = try #require(
            scene.accessibilityTree.snapshot.nodes.values.first {
                $0.label == "Result 0"
            })
        #expect(moved.id == itemFifty.id)
    }

    @Test func secureTextIsRedactedFromEveryExportedTextSurface()
        throws
    {
        let field = TextField(string: "hunter2", isSecure: true)
        field.frame = Rect(x: 0, y: 0, width: 180, height: 24)
        let (scene, _) = makeScene(root: field)
        _ = scene.accessibilityTree.publish()
        let node = try #require(
            scene.accessibilityTree.snapshot.nodes[field.accessibilityID])

        #expect(node.value == nil)
        #expect(node.textSelection == nil)
        #expect(node.state.contains(.secure))
        #expect(!node.actions.contains(.setText))
        #expect(!node.actions.contains(.copy))
    }

    @Test func rangeSliderExportsTwoStableIndependentlyOperableThumbs()
        throws
    {
        let slider = RangeSlider()
        slider.frame = Rect(x: 0, y: 0, width: 120, height: 24)
        slider.lowerValue = 0.2
        slider.upperValue = 0.8
        let (scene, _) = makeScene(root: slider)
        _ = scene.accessibilityTree.publish()
        let children = try #require(
            scene.accessibilityTree.snapshot.nodes[
                slider.accessibilityID]?.childIDs)
        #expect(children.count == 2)
        let lowerID = children[0]
        let lower = try #require(
            scene.accessibilityTree.snapshot.nodes[lowerID])
        #expect(lower.label == "Lower value")
        #expect(lower.role == .slider)
        #expect(lower.state.contains(.focusable))
        #expect(lower.actions.contains(.setValue))

        #expect(scene.accessibilityTree.perform(.init(
            target: lowerID,
            action: .setValue,
            value: 0.5)))
        #expect(slider.lowerValue == 0.5)
        _ = scene.accessibilityTree.publish()
        #expect(
            scene.accessibilityTree.snapshot.nodes[lowerID]?
                .rangeValue?.current == 0.5)
    }
}
