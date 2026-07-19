import Testing
@testable import NucleusUI

/// Flexible empty space.
@MainActor
@Suite struct SpacerTests {
    @Test func aSpacerAbsorbsSurplusSpace() {
        let stack = StackView()
        stack.axis = .horizontal
        stack.frame = Rect(x: 0, y: 0, width: 200, height: 20)

        let left = View()
        left.frame = Rect(x: 0, y: 0, width: 40, height: 20)
        let right = View()
        right.frame = Rect(x: 0, y: 0, width: 60, height: 20)
        stack.addArrangedSubview(left)
        stack.addArrangedSubview(Spacer())
        stack.addArrangedSubview(right)
        stack.layoutIfNeeded()

        #expect(left.frame.origin.x == 0)
        #expect(right.frame.origin.x == 140, "pushed to the far edge by the slack")
    }

    /// Two spacers split what is left, which is how a bar centres its middle
    /// section.
    @Test func spacersShareTheSurplusEqually() {
        let stack = StackView()
        stack.axis = .horizontal
        stack.frame = Rect(x: 0, y: 0, width: 200, height: 20)

        let middle = View()
        middle.frame = Rect(x: 0, y: 0, width: 40, height: 20)
        stack.addArrangedSubview(Spacer())
        stack.addArrangedSubview(middle)
        stack.addArrangedSubview(Spacer())
        stack.layoutIfNeeded()

        #expect(middle.frame.origin.x == 80, "centred: 80 of slack on each side")
    }

    @Test func aMinimumLengthIsHeldEvenWithoutSurplus() {
        let spacer = Spacer(minimumLength: 12)
        #expect(spacer.intrinsicContentSize.width == 12)
        #expect(spacer.intrinsicContentSize.height == 12)
    }

    @Test func aSpacerHasNoNaturalSize() {
        #expect(Spacer().intrinsicContentSize == .zero)
    }

    /// Slack is the first thing to give up when a stack is over-full: a spacer
    /// shrinking is invisible, a label shrinking is not.
    @Test func aSpacerGrowsAndShrinks() {
        let spacer = Spacer()
        #expect(spacer.growFactor == 1)
        #expect(spacer.shrinkFactor == 1)
    }

    @Test func aSpacerIsNotAnAccessibilityElement() {
        #expect(!Spacer().isAccessibilityElement)
    }
}

/// Dividing rules.
@MainActor
@Suite struct SeparatorTests {
    /// Returns the stack too: it owns the separator, and letting it fall out of
    /// scope would leave `parentView` nil and the inference with nothing to read.
    private func separator(in axis: StackView.Axis) -> (StackView, Separator) {
        let stack = StackView()
        stack.axis = axis
        stack.frame = Rect(x: 0, y: 0, width: 100, height: 100)
        let separator = Separator()
        stack.addArrangedSubview(separator)
        return (stack, separator)
    }

    /// The orientation a caller means every time: a rule divides the items a
    /// stack arranged, so it lies across that axis.
    @Test func orientationIsInferredFromTheEnclosingStack() {
        let (columnStack, inColumn) = separator(in: .vertical)
        let (rowStack, inRow) = separator(in: .horizontal)
        #expect(inColumn.isHorizontalRule, "a rule in a column is horizontal")
        #expect(!inRow.isHorizontalRule, "a rule in a row is vertical")
        withExtendedLifetime((columnStack, rowStack)) {}
    }

    /// Outside a stack there is nothing to infer from. A horizontal rule is the
    /// commoner default.
    @Test func withoutAStackItIsAHorizontalRule() {
        #expect(Separator().isHorizontalRule)
    }

    @Test func anExplicitOrientationOverridesInference() {
        let (stack, separator) = separator(in: .vertical)
        separator.orientation = .vertical
        #expect(!separator.isHorizontalRule)
        withExtendedLifetime(stack) {}
    }

    /// Thick across, and nothing along — the stack stretches it the other way.
    @Test func theIntrinsicSizeIsThicknessAcrossOnly() {
        let horizontal = Separator(orientation: .horizontal)
        horizontal.thickness = 2
        #expect(horizontal.intrinsicContentSize == Size(width: 0, height: 2))

        let vertical = Separator(orientation: .vertical)
        vertical.thickness = 2
        #expect(vertical.intrinsicContentSize == Size(width: 2, height: 0))
    }

    /// Spacing is room on either side of the rule, so it counts twice.
    @Test func spacingAddsToBothSides() {
        let separator = Separator(orientation: .horizontal)
        separator.thickness = 1
        separator.spacing = 4
        #expect(separator.intrinsicContentSize.height == 9)
    }

