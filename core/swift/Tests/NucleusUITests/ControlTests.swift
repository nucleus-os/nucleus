import NucleusTypes
@_spi(NucleusCompositor) @testable import NucleusUI
import Testing

@MainActor
@Suite(.uiContext) struct ControlTests {
    @Test func controlTracksPointerStateAndSendsPrimaryAction() throws {
        let control = Control()
        var actions = 0

        control.frame = (Rect(x: 0, y: 0, width: 40, height: 20))
        control.onPrimaryAction { sender in
            #expect(sender === control)
            actions += 1
        }

        #expect(control.handleEvent(Event(type: .pointerDown)) == .handled)
        #expect(control.isPressed)
        #expect(control.isHighlighted)

        #expect(control.handleEvent(Event(type: .pointerUp)) == .handled)
        #expect(!control.isPressed)
        #expect(!control.isHighlighted)
        #expect(actions == 1)
    }

    @Test func disabledControlClearsPressedStateAndDoesNotHandle() throws {
        let control = Control()

        #expect(control.handleEvent(Event(type: .pointerDown)) == .handled)
        #expect(control.isPressed)

        control.isEnabled = false

        #expect(!control.isPressed)
        #expect(!control.isHighlighted)
        #expect(control.handleEvent(Event(type: .pointerUp)) == .notHandled)
    }
}
