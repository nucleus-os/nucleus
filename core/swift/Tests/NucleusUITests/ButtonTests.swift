@_spi(NucleusCompositor) @testable import NucleusUI
import Testing

@MainActor
@Suite struct ButtonTests {
    @Test func buttonKeepsSwiftSemanticTitle() throws {
        let button = Button(title: "Save")
        #expect(button.title == "Save")

        button.title = "Save As"
        #expect(button.title == "Save As")
    }

    @Test func primaryActionFiresForButtonPress() throws {
        let button = Button(title: "OK")
        var pressed = false

        button.onPress { sender in
            #expect(sender === button)
            pressed = true
        }
        button.performPress()

        #expect(pressed)
    }

    @Test func buttonExposesGenericViewBehavior() throws {
        let button = Button(title: "Child")

        button.frame = (Rect(x: 1, y: 2, width: 3, height: 4))
        #expect(button.frame == Rect(x: 1, y: 2, width: 3, height: 4))
    }

    @Test func buttonAsWindowRootReleasesWithWindow() throws {
        weak var weakButton: View?
        do {
            let window = Window(title: "Button Root")
            let button = Button(title: "Root")
            weakButton = button

            window.setRootView(button)
            #expect(weakButton != nil)
        }

        #expect(weakButton == nil)
    }
}
