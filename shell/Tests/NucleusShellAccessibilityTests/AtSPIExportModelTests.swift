import Testing
@testable import NucleusShellAccessibility
@testable import NucleusUI

@MainActor
@Suite(.uiContext) struct AtSPIExportModelTests {
    private func makeScene(root: View) -> WindowScene {
        root.frame = Rect(x: 0, y: 0, width: 200, height: 100)
        let window = Window(
            title: "Preferences",
            frame: Rect(x: 40, y: 30, width: 200, height: 100))
        window.setContentView(root)
        window.orderFront()
        return WindowScene(inMemoryWindows: [window])
    }

    @Test func stablePathsRolesStatesAndActionsSurviveUpdates() throws {
        let root = View()
        let button = Button(title: "Apply")
        button.frame = Rect(x: 10, y: 12, width: 80, height: 30)
        root.addSubview(button)
        let scene = makeScene(root: root)
        let adapter = RecordingAtSPIAdapter(applicationName: "Settings")
        let bridge = AtSPIBridge(scene: scene, adapter: adapter)
        var presses = 0
        button.onPress { _ in presses += 1 }

        _ = bridge.publish()
        let object = try #require(adapter.model.object(
            for: button.accessibilityID))
        #expect(object.path == AtSPIExportModel.path(
            for: button.accessibilityID))
        #expect(object.role == 43)
        #expect(object.name == "Apply")
        #expect(object.frame == Rect(
            x: 50, y: 42, width: 80, height: 30))
        #expect(object.interfaces.contains(AtSPIInterface.action))
        #expect(object.actions.first == .press)
        #expect(bridge.perform(.init(
            target: button.accessibilityID,
            action: .press)))
        #expect(presses == 1)

        button.frame.origin.x = 20
        _ = bridge.publish()
        let moved = try #require(adapter.model.object(
            for: button.accessibilityID))
        #expect(moved.path == object.path)
        #expect(adapter.updates.last?.events.contains {
            $0.kind == .boundsChanged && $0.sourcePath == object.path
        } == true)
    }

    @Test func secureTextNeverAdvertisesTextOrEditableText() throws {
        let field = TextField(string: "secret", isSecure: true)
        let scene = makeScene(root: field)
        let adapter = RecordingAtSPIAdapter()
        let bridge = AtSPIBridge(scene: scene, adapter: adapter)

        _ = bridge.publish()
        let object = try #require(adapter.model.object(
            for: field.accessibilityID))
        #expect(object.role == 40)
        #expect(object.text.isEmpty)
        #expect(object.valueText.isEmpty)
        #expect(!object.interfaces.contains(AtSPIInterface.text))
        #expect(!object.interfaces.contains(AtSPIInterface.editableText))
        #expect(!object.actions.contains(.setText))
    }

    @Test func removalEmitsConcreteChildAndWindowEvents() throws {
        let button = Button(title: "Remove")
        let scene = makeScene(root: button)
        let adapter = RecordingAtSPIAdapter()
        let bridge = AtSPIBridge(scene: scene, adapter: adapter)
        _ = bridge.publish()
        let path = AtSPIExportModel.path(for: button.accessibilityID)

        button.isHidden = true
        _ = bridge.publish()

        #expect(adapter.model.objects[path] == nil)
        #expect(adapter.updates.last?.removedPaths.contains(path) == true)
        #expect(adapter.updates.last?.events.contains {
            $0.kind == .childrenRemoved && $0.relatedPath == path
        } == true)
    }

    @Test func neutralNotificationsMapToATSPIFocusValueSelectionAndAnnouncement()
        throws
    {
        let root = View()
        let button = Button(title: "Focus")
        let slider = Slider()
        let tabs = SegmentedControl(segments: [
            SegmentOption(id: "one", title: "One"),
            SegmentOption(id: "two", title: "Two"),
        ])
        root.addSubview(button)
        root.addSubview(slider)
        root.addSubview(tabs)
        let scene = makeScene(root: root)
        let adapter = RecordingAtSPIAdapter()
        let bridge = AtSPIBridge(scene: scene, adapter: adapter)
        _ = bridge.publish()

        #expect(button.window?.makeFirstResponder(button) == true)
        slider.value = 0.5
        tabs.setSelectedIDs([CollectionItemID("two")])
        button.postAccessibilityAnnouncement("Saved", priority: .assertive)
        let update = bridge.publish()

        #expect(update.notifications.contains { $0.kind == .focus })
        let events = try #require(adapter.updates.last?.events)
        #expect(events.contains { $0.kind == .focus })
        #expect(events.contains { $0.kind == .valueChanged })
        #expect(events.contains { $0.kind == .selectionChanged })
        #expect(events.contains {
            $0.kind == .announcement && $0.text == "Saved"
        })
    }
}
