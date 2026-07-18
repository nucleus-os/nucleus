import Testing
import NucleusUI
import NucleusUIEmbedder
import NucleusTypes
@testable import NucleusShellProduct

/// The out-of-package authoring proof.
///
/// These run in `shell`, outside package `Nucleus`, against a view built only
/// from NucleusUI's public API. If any of this required layer, recording, or
/// registrar access, the capability would belong in NucleusUI rather than being
/// reached around — which is exactly the leak this phase closes.
///
/// The tests read what was drawn through `NucleusUIEmbedder`, a **test-only**
/// dependency. `NucleusShellProduct` itself depends on NucleusUI alone, and the
/// build enforces that — which is the boundary this phase exists to establish.
/// A product-tier inspection seam would be better than reaching for the
/// embedder here, and is the honest gap these tests document.
@MainActor
@Suite struct StatusPillViewTests {
    private func record(_ view: View) -> [PaintCommand] {
        view.displayIfNeeded()
        return view.recordedDrawing.paintCommands
    }

    private func makePill(width: Double = 72, height: Double = 18) -> StatusPillView {
        let pill = StatusPillView()
        pill.frame = Rect(x: 0, y: 0, width: width, height: height)
        return pill
    }

    @Test func aPillDrawsAFilledBodyAndAStrokedOutline() {
        let commands = record(makePill())
        #expect(commands.count == 2, "fill + outline")

        let fill = commands[0]
        #expect(fill.kind == .path)
        #expect(!fill.flags.contains(.stroke), "the body is filled")

        let outline = commands[1]
        #expect(outline.kind == .path)
        #expect(outline.flags.contains(.stroke), "the outline is stroked")
        #expect(outline.strokeWidth == 1)
    }

    @Test func emphasisSwitchesTheBodyToAGradient() {
        let plain = record(makePill())
        #expect(plain[0].shading == .color)

        let pill = makePill()
        pill.isEmphasized = true
        let emphasized = record(pill)
        #expect(emphasized[0].shading == .linearGradient)
    }

    @Test func aDotIndicatorAddsOneFilledPath() {
        let pill = makePill()
        pill.indicator = .dot(Color(1, 1, 1, 1))
        let commands = record(pill)

        #expect(commands.count == 3, "fill + outline + dot")
        let dot = commands[2]
        #expect(dot.kind == .path)
        #expect(!dot.flags.contains(.stroke))
    }

    /// A ring is a track plus a swept arc — two stroked paths, not a bespoke
    /// primitive. At zero progress the sweep is omitted entirely rather than
    /// emitting a degenerate arc.
    @Test func aRingIndicatorDrawsATrackAndASweep() {
        let pill = makePill()
        pill.indicator = .ring(Color(1, 1, 1, 1), progress: 0.5)
        let half = record(pill)
        #expect(half.count == 4, "fill + outline + track + sweep")
        #expect(half[3].flags.contains(.stroke))

        let empty = makePill()
        empty.indicator = .ring(Color(1, 1, 1, 1), progress: 0)
        #expect(record(empty).count == 3, "no sweep at zero progress")

        let over = makePill()
        over.indicator = .ring(Color(1, 1, 1, 1), progress: 5)
        #expect(record(over).count == 4, "progress clamps rather than dropping")
    }

    /// Re-recording an unchanged view must produce an equal recording. This is
    /// the publisher's re-registration gate: if equal drawings compared unequal,
    /// every view would re-register its paint content on every publish.
    @Test func anUnchangedDrawingRecordsEqually() {
        let pill = makePill()
        pill.indicator = .ring(Color(1, 1, 1, 1), progress: 0.25)
        let first = record(pill)

        pill.setNeedsDisplay()
        let second = record(pill)
        #expect(first == second)
    }

    @Test func changingAPropertyChangesTheRecording() {
        let pill = makePill()
        let before = record(pill)

        pill.accent = Color(1, 0, 0, 1)
        let after = record(pill)
        #expect(before != after)
    }

    /// An empty frame draws nothing at all, rather than emitting degenerate
    /// geometry the rasterizer would have to reject.
    @Test func aZeroSizedPillDrawsNothing() {
        let pill = makePill(width: 0, height: 0)
        #expect(record(pill).isEmpty)
    }
}