    @Test func changingThicknessInvalidates() {
        let separator = Separator(orientation: .horizontal)
        separator.frame = Rect(x: 0, y: 0, width: 100, height: 10)
        separator.displayIfNeeded()
        separator.thickness = 3
        #expect(separator.needsDisplay)
    }

    @Test func aSeparatorIsNotAnAccessibilityElement() {
        #expect(!Separator().isAccessibilityElement)
    }
}

/// Progress bars.
@MainActor
@Suite struct ProgressBarTests {
    private func makeBar(width: Double = 100, height: Double = 8) -> ProgressBar {
        let bar = ProgressBar()
        bar.frame = Rect(x: 0, y: 0, width: width, height: height)
        return bar
    }

    private func fillClipFrame(_ bar: ProgressBar) -> Rect {
        bar.layoutIfNeeded()
        // The clip is the bar's only subview; the fill sits inside it.
        return bar.subviews.first?.frame ?? .zero
    }

    // MARK: - Value

    @Test func progressDrivesTheFilledWidth() {
        let bar = makeBar()
        bar.progress = 0.25
        #expect(fillClipFrame(bar).size.width == 25)

        bar.progress = 1
        #expect(fillClipFrame(bar).size.width == 100)
    }

    @Test func anEmptyBarShowsNoFill() {
        let bar = makeBar()
        #expect(fillClipFrame(bar).size.width == 0)
    }

    /// A caller dividing by a total that briefly reads zero should get an empty
    /// bar, not a broken one.
    @Test func outOfRangeValuesClamp() {
        let bar = makeBar()
        bar.progress = 5
        #expect(bar.progress == 1)
        bar.progress = -2
        #expect(bar.progress == 0)
    }

    /// One rule for everything that is not a number, rather than clamping
    /// infinity to full and NaN to empty — a caller producing either has a bug,
    /// and two behaviours would only make it harder to spot.
    @Test func aNonFiniteValueReadsAsEmpty() {
        let bar = makeBar()
        bar.progress = 0.5
        bar.progress = .nan
        #expect(bar.progress == 0)

        bar.progress = 0.5
        bar.progress = .infinity
        #expect(bar.progress == 0)
    }

    // MARK: - Geometry

    /// The fill is a full-size bar behind a moving window, so its rounded end
    /// matches the track's at any value. Drawing it at the fraction's width
    /// would square that end off.
    @Test func theFillIsFullSizeBehindAClip() {
        let bar = makeBar()
        bar.progress = 0.1
        bar.layoutIfNeeded()

        let clip = bar.subviews.first
        let fill = clip?.subviews.first
        #expect(clip?.frame.size.width == 10)
        #expect(fill?.frame.size.width == 100, "the fill is the whole bar; the window is small")
    }

    @Test func aCentredBarFillsOutwardFromTheMiddle() {
        let bar = makeBar()
        bar.orientation = .horizontalCentered
        bar.progress = 0.5
        let clip = fillClipFrame(bar)
        #expect(clip.size.width == 50)
        #expect(clip.origin.x == 25, "centred, so a quarter of the bar on each side")
    }

    /// A vertical meter reads upward, so it fills from the bottom.
    @Test func aVerticalBarFillsUpward() {
        let bar = makeBar(width: 8, height: 100)
        bar.orientation = .vertical
        bar.progress = 0.25
        let clip = fillClipFrame(bar)
        #expect(clip.size.height == 25)
        #expect(clip.origin.y == 75, "anchored to the bottom")
    }

    /// Fully rounded by default, which is what the reference uses everywhere.
    @Test func endsAreRoundedToHalfTheThickness() {
        let bar = makeBar(width: 100, height: 8)
        bar.progress = 0.5
        bar.layoutIfNeeded()
        #expect(bar.cornerRadius == 4)
    }

    @Test func anExplicitRadiusOverridesTheDefault() {
        let bar = makeBar()
        bar.barCornerRadius = 0
        bar.layoutIfNeeded()
        #expect(bar.cornerRadius == 0)
    }

    @Test func aBarHasThicknessButNoNaturalLength() {
        let bar = ProgressBar()
        #expect(bar.intrinsicContentSize.width == 0)
        #expect(bar.intrinsicContentSize.height > 0)

        bar.orientation = .vertical
        #expect(bar.intrinsicContentSize.height == 0)
        #expect(bar.intrinsicContentSize.width > 0)
    }

    // MARK: - Theming

    @Test func trackAndFillFollowThePalette() {
        let bar = makeBar()
        bar.palette = .dark
        bar.layoutIfNeeded()
        #expect(bar.backgroundColor == Palette.dark.surfaceVariant)

        bar.palette = .light
        #expect(bar.backgroundColor == Palette.light.surfaceVariant)
    }

    @Test func aBarDescribesItselfAsAProgressIndicator() {
        #expect(ProgressBar().accessibilityRole == .progressIndicator)
    }
}
