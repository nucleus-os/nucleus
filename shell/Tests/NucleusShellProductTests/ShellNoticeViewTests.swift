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
@Suite struct ShellNoticeViewTests {
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
