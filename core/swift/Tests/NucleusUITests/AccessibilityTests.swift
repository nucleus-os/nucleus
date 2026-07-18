@_spi(NucleusCompositor) @testable import NucleusUI
import Testing

@MainActor
@Suite struct AccessibilityTests {
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
}
