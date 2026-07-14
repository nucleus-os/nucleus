@_spi(NucleusCompositor) @testable import NucleusUI
import Testing

@MainActor
@Suite struct LayoutTests {
    final class LayoutCountingView: View {
        var layoutCount = 0

        override func layout() throws(UIError) {
            layoutCount += 1
        }
    }

    @Test func setNeedsLayoutAndLayoutIfNeeded() throws {
        let view = try LayoutCountingView()

        #expect(!view.needsLayout)
        view.setNeedsLayout()
        #expect(view.needsLayout)

        try view.layoutIfNeeded()

        #expect(!view.needsLayout)
        #expect(view.layoutCount == 1)
    }

    @Test func verticalStackUsesIntrinsicSizesAndSpacing() throws {
        let stack = try StackView(axis: .vertical, spacing: 4, alignment: .fill)
        let first = try Label("One")
        let second = try Button(title: "Go")

        stack.frame = (Rect(x: 10, y: 20, width: 200, height: 300))
        try stack.addArrangedSubview(first)
        try stack.addArrangedSubview(second)
        try stack.layoutIfNeeded()

        let firstHeight = first.intrinsicContentSize.height
        let secondHeight = second.intrinsicContentSize.height
        #expect(first.frame == Rect(x: 10, y: 20, width: 200, height: firstHeight))
        #expect(second.frame == Rect(x: 10, y: 20 + firstHeight + 4, width: 200, height: secondHeight))
    }

