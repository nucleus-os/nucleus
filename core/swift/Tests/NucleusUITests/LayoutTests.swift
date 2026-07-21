@_spi(NucleusCompositor) @testable import NucleusUI
import Testing

@MainActor
@Suite(.uiContext) struct LayoutTests {
    init() {
        installTestTextBackend()
    }

    final class LayoutCountingView: View {
        var layoutCount = 0

        override func layout() {
            layoutCount += 1
        }
    }

    final class BaselineView: View, LayoutBaselineProviding {
        let desiredSize: Size
        let metrics: LayoutBaselineMetrics

        init(size: Size, first: Double, last: Double) {
            desiredSize = size
            metrics = LayoutBaselineMetrics(
                firstFromTop: first, lastFromBottom: last)
            super.init()
        }

        override var intrinsicContentSize: Size { desiredSize }

        func layoutBaselines(for size: Size) -> LayoutBaselineMetrics {
            _ = size
            return metrics
        }
    }

    @Test func setNeedsLayoutAndLayoutIfNeeded() throws {
        let view = LayoutCountingView()

        #expect(!view.needsLayout)
        view.setNeedsLayout()
        #expect(view.needsLayout)

        view.layoutIfNeeded()

        #expect(!view.needsLayout)
        #expect(view.layoutCount == 1)
    }

    @Test func verticalStackUsesIntrinsicSizesAndSpacing() throws {
        let stack = StackView(axis: .vertical, spacing: 4, alignment: .fill)
        let first = Label("One")
        let second = Button(title: "Go")

        stack.frame = (Rect(x: 10, y: 20, width: 200, height: 300))
        stack.addArrangedSubview(first)
        stack.addArrangedSubview(second)
        stack.layoutIfNeeded()

        let firstHeight = first.intrinsicContentSize.height
        let secondHeight = second.intrinsicContentSize.height
        // Child frames are relative to the stack, not to the stack's own
        // position in its parent. The stack sitting at (10, 20) must not push
        // its children by that much again.
        #expect(first.frame == Rect(x: 0, y: 0, width: 200, height: firstHeight))
        #expect(second.frame == Rect(x: 0, y: firstHeight + 4, width: 200, height: secondHeight))
    }

