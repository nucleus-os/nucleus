@_spi(NucleusCompositor) @testable import NucleusUI
import Testing

@MainActor
@Suite struct StaticControlTests {
    @Test func buttonIntrinsicSizeTracksTitle() throws {
        let button = Button(title: "OK")
        let initial = button.intrinsicContentSize

        button.title = "Install Updates"

        #expect(button.needsIntrinsicContentSizeUpdate)
        let updated = button.intrinsicContentSize
        #expect(updated.width > initial.width)
        // Reading the size does not clear the flag — the layout pass that
        // consumes the new size does.
        #expect(button.needsIntrinsicContentSizeUpdate)
        button.layoutIfNeeded()
        #expect(!button.needsIntrinsicContentSizeUpdate)
    }

    @Test func labelIsGenericViewWithTextIntrinsicSize() throws {
        let label = Label("Nucleus")
        let layout = TextLayout(text: "Nucleus", font: label.font)

        #expect(label.alignment == .leading)
        #expect(label.intrinsicContentSize == layout.intrinsicSize)

        label.text = ""
        #expect(label.needsIntrinsicContentSizeUpdate)
        #expect(label.intrinsicContentSize == .zero)
    }

    @Test func imageViewUsesGenericImageHandleAndSize() throws {
        let handle = ImageHandle(id: 42)
        let imageView = ImageView(image: handle, imageSize: Size(width: 320, height: 180))

        #expect(imageView.image?.id == 42)
        #expect(imageView.intrinsicContentSize == Size(width: 320, height: 180))

        imageView.image = nil
        #expect(imageView.needsIntrinsicContentSizeUpdate)
        #expect(imageView.intrinsicContentSize == .zero)
    }
}