    @Test func horizontalStackCentersChildrenOnCrossAxis() throws {
        let stack = try StackView(axis: .horizontal, spacing: 10, alignment: .center)
        let first = try Label("Hi")
        let second = try Label("There")

        stack.frame = (Rect(x: 0, y: 0, width: 300, height: 100))
        try stack.addArrangedSubview(first)
        try stack.addArrangedSubview(second)
        try stack.layoutIfNeeded()

        let firstSize = first.intrinsicContentSize
        let secondSize = second.intrinsicContentSize
        #expect(first.frame == Rect(
            x: 0,
            y: (100 - firstSize.height) / 2,
            width: firstSize.width,
            height: firstSize.height
        ))
        #expect(second.frame == Rect(
            x: firstSize.width + 10,
            y: (100 - secondSize.height) / 2,
            width: secondSize.width,
            height: secondSize.height
        ))
    }

    @Test func textLayoutExposesFontMetricsAndBaselines() throws {
        let font = Font.systemFont(ofSize: 14)
        let layout = TextLayout(text: "gy", font: font)

        #expect(layout.intrinsicSize.width == TextLayout.measureWidth("gy", font: font))
        #expect(layout.intrinsicSize.height == layout.usedRect.size.height)
        #expect(layout.firstBaselineOffsetFromTop < layout.intrinsicSize.height)
        #expect(layout.lastBaselineOffsetFromBottom > 0)

        let commands = layout.layerContentCommands(color: Color(1, 1, 1, 1))
        let textCommand = try #require(commands.first)
        #expect(textCommand.kind == .textLayout)
        #expect(textCommand.y == 0)
        #expect(textCommand.h == Float(layout.intrinsicSize.height))
    }

    @Test func fontResolutionExposesBackendSelectedIdentity() throws {
        let font = Font(descriptor: FontDescriptor(
            familyName: "DefinitelyMissingNucleusFont",
            pointSize: 14,
            weight: .semibold,
            width: .condensed,
            slant: .italic
        ))
        let resolved = font.resolvedDescriptor

        #expect(!resolved.familyName.isEmpty)
        #expect(resolved.familyName != "DefinitelyMissingNucleusFont")
        #expect(!resolved.postScriptName.isEmpty)
        #expect(resolved.pointSize == 14)
        #expect(resolved.width == .standard)
        #expect(resolved.slant == .upright || resolved.slant == .italic || resolved.slant == .oblique)
        #expect(resolved != ResolvedFontDescriptor(
            familyName: "DefinitelyMissingNucleusFont",
            postScriptName: "DefinitelyMissingNucleusFont",
            pointSize: 14,
            weight: font.weight,
            width: font.width,
            slant: font.slant
        ))
    }

    @Test func fontDescriptorCarriesAppFacingTraitsThroughFontValues() throws {
        var font = Font(descriptor: FontDescriptor(
            familyName: "Inter",
            pointSize: 0,
            weight: .medium,
            width: .expanded,
            slant: .oblique
        ))

        #expect(font.descriptor.familyName == "Inter")
        #expect(font.pointSize == 1)
        #expect(font.weight == .medium)
        #expect(font.width == .expanded)
        #expect(font.slant == .oblique)

        font.width = .compressed
        font.slant = .upright

        #expect(font.descriptor.width == .compressed)
        #expect(font.descriptor.slant == .upright)
    }

    @Test func textLayoutWrapsIntoLineFragments() throws {
        let font = Font.systemFont(ofSize: 10)
        let layout = TextLayout(
            text: "One two three",
            font: font,
            containerWidth: 35,
            lineBreakMode: .byWordWrapping,
            numberOfLines: 3
        )

        #expect(layout.lines.count > 1)
        #expect(layout.lines.map(\.text).joined() == "One two three")
        #expect(layout.intrinsicSize.width == 35)
        let firstLine = try #require(layout.lines.first)
        #expect(layout.intrinsicSize.height > firstLine.frame.size.height)
        #expect(layout.lines[1].baselineY > layout.lines[0].baselineY)
    }

    @Test func textLayoutTruncatesTailWithinContainer() throws {
        let font = Font.systemFont(ofSize: 10)
        let layout = TextLayout(
            text: "Nucleus compositor",
            font: font,
            containerWidth: 42,
            lineBreakMode: .byTruncatingTail
        )

        let line = try #require(layout.lines.first)
        #expect(!line.text.isEmpty)
        #expect(line.sourceUTF16Range.lowerBound == 0)
        #expect(line.sourceUTF16Range.upperBound <= layout.text.utf16.count)
        #expect(line.isTruncated)
        #expect(layout.didExceedMaximumLineCount)
        #expect(line.frame.size.width <= 42)
    }

    @Test func textLayoutKeepsHitTestingAndSelectionRectsBackendOwned() throws {
        let font = Font.systemFont(ofSize: 14)
        let layout = TextLayout(
            text: "Hello world",
            font: font,
            containerWidth: 140,
            lineBreakMode: .byClipping
        )

        if let position = layout.glyphPosition(at: Point(x: layout.usedRect.size.width * 0.5, y: layout.firstBaselineOffsetFromTop)) {
            #expect(position.utf16Offset > 0)
            #expect(position.utf16Offset <= layout.text.utf16.count)

            let rects = layout.selectionRects(forUTF16Range: 0..<5)
            #expect(!rects.isEmpty)
            #expect(rects[0].rect.size.width > 0)
            #expect(rects[0].rect.size.height > 0)
            #expect(rects[0].direction == .leftToRight)
        } else {
            #expect(layout.selectionRects(forUTF16Range: 0..<5).isEmpty)
        }
    }

    @Test func textLayoutCarriesAttributedRunsToParagraphCommand() throws {
        let titleFont = Font.systemFont(ofSize: 14, weight: .semibold)
        let detailFont = Font.systemFont(ofSize: 10)
        let layout = TextLayout(runs: [
            TextRun(text: "Nucleus", font: titleFont, color: Color(1, 1, 1, 1)),
            TextRun(text: " compositor", font: detailFont, color: Color(0.72, 0.78, 0.86, 1))
        ])

        #expect(layout.text == "Nucleus compositor")
        #expect(layout.textRuns.count == 2)
        #expect(layout.intrinsicSize.width > TextLayout.measureWidth("Nucleus", font: titleFont))

        let command = try #require(layout.layerContentCommands(color: Color(1, 1, 1, 1)).first)
        #expect(command.kind == .textLayout)
        let commandLayout = try #require(command.textLayout)
        #expect(commandLayout.textRuns.count == 2)
        #expect(commandLayout.textRuns[0].font.weight == .semibold)
        #expect(commandLayout.textRuns[1].color == Color(0.72, 0.78, 0.86, 1))
    }

    @Test func textSystemLayoutsAttributedTextWithParagraphStyle() throws {
        let attributedText = AttributedText(runs: [
            TextRun(
                text: "Nucleus",
                style: TextStyle(
                    font: .systemFont(ofSize: 14, weight: .semibold),
                    color: Color(1, 1, 1, 1)
                )
            ),
            TextRun(
                text: " text",
                style: TextStyle(
                    font: .systemFont(ofSize: 10),
                    color: Color(0.72, 0.78, 0.86, 1)
                )
            )
        ])
        let paragraphStyle = ParagraphStyle(
            alignment: .leading,
            lineBreakMode: .byClipping,
            maximumLineCount: 1
        )

        let result = TextSystem.shared.layout(
            attributedText,
            containerWidth: nil,
            paragraphStyle: paragraphStyle
        )

        #expect(attributedText.string == "Nucleus text")
        #expect(result.lines.count == 1)
        #expect(result.usedRect.size.width > TextLayout.measureWidth("Nucleus", font: .systemFont(ofSize: 14, weight: .semibold)))
        let line = try #require(result.lines.first)
        #expect(line.sourceUTF16Range == 0..<attributedText.string.utf16.count)
        #expect(line.endExcludingWhitespace == attributedText.string.utf16.count)
        #expect(line.typographicAscent > 0)
        #expect(line.typographicDescent >= 0)
        #expect(!line.isTruncated)
    }

    @Test func labelPlacesFramesFromBaselineMetrics() throws {
        let label = try Label("Descenders gy")
        label.fontSize = 14

        label.placeBaseline(at: 30, x: 12, width: 140)

        #expect(label.frame.size.height == label.intrinsicContentSize.height)
        #expect(label.frame.size.height > Double(label.fontSize))
        #expect(abs((label.frame.origin.y + label.firstBaselineOffsetFromTop) - 30) < 0.001)
    }

    @Test func intrinsicInvalidationMarksParentLayoutDirty() throws {
        let stack = try StackView(axis: .vertical)
        let button = try Button(title: "OK")

        stack.frame = (Rect(x: 0, y: 0, width: 200, height: 100))
        try stack.addArrangedSubview(button)
        try stack.layoutIfNeeded()
        #expect(!stack.needsLayout)

        button.title = "Install Updates"

        #expect(button.needsIntrinsicContentSizeUpdate)
        #expect(stack.needsLayout)
    }

    @Test func stackFallsBackToExplicitFrameForNonIntrinsicChild() throws {
        let stack = try StackView(axis: .vertical, spacing: 2, alignment: .leading)
        let child = try View()

        stack.frame = (Rect(x: 5, y: 6, width: 100, height: 100))
        child.frame = (Rect(x: 0, y: 0, width: 44, height: 18))
        try stack.addArrangedSubview(child)
        try stack.layoutIfNeeded()

        #expect(child.frame == Rect(x: 5, y: 6, width: 44, height: 18))
    }

    @Test func stackRespectsLayoutMarginsAndHiddenArrangedSubviews() throws {
        let stack = try StackView(axis: .vertical, spacing: 3, alignment: .fill)
        let first = try Label("One")
        let hidden = try Label("Hidden")
        let second = try Label("Two")

        stack.frame = Rect(x: 10, y: 20, width: 120, height: 100)
        stack.layoutMargins = EdgeInsets(top: 4, left: 5, bottom: 6, right: 7)
        hidden.isHidden = true
        try stack.addArrangedSubview(first)
        try stack.addArrangedSubview(hidden)
        try stack.addArrangedSubview(second)
        try stack.layoutIfNeeded()

        let firstHeight = first.intrinsicContentSize.height
        let secondHeight = second.intrinsicContentSize.height
        #expect(first.frame == Rect(x: 15, y: 24, width: 108, height: firstHeight))
        #expect(second.frame == Rect(x: 15, y: 24 + firstHeight + 3, width: 108, height: secondHeight))
        #expect(hidden.frame == Rect(x: 0, y: 0, width: 0, height: 0))
    }

    @Test func arrangedSubviewRemovalTransitionsSerializeExitThenReflow() throws {
        let stack = try StackView(axis: .vertical, spacing: 2, alignment: .leading)
        let first = try View()
        let second = try View()
        let third = try View()
        var removed: [Int] = []

        stack.frame = Rect(x: 0, y: 0, width: 100, height: 100)
        first.frame = Rect(x: 0, y: 0, width: 20, height: 10)
        second.frame = Rect(x: 0, y: 0, width: 20, height: 10)
        third.frame = Rect(x: 0, y: 0, width: 20, height: 10)
        try stack.addArrangedSubview(first)
        try stack.addArrangedSubview(second)
        try stack.addArrangedSubview(third)
        try stack.layoutIfNeeded()

        let initialSecondY = second.frame.origin.y
        try stack.removeArrangedSubview(
            first,
            transition: .slideTrailingFade(duration: 0.10),
            reflow: .animated(duration: 0.10),
            nowNs: 1_000_000,
            didRemove: { removed.append(1) }
        )
        try stack.removeArrangedSubview(
            second,
            transition: .slideTrailingFade(duration: 0.10),
            reflow: .animated(duration: 0.10),
            nowNs: 1_000_000,
            didRemove: { removed.append(2) }
        )

        #expect(first.alphaValue == 0)
        #expect(second.alphaValue == 1)
        #expect(second.frame.origin.y == initialSecondY)

        try stack.advanceArrangedSubviewTransitions(nowNs: 101_000_000)
        #expect(removed == [1])
        #expect(!stack.arrangedSubviews.contains { $0 === first })
        #expect(second.frame.origin.y == 0)
        #expect(second.alphaValue == 1)

        try stack.advanceArrangedSubviewTransitions(nowNs: 201_000_000)
        #expect(second.alphaValue == 0)
        #expect(stack.arrangedSubviews.contains { $0 === second })

        try stack.advanceArrangedSubviewTransitions(nowNs: 301_000_000)
        #expect(removed == [1, 2])
        #expect(!stack.arrangedSubviews.contains { $0 === second })
        #expect(third.frame.origin.y == 0)
    }
}