    @Test func horizontalStackCentersChildrenOnCrossAxis() throws {
        let stack = StackView(axis: .horizontal, spacing: 10, alignment: .center)
        let first = Label("Hi")
        let second = Label("There")

        stack.frame = (Rect(x: 0, y: 0, width: 300, height: 100))
        stack.addArrangedSubview(first)
        stack.addArrangedSubview(second)
        stack.layoutIfNeeded()

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
        let layout = TextLayout(
            text: "gy",
            font: font,
            textSystem: testTextSystem())

        #expect(layout.intrinsicSize.width == TextLayout.measureWidth(
            "gy", font: font, in: testTextSystem()))
        #expect(layout.intrinsicSize.height == layout.usedRect.size.height)
        #expect(layout.firstBaselineOffsetFromTop < layout.intrinsicSize.height)
        #expect(layout.lastBaselineOffsetFromBottom > 0)

        let context = GraphicsContext(textSystem: testTextSystem())
        context.fillColor = Color(1, 1, 1, 1)
        context.draw(layout, in: Rect(
            x: 0, y: 0,
            width: layout.usedRect.size.width, height: layout.usedRect.size.height))
        let textCommand = try #require(context.recording.commands.first)
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
        let resolved = font.resolvedDescriptor(in: testTextSystem())

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
            numberOfLines: 3,
            textSystem: testTextSystem()
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
            lineBreakMode: .byTruncatingTail,
            textSystem: testTextSystem()
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
            lineBreakMode: .byClipping,
            textSystem: testTextSystem()
        )

        if let position = layout.glyphPosition(
            at: Point(
                x: layout.usedRect.size.width * 0.5,
                y: layout.firstBaselineOffsetFromTop),
            in: testTextSystem())
        {
            #expect(position.utf16Offset > 0)
            #expect(position.utf16Offset <= layout.text.utf16.count)

            let rects = layout.selectionRects(
                forUTF16Range: 0..<5,
                in: testTextSystem())
            #expect(!rects.isEmpty)
            #expect(rects[0].rect.size.width > 0)
            #expect(rects[0].rect.size.height > 0)
            #expect(rects[0].direction == .leftToRight)
        } else {
            #expect(layout.selectionRects(
                forUTF16Range: 0..<5,
                in: testTextSystem()).isEmpty)
        }
    }

    @Test func textLayoutCarriesAttributedRunsToParagraphCommand() throws {
        let titleFont = Font.systemFont(ofSize: 14, weight: .semibold)
        let detailFont = Font.systemFont(ofSize: 10)
        let layout = TextLayout(
            runs: [
                TextRun(text: "Nucleus", font: titleFont, color: Color(1, 1, 1, 1)),
                TextRun(text: " compositor", font: detailFont, color: Color(0.72, 0.78, 0.86, 1)),
            ],
            textSystem: testTextSystem())

        #expect(layout.text == "Nucleus compositor")
        #expect(layout.textRuns.count == 2)
        #expect(layout.intrinsicSize.width > TextLayout.measureWidth(
            "Nucleus", font: titleFont, in: testTextSystem()))

        let context = GraphicsContext(textSystem: testTextSystem())
        context.fillColor = Color(1, 1, 1, 1)
        context.draw(layout, in: Rect(x: 0, y: 0, width: 100, height: 20))
        let command = try #require(context.recording.commands.first)
        #expect(command.kind == .textLayout)
        // The handle is a one-based index into the recording's layouts, not a
        // registry handle — nothing is minted while drawing.
        #expect(command.textLayoutHandle == 1)
        let commandLayout = try #require(context.recording.textLayouts.first)
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

        let result = testTextSystem().layout(
            attributedText,
            containerWidth: nil,
            paragraphStyle: paragraphStyle
        )

        #expect(attributedText.string == "Nucleus text")
        #expect(result.lines.count == 1)
        #expect(result.usedRect.size.width > TextLayout.measureWidth(
            "Nucleus",
            font: .systemFont(ofSize: 14, weight: .semibold),
            in: testTextSystem()))
        let line = try #require(result.lines.first)
        #expect(line.sourceUTF16Range == 0..<attributedText.string.utf16.count)
        #expect(line.endExcludingWhitespace == attributedText.string.utf16.count)
        #expect(line.typographicAscent > 0)
        #expect(line.typographicDescent >= 0)
        #expect(!line.isTruncated)
    }

    @Test func labelPlacesFramesFromBaselineMetrics() throws {
        let label = Label("Descenders gy")
        label.fontSize = 14

        label.placeBaseline(at: 30, x: 12, width: 140)

        #expect(label.frame.size.height == label.intrinsicContentSize.height)
        #expect(label.frame.size.height > Double(label.fontSize))
        #expect(abs((label.frame.origin.y + label.firstBaselineOffsetFromTop) - 30) < 0.001)
    }

    @Test func intrinsicInvalidationMarksParentLayoutDirty() throws {
        let stack = StackView(axis: .vertical)
        let button = Button(title: "OK")

        stack.frame = (Rect(x: 0, y: 0, width: 200, height: 100))
        stack.addArrangedSubview(button)
        stack.layoutIfNeeded()
        #expect(!stack.needsLayout)

        button.title = "Install Updates"

        #expect(button.needsIntrinsicContentSizeUpdate)
        #expect(stack.needsLayout)
    }

    @Test func stackFallsBackToExplicitFrameForNonIntrinsicChild() throws {
        let stack = StackView(axis: .vertical, spacing: 2, alignment: .leading)
        let child = View()

        stack.frame = (Rect(x: 5, y: 6, width: 100, height: 100))
        child.frame = (Rect(x: 0, y: 0, width: 44, height: 18))
        stack.addArrangedSubview(child)
        stack.layoutIfNeeded()

        #expect(child.frame == Rect(x: 0, y: 0, width: 44, height: 18))
    }

    @Test func stackRespectsLayoutMarginsAndHiddenArrangedSubviews() throws {
        let stack = StackView(axis: .vertical, spacing: 3, alignment: .fill)
        let first = Label("One")
        let hidden = Label("Hidden")
        let second = Label("Two")

        stack.frame = Rect(x: 10, y: 20, width: 120, height: 100)
        stack.layoutMargins = EdgeInsets(top: 4, left: 5, bottom: 6, right: 7)
        hidden.isHidden = true
        stack.addArrangedSubview(first)
        stack.addArrangedSubview(hidden)
        stack.addArrangedSubview(second)
        stack.layoutIfNeeded()

        let firstHeight = first.intrinsicContentSize.height
        let secondHeight = second.intrinsicContentSize.height
        // Only the margins offset the children — the stack's own origin does not.
        #expect(first.frame == Rect(x: 5, y: 4, width: 108, height: firstHeight))
        #expect(second.frame == Rect(x: 5, y: 4 + firstHeight + 3, width: 108, height: secondHeight))
        #expect(hidden.frame == Rect(x: 0, y: 0, width: 0, height: 0))
    }

    /// The point of child-local placement: an arranged subview in a stack that
    /// is not at the origin must still be reachable by a pointer. Parent-space
    /// placement double-counted the stack's origin, pushing every child out of
    /// the region `hitTest` searches.
    @Test func arrangedSubviewsAreHittable() throws {
        let root = View()
        root.frame = Rect(x: 0, y: 0, width: 300, height: 300)
        let stack = StackView(axis: .vertical, spacing: 0, alignment: .fill)
        stack.frame = Rect(x: 40, y: 50, width: 100, height: 200)
        let child = Button(title: "Hit me")
        root.addSubview(stack)
        stack.addArrangedSubview(child)
        stack.layoutIfNeeded()

        // A point inside the child, expressed in the root's coordinates.
        let inChild = Point(x: 40 + 10, y: 50 + 5)
        #expect(root.hitTest(inChild) === child)
    }

    // MARK: - measure

    @Test func measuringUnconstrainedMatchesTheIntrinsicSize() throws {
        let label = Label("Some text")
        #expect(label.measure(.unconstrained) == label.intrinsicContentSize)
    }

    /// The case `intrinsicContentSize` structurally cannot answer: a wrapped
    /// label is taller at a narrow width than at a wide one.
    @Test func aLabelMeasuresTallerWhenOfferedLessWidth() throws {
        let label = Label("One two three four five six")
        label.font = .systemFont(ofSize: 10)
        label.lineBreakMode = .byWordWrapping
        label.numberOfLines = 5

        let wide = label.measure(LayoutConstraints(maxWidth: 400))
        let narrow = label.measure(LayoutConstraints(maxWidth: 60))

        #expect(narrow.height > wide.height)
        #expect(narrow.width <= 60)
    }

    @Test func tightConstraintsOverrideWhatAViewWants() throws {
        let button = Button(title: "A very long button title indeed")
        let size = button.measure(.tight(Size(width: 30, height: 12)))
        #expect(size == Size(width: 30, height: 12))
    }

    @Test func constraintsInsetReservesSpaceOnBothAxes() throws {
        let inner = LayoutConstraints(maxWidth: 100, maxHeight: 50)
            .inset(by: EdgeInsets(top: 4, left: 5, bottom: 6, right: 7))
        #expect(inner.maxWidth == 88)
        #expect(inner.maxHeight == 40)
        // An unbounded axis stays unbounded rather than going negative.
        #expect(LayoutConstraints.unconstrained
            .inset(by: EdgeInsets(top: 10, left: 10)).maxWidth == .infinity)
    }

    @Test func constraintsCanonicalizeEveryInvalidRangeAndResult() {
        let constraints = LayoutConstraints(
            minWidth: .nan,
            maxWidth: -.infinity,
            minHeight: .infinity,
            maxHeight: -10)
        #expect(constraints == LayoutConstraints(
            minWidth: 0, maxWidth: 0, minHeight: 0, maxHeight: 0))
        #expect(constraints.constrain(Size(width: .nan, height: .infinity)) == .zero)

        let reversed = LayoutConstraints(
            minWidth: 40, maxWidth: 10,
            minHeight: 20, maxHeight: 5)
        #expect(reversed.minWidth == 40 && reversed.maxWidth == 40)
        #expect(reversed.minHeight == 20 && reversed.maxHeight == 20)

        let inset = LayoutConstraints(maxWidth: 100, maxHeight: 100).inset(
            by: EdgeInsets(top: .nan, left: -.infinity, bottom: 10, right: 20))
        #expect(inset.maxWidth == 80)
        #expect(inset.maxHeight == 90)
    }

    /// A stack reports its own size from its children, so nesting works.
    @Test func aStackMeasuresFromItsChildrenPlusSpacingAndMargins() throws {
        let stack = StackView(axis: .vertical, spacing: 4, alignment: .leading)
        stack.layoutMargins = EdgeInsets(top: 2, left: 3, bottom: 2, right: 3)
        let first = Label("One")
        let second = Label("Two")
        stack.addArrangedSubview(first)
        stack.addArrangedSubview(second)

        let measured = stack.measure(.unconstrained)
        let expectedHeight = first.intrinsicContentSize.height
            + second.intrinsicContentSize.height + 4 + 4
        #expect(abs(measured.height - expectedHeight) < 0.001)
        #expect(measured.width > 0)
    }

    // MARK: - Flex and distribution

    @Test func growFactorsSplitSurplusSpace() throws {
        let stack = StackView(axis: .horizontal, spacing: 0, alignment: .fill)
        stack.frame = Rect(x: 0, y: 0, width: 300, height: 40)
        let fixed = View()
        fixed.frame = Rect(x: 0, y: 0, width: 100, height: 40)
        let flexible = View()
        flexible.frame = Rect(x: 0, y: 0, width: 50, height: 40)
        flexible.growFactor = 1
        stack.addArrangedSubview(fixed)
        stack.addArrangedSubview(flexible)
        stack.layoutIfNeeded()

        // 150 used, 150 surplus, all of it to the one growing child.
        #expect(fixed.frame.size.width == 100)
        #expect(flexible.frame.size.width == 200)
        #expect(flexible.frame.origin.x == 100)
    }

    @Test func surplusIsSplitInProportionToGrowFactors() throws {
        let stack = StackView(axis: .horizontal, spacing: 0, alignment: .fill)
        stack.frame = Rect(x: 0, y: 0, width: 300, height: 40)
        let one = View()
        one.frame = Rect(x: 0, y: 0, width: 50, height: 40)
        one.growFactor = 1
        let three = View()
        three.frame = Rect(x: 0, y: 0, width: 50, height: 40)
        three.growFactor = 3
        stack.addArrangedSubview(one)
        stack.addArrangedSubview(three)
        stack.layoutIfNeeded()

        // 200 surplus split 1:3.
        #expect(one.frame.size.width == 100)
        #expect(three.frame.size.width == 200)
    }

    @Test func overflowShrinksChildrenRatherThanRunningPastTheEdge() throws {
        let stack = StackView(axis: .horizontal, spacing: 0, alignment: .fill)
        stack.frame = Rect(x: 0, y: 0, width: 100, height: 40)
        let first = View()
        first.frame = Rect(x: 0, y: 0, width: 100, height: 40)
        let second = View()
        second.frame = Rect(x: 0, y: 0, width: 100, height: 40)
        stack.addArrangedSubview(first)
        stack.addArrangedSubview(second)
        stack.layoutIfNeeded()

        #expect(first.frame.size.width == 50)
        #expect(second.frame.size.width == 50)
        #expect(second.frame.origin.x + second.frame.size.width == 100)
    }

    @Test func aZeroShrinkFactorHoldsAChildAtItsMeasuredSize() throws {
        let stack = StackView(axis: .horizontal, spacing: 0, alignment: .fill)
        stack.frame = Rect(x: 0, y: 0, width: 100, height: 40)
        let rigid = View()
        rigid.frame = Rect(x: 0, y: 0, width: 100, height: 40)
        rigid.shrinkFactor = 0
        let yielding = View()
        yielding.frame = Rect(x: 0, y: 0, width: 100, height: 40)
        stack.addArrangedSubview(rigid)
        stack.addArrangedSubview(yielding)
        stack.layoutIfNeeded()

        #expect(rigid.frame.size.width == 100)
        #expect(yielding.frame.size.width == 0)
    }

    @Test func stackShrinkFreezesMinimumsAndRedistributesTheRemainingDeficit() {
        let stack = StackView(axis: .horizontal, alignment: .fill)
        stack.frame = Rect(x: 0, y: 0, width: 120, height: 20)
        let minimumBound = View()
        minimumBound.frame = Rect(x: 0, y: 0, width: 100, height: 20)
        minimumBound.minimumLayoutExtent = 80
        let flexible = View()
        flexible.frame = Rect(x: 0, y: 0, width: 100, height: 20)
        flexible.minimumLayoutExtent = 0
        stack.addArrangedSubview(minimumBound)
        stack.addArrangedSubview(flexible)

        stack.layoutIfNeeded()

        #expect(abs(minimumBound.frame.size.width - 80) < 0.001)
        #expect(abs(flexible.frame.size.width - 40) < 0.001)
        #expect(abs(flexible.frame.origin.x + flexible.frame.size.width - 120) < 0.001)
    }

    @Test func equalSpacingContractsItsGapsWhenTheMinimumDoesNotFit() {
        let stack = StackView(
            axis: .horizontal, spacing: 20,
            alignment: .fill, distribution: .equalSpacing)
        stack.frame = Rect(x: 0, y: 0, width: 110, height: 20)
        let first = View()
        first.frame = Rect(x: 0, y: 0, width: 50, height: 20)
        let second = View()
        second.frame = Rect(x: 0, y: 0, width: 50, height: 20)
        stack.addArrangedSubview(first)
        stack.addArrangedSubview(second)

        stack.layoutIfNeeded()

        #expect(first.frame.size.width == 50)
        #expect(second.frame.size.width == 50)
        #expect(second.frame.origin.x == 60, "the gap contracts from 20 to 10")
        #expect(second.frame.origin.x + second.frame.size.width == 110)
    }

    @Test func firstAndLastBaselineAlignmentUseChildMetrics() {
        let first = BaselineView(
            size: Size(width: 20, height: 20), first: 5, last: 3)
        let second = BaselineView(
            size: Size(width: 20, height: 30), first: 12, last: 7)
        let stack = StackView(
            axis: .horizontal, alignment: .firstBaseline)
        stack.frame = Rect(x: 0, y: 0, width: 100, height: 50)
        stack.addArrangedSubview(first)
        stack.addArrangedSubview(second)

        stack.layoutIfNeeded()
        #expect(first.frame.origin.y + 5 == second.frame.origin.y + 12)

        stack.alignment = .lastBaseline
        stack.layoutIfNeeded()
        #expect(
            first.frame.origin.y + first.frame.size.height - 3 ==
                second.frame.origin.y + second.frame.size.height - 7)
    }

    @Test func layoutBasisOverridesTheMeasuredMainAxisSize() throws {
        let stack = StackView(axis: .vertical, spacing: 0, alignment: .fill)
        stack.frame = Rect(x: 0, y: 0, width: 100, height: 200)
        let label = Label("One")
        label.layoutBasis = 44
        stack.addArrangedSubview(label)
        stack.layoutIfNeeded()

        #expect(label.frame.size.height == 44)
        #expect(label.intrinsicContentSize.height != 44)
    }

    @Test func fillEquallyGivesEveryChildTheSameMainAxisSize() throws {
        let stack = StackView(
            axis: .horizontal, spacing: 10, alignment: .fill, distribution: .fillEqually)
        stack.frame = Rect(x: 0, y: 0, width: 320, height: 40)
        let views = (0..<3).map { _ -> View in
            let view = View()
            view.frame = Rect(x: 0, y: 0, width: 10, height: 40)
            stack.addArrangedSubview(view)
            return view
        }
        stack.layoutIfNeeded()

        // (320 - 20 spacing) / 3
        for view in views {
            #expect(abs(view.frame.size.width - 100) < 0.001)
        }
        #expect(abs(views[2].frame.origin.x - 220) < 0.001)
    }

    @Test func equalSpacingKeepsSizesAndWidensTheGaps() throws {
        let stack = StackView(
            axis: .horizontal, spacing: 0, alignment: .fill, distribution: .equalSpacing)
        stack.frame = Rect(x: 0, y: 0, width: 300, height: 40)
        let first = View()
        first.frame = Rect(x: 0, y: 0, width: 50, height: 40)
        let second = View()
        second.frame = Rect(x: 0, y: 0, width: 50, height: 40)
        stack.addArrangedSubview(first)
        stack.addArrangedSubview(second)
        stack.layoutIfNeeded()

        #expect(first.frame.size.width == 50)
        #expect(second.frame.size.width == 50)
        #expect(second.frame.origin.x == 250)
    }

    // MARK: - Dirty tracking

    /// A clean subtree is skipped outright, so a per-frame pass over a settled
    /// tree does no work at all.
    @Test func aCleanSubtreeIsNotWalked() throws {
        let root = LayoutCountingView()
        root.frame = Rect(x: 0, y: 0, width: 100, height: 100)
        let child = LayoutCountingView()
        root.addSubview(child)
        root.layoutIfNeeded()
        let baseline = child.layoutCount

        root.layoutIfNeeded()
        #expect(child.layoutCount == baseline, "nothing was dirty, so nothing ran")
    }

    /// But a dirty descendant is still reached through a clean ancestor.
    @Test func aDirtyDescendantIsReachedThroughACleanAncestor() throws {
        let root = LayoutCountingView()
        root.frame = Rect(x: 0, y: 0, width: 100, height: 100)
        let middle = View()
        let leaf = LayoutCountingView()
        root.addSubview(middle)
        middle.addSubview(leaf)
        root.layoutIfNeeded()
        let baseline = leaf.layoutCount

        leaf.setNeedsLayout()
        root.layoutIfNeeded()
        #expect(leaf.layoutCount == baseline + 1)
    }

    /// Reading a view's size is a question, not a mutation. The getter used to
    /// clear the invalidation flag as a side effect, so anything that merely
    /// measured a view silently marked it clean.
    @Test func readingIntrinsicContentSizeDoesNotClearInvalidation() throws {
        let button = Button(title: "OK")
        button.title = "Install Updates"
        #expect(button.needsIntrinsicContentSizeUpdate)

        _ = button.intrinsicContentSize
        #expect(button.needsIntrinsicContentSizeUpdate, "asking is not answering")

        button.layoutIfNeeded()
        #expect(!button.needsIntrinsicContentSizeUpdate, "the layout pass consumed it")
    }

    @Test func arrangedSubviewRemovalTransitionsSerializeExitThenReflow() throws {
        let stack = StackView(axis: .vertical, spacing: 2, alignment: .leading)
        let first = View()
        let second = View()
        let third = View()
        var removed: [Int] = []

        stack.frame = Rect(x: 0, y: 0, width: 100, height: 100)
        first.frame = Rect(x: 0, y: 0, width: 20, height: 10)
        second.frame = Rect(x: 0, y: 0, width: 20, height: 10)
        third.frame = Rect(x: 0, y: 0, width: 20, height: 10)
        stack.addArrangedSubview(first)
        stack.addArrangedSubview(second)
        stack.addArrangedSubview(third)
        stack.layoutIfNeeded()

        let initialSecondY = second.frame.origin.y
        stack.removeArrangedSubview(
            first,
            transition: .slideTrailingFade(duration: 0.10),
            reflow: .animated(duration: 0.10),
            didRemove: { removed.append(1) }
        )
        stack.removeArrangedSubview(
            second,
            transition: .slideTrailingFade(duration: 0.10),
            reflow: .animated(duration: 0.10),
            didRemove: { removed.append(2) }
        )

        #expect(first.alphaValue == 1)
        #expect(second.alphaValue == 1)
        #expect(second.frame.origin.y == initialSecondY)

        _ = stack.uiContext.advanceAnimations(
            predictedPresentationNanoseconds: 1_000_000
        )
        _ = stack.uiContext.advanceAnimations(
            predictedPresentationNanoseconds: 101_000_000
        )
        #expect(removed == [1])
        #expect(!stack.arrangedSubviews.contains { $0 === first })
        #expect(second.frame.origin.y == initialSecondY)
        #expect(second.alphaValue == 1)

        _ = stack.uiContext.advanceAnimations(
            predictedPresentationNanoseconds: 201_000_000
        )
        #expect(second.frame.origin.y == 0)
        #expect(second.alphaValue == 1)
        #expect(stack.arrangedSubviews.contains { $0 === second })

        _ = stack.uiContext.advanceAnimations(
            predictedPresentationNanoseconds: 301_000_000
        )
        #expect(removed == [1, 2])
        #expect(!stack.arrangedSubviews.contains { $0 === second })
        _ = stack.uiContext.advanceAnimations(
            predictedPresentationNanoseconds: 401_000_000
        )
        #expect(third.frame.origin.y == 0)
    }
}
