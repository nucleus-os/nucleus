import Testing
@testable import NucleusUI

@MainActor
@Suite(.uiContext) struct ControlPrimitiveTests {
    init() {
        installTestTextBackend()
    }

    @Test func toggleAndCheckboxSharePrimaryActionState() {
        for toggle in [Toggle(), Checkbox()] {
            toggle.frame = Rect(x: 0, y: 0, width: 40, height: 22)
            var changes: [Bool] = []
            toggle.onChange { changes.append($0) }
            _ = toggle.handleEvent(Event(type: .action))
            #expect(toggle.isOn)
            #expect(toggle.isSelected)
            #expect(changes == [true])
        }
    }

    @Test func radioGroupMaintainsOneStableSelection() {
        let group = RadioGroup(options: [
            RadioOption(id: "a", title: "A"),
            RadioOption(id: "b", title: "B"),
        ])
        group.frame = Rect(x: 0, y: 0, width: 100, height: 56)
        _ = group.handleEvent(Event(
            type: .pointerDown,
            location: Point(x: 10, y: 40)))
        _ = group.handleEvent(Event(
            type: .pointerUp,
            location: Point(x: 10, y: 40)))
        #expect(group.selectedID == CollectionItemID("b"))
    }

    @Test func sliderClampsStepsAndTracksPointer() {
        let slider = Slider()
        slider.frame = Rect(x: 0, y: 0, width: 100, height: 24)
        slider.minimumValue = 0
        slider.maximumValue = 10
        slider.step = 2
        _ = slider.handleEvent(Event(
            type: .pointerDown,
            location: Point(x: 51, y: 12)))
        #expect(slider.value == 6)
        slider.value = .infinity
        #expect(slider.value == 0)
    }

    @Test func rangeSliderNeverCrossesItsThumbs() {
        let slider = RangeSlider()
        slider.frame = Rect(x: 0, y: 0, width: 100, height: 24)
        slider.lowerValue = 0.25
        slider.upperValue = 0.75
        _ = slider.handleEvent(Event(
            type: .pointerDown,
            location: Point(x: 20, y: 12)))
        _ = slider.handleEvent(Event(
            type: .pointerDragged,
            location: Point(x: 90, y: 12)))
        #expect(slider.lowerValue == slider.upperValue)
        #expect(slider.lowerValue == 0.75)
    }

    @Test func rangeSliderCanonicalizesStepsAndDoesNotTrackWithoutAPress() {
        let slider = RangeSlider()
        slider.frame = Rect(x: 0, y: 0, width: 100, height: 24)
        slider.minimumValue = 0
        slider.maximumValue = 10
        slider.step = 2
        slider.lowerValue = 3
        slider.upperValue = 9
        #expect(slider.lowerValue == 4)
        #expect(slider.upperValue == 10)

        #expect(slider.handleEvent(Event(
            type: .pointerDragged,
            location: Point(x: 90, y: 12))) == .notHandled)
        #expect(slider.lowerValue == 4)
        #expect(slider.upperValue == 10)
    }

    @Test func segmentedControlSupportsSingleAndMultipleSelection() {
        let control = SegmentedControl(segments: [
            SegmentOption(id: 1, title: "One"),
            SegmentOption(id: 2, title: "Two"),
        ])
        control.frame = Rect(x: 0, y: 0, width: 100, height: 30)
        _ = control.handleEvent(Event(
            type: .pointerDown,
            location: Point(x: 75, y: 10)))
        _ = control.handleEvent(Event(
            type: .pointerUp,
            location: Point(x: 75, y: 10)))
        #expect(control.selectedIDs == [CollectionItemID(2)])

        control.selectionMode = .multiple
        _ = control.handleEvent(Event(
            type: .pointerDown,
            location: Point(x: 25, y: 10)))
        _ = control.handleEvent(Event(
            type: .pointerUp,
            location: Point(x: 25, y: 10)))
        #expect(control.selectedIDs == [
            CollectionItemID(1),
            CollectionItemID(2),
        ])
    }

    @Test func selectWithoutSceneUsesDeterministicFallback() {
        let select = SelectControl(options: [
            SelectOption(id: "a", title: "A"),
            SelectOption(id: "b", title: "B"),
        ])
        _ = select.handleEvent(Event(type: .action))
        #expect(select.selectedID == CollectionItemID("a"))
        #expect(select.title == "A")
    }

    @Test func contextMenuPresentsFromSecondaryClick() {
        let root = View()
        root.frame = Rect(x: 0, y: 0, width: 100, height: 100)
        root.contextMenuProvider = {
            Menu(items: [
                MenuItem(id: "copy", title: "Copy") {},
            ])
        }
        let window = Window(title: "Menu")
        window.setContentView(root)
        window.orderFront()
        let scene = WindowScene(inMemoryWindows: [window])
        scene.displayBounds = Rect(x: 0, y: 0, width: 400, height: 400)

        #expect(scene.dispatchEvent(Event(
            type: .pointerDown,
            location: Point(x: 20, y: 20),
            button: .right)) == .handled)
        #expect(scene.popovers.count == 1)
    }

    @Test func keyPopoverRestoresItsPriorWindowAndResponder() {
        let field = TextField(string: "")
        field.frame = Rect(x: 0, y: 0, width: 100, height: 24)
        let window = Window(title: "Original")
        window.setContentView(field)
        window.orderFront()
        let scene = WindowScene(inMemoryWindows: [window])
        scene.displayBounds = Rect(x: 0, y: 0, width: 400, height: 400)
        scene.makeKey(window)
        #expect(window.makeFirstResponder(field))

        let menu = Menu(items: [
            MenuItem(id: "one", title: "One") {},
        ])
        let presentation = scene.present(
            menu,
            anchor: Rect(x: 20, y: 20, width: 1, height: 1))
        #expect(scene.keyWindow !== window)
        #expect(scene.keyWindow?.firstResponder != nil)

        presentation.dismiss()
        #expect(scene.keyWindow === window)
        #expect(window.firstResponder === field)
        #expect(field.isFocused)
    }
}
