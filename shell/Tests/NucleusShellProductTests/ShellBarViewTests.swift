import Testing
import NucleusUI
@testable import NucleusShellProduct

/// The layout acceptance test for the external-client tier.
///
/// These run outside package `Nucleus` against views built from NucleusUI's
/// public layout API alone. Unlike the drawing tests next door, nothing here
/// needs `NucleusUIEmbedder` — layout state is product-tier, readable through
/// `frame` and `measure(_:)`.
@MainActor
@Suite struct ShellBarViewTests {
    private func makeBar(width: Double = 400) -> ShellBarView {
        let bar = ShellBarView()
        bar.frame = Rect(x: 0, y: 0, width: width, height: 26)
        return bar
    }

    private func makePill(width: Double) -> StatusPillView {
        let pill = StatusPillView()
        pill.frame = Rect(x: 0, y: 0, width: width, height: 18)
        pill.layoutBasis = width
        return pill
    }

    @Test func flexibleSpacePinsTrailingItemsToTheTrailingEdge() {
        let bar = makeBar(width: 400)
        bar.leadingItems.addArrangedSubview(makePill(width: 60))
        bar.trailingItems.addArrangedSubview(makePill(width: 40))
        bar.layoutIfNeeded()

        let trailing = bar.trailingItems.frame
        // 10pt trailing margin on the row.
        #expect(abs((trailing.origin.x + trailing.size.width) - 390) < 0.001)
        #expect(bar.leadingItems.frame.origin.x == 10)
    }

    /// The same tree at a different width, with no shell-side recomputation:
    /// the trailing group tracks the edge because the spacer absorbs the change.
    @Test func theBarReflowsWhenItsWidthChanges() {
        let bar = makeBar(width: 400)
        bar.leadingItems.addArrangedSubview(makePill(width: 60))
        let trailingPill = makePill(width: 40)
        bar.trailingItems.addArrangedSubview(trailingPill)
        bar.layoutIfNeeded()
        let narrowRight = bar.trailingItems.frame.origin.x

        bar.frame = Rect(x: 0, y: 0, width: 600, height: 26)
        bar.layoutIfNeeded()

        #expect(bar.trailingItems.frame.origin.x == narrowRight + 200)
        #expect(trailingPill.frame.size.width == 40, "the item itself did not stretch")
    }

    @Test func itemsAreCenteredOnTheCrossAxis() {
        let bar = makeBar(width: 400)
        let pill = makePill(width: 60)
        bar.leadingItems.addArrangedSubview(pill)
        bar.layoutIfNeeded()

        let group = bar.leadingItems.frame
        // The row's 4pt vertical margins leave 18pt of content height, which the
        // 18pt-tall group fills exactly.
        #expect(abs(group.origin.y - 4) < 0.001)
        #expect(abs(group.size.height - 18) < 0.001)
    }

    /// Bar items must remain reachable by a pointer once nested two stacks deep
    /// at a non-zero offset — the concrete failure that child-local placement fixes.
    @Test func aBarItemIsHittableThroughNestedStacks() {
        let bar = makeBar(width: 400)
        let pill = makePill(width: 60)
        bar.trailingItems.addArrangedSubview(pill)
        bar.layoutIfNeeded()

        let frame = pill.frame
        let group = bar.trailingItems.frame
        let inPill = Point(
            x: group.origin.x + frame.origin.x + frame.size.width / 2,
            y: group.origin.y + frame.origin.y + frame.size.height / 2)
        #expect(bar.hitTest(inPill) === pill)
    }

    // MARK: - Wrapped text

    /// Wrapped text participating in layout, which is what two-phase measurement
    /// exists for: the notice is taller in a narrow column than a wide one, with
    /// no size hardcoded by the shell.
    @Test func aNoticeGrowsTallerInANarrowerColumn() {
        let notice = ShellNoticeView(
            title: "Update available",
            body: "A new version of the compositor is ready to install and will "
                + "apply the next time the session restarts.")

        let wide = notice.measure(LayoutConstraints(maxWidth: 400))
        let narrow = notice.measure(LayoutConstraints(maxWidth: 140))

        #expect(narrow.height > wide.height)
        #expect(narrow.width <= 140)
    }

    @Test func aNoticeLaysItsBodyOutBelowItsTitle() {
        let notice = ShellNoticeView(title: "Update available", body: "Ready to install.")
        notice.frame = Rect(x: 20, y: 30, width: 200, height: notice.measure(
            LayoutConstraints(maxWidth: 200)).height)
        notice.layoutIfNeeded()

        let title = notice.titleLabel.frame
        let body = notice.bodyLabel.frame
        #expect(title.origin.y < body.origin.y)
        // Both are child-local within the column, which is itself inset by the
        // column's margins — not offset again by the notice's own position.
        #expect(title.origin.x == 10)
        #expect(body.origin.x == 10)
        #expect(title.origin.y == 8)
    }
}
