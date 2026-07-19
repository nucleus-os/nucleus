import Testing
import NucleusUI
import NucleusTypes

/// The payload blob is the one format written by `GraphicsContext` and read by
/// the rasterizer. Both sides live in different modules, so these tests pin the
/// round trip and — more importantly — the rejections, since a payload that
/// decodes *wrongly* would draw arbitrary geometry rather than fail.
@Suite struct PaintPayloadTests {
    @Test func regionsRoundTrip() throws {
        var blob: [UInt8] = []
        let slice = PaintPayload.append(
            to: &blob,
            verbs: [.move, .line, .close],
            points: [1, 2, 3, 4],
            scalars: [0.25, 0.75],
            colors: [Color(r: 1, g: 0, b: 0, a: 1), Color(r: 0, g: 0, b: 1, a: 0.5)])

        let regions = try #require(
            PaintPayload.decode(blob, offset: slice.offset, length: slice.length))
        #expect(regions.verbs == [.move, .line, .close])
        #expect(regions.points == [1, 2, 3, 4])
        #expect(regions.scalars == [0.25, 0.75])
        #expect(regions.colors.count == 2)
        #expect(regions.colors[1].b == 1)
        #expect(regions.colors[1].a == 0.5)
    }

    /// Appending is the only mutation, so a slice written earlier keeps its
    /// offset when more commands are appended. The publisher's `==` gate
    /// depends on this: shifting offsets would make identical drawings compare
    /// unequal and re-register every publish.
    @Test func appendingDoesNotMoveEarlierSlices() {
        var blob: [UInt8] = []
        let first = PaintPayload.append(to: &blob, verbs: [.move], points: [1, 2])
        let second = PaintPayload.append(to: &blob, verbs: [.move], points: [3, 4])

        #expect(first.offset == 0)
        #expect(second.offset == first.length)

        let firstRegions = PaintPayload.decode(blob, offset: first.offset, length: first.length)
        #expect(firstRegions?.points == [1, 2], "the earlier slice still decodes")
    }

    @Test func anEmptySliceRoundTripsAsEmptyRegions() throws {
        var blob: [UInt8] = []
        let slice = PaintPayload.append(to: &blob)
        let regions = try #require(
            PaintPayload.decode(blob, offset: slice.offset, length: slice.length))
        #expect(regions.verbs.isEmpty)
        #expect(regions.points.isEmpty)
    }

    /// Verbs consume a fixed number of floats. A point array that does not
    /// match must be rejected rather than silently building a shorter path.
    @Test func verbsThatOverConsumePointsAreRejected() {
        var blob: [UInt8] = []
        // Two verbs need four floats; supply two.
        let slice = PaintPayload.append(to: &blob, verbs: [.move, .line], points: [1, 2])
        #expect(PaintPayload.decode(blob, offset: slice.offset, length: slice.length) == nil)
    }

    @Test func aSliceRunningPastTheBlobIsRejected() {
        var blob: [UInt8] = []
        let slice = PaintPayload.append(to: &blob, verbs: [.move], points: [1, 2])
        #expect(PaintPayload.decode(blob, offset: slice.offset, length: slice.length + 4) == nil)
        #expect(PaintPayload.decode(blob, offset: 4, length: slice.length) == nil)
    }

    @Test func aTruncatedHeaderIsRejected() {
        let blob = [UInt8](repeating: 0, count: 8)
        #expect(PaintPayload.decode(blob, offset: 0, length: 8) == nil)
    }

    /// An unknown verb byte means the producer and this format disagree.
    @Test func anUnknownVerbIsRejected() {
        var blob: [UInt8] = []
        let slice = PaintPayload.append(to: &blob, verbs: [.move], points: [1, 2])
        var corrupted = blob
        corrupted[PaintPayload.headerByteCount] = 99
        #expect(PaintPayload.decode(corrupted, offset: slice.offset, length: slice.length) == nil)
    }

    /// Verbs are byte-packed and padded to a 4-byte boundary so the float
    /// regions stay aligned. Exercise a verb count that is not a multiple of 4.
    @Test func verbPaddingKeepsFloatRegionsAligned() throws {
        var blob: [UInt8] = []
        let slice = PaintPayload.append(
            to: &blob,
            verbs: [.move, .line, .line, .line, .close],  // 5 verbs → padded to 8
            points: [1, 2, 3, 4, 5, 6, 7, 8])
        let regions = try #require(
            PaintPayload.decode(blob, offset: slice.offset, length: slice.length))
        #expect(regions.points == [1, 2, 3, 4, 5, 6, 7, 8])
    }

    @Test func arcVerbsConsumeSixFloats() throws {
        var blob: [UInt8] = []
        let slice = PaintPayload.append(
            to: &blob, verbs: [.move, .arc], points: [0, 0, 10, 10, 20, 20, 0, 270])
        let regions = try #require(
            PaintPayload.decode(blob, offset: slice.offset, length: slice.length))
        #expect(regions.verbs == [.move, .arc])
        #expect(regions.points.count == 8)
    }
}

/// `GraphicsContext`'s graphics-state stack.
@MainActor
@Suite struct GraphicsStateTests {
    /// A view that saves and forgets to restore must not change how its own
    /// later commands render. Skia's canvas would otherwise stay saved, and a
    /// clip set after the save would leak forward through the recording.
    @Test func anUnbalancedSaveIsClosedOff() {
        let context = GraphicsContext()
        context.saveGState()
        context.clip(to: Rect(x: 0, y: 0, width: 10, height: 10))
        context.fill(Rect(x: 0, y: 0, width: 20, height: 20))

        let kinds = context.recording.commands.map(\.kind)
        #expect(kinds.first == .save)
        #expect(kinds.last == .restore, "the dangling save is balanced")
        #expect(kinds.filter { $0 == .save }.count == kinds.filter { $0 == .restore }.count)
    }

    @Test func nestedUnbalancedSavesAreAllClosed() {
        let context = GraphicsContext()
        context.saveGState()
        context.saveGState()
        context.fill(Rect(x: 0, y: 0, width: 10, height: 10))

        let kinds = context.recording.commands.map(\.kind)
        #expect(kinds.filter { $0 == .save }.count == 2)
        #expect(kinds.filter { $0 == .restore }.count == 2)
    }

    @Test func aBalancedScopeIsUnchanged() {
        let context = GraphicsContext()
        context.withGraphicsState {
            context.fill(Rect(x: 0, y: 0, width: 10, height: 10))
        }
        let kinds = context.recording.commands.map(\.kind)
        #expect(kinds == [.save, .path, .restore])
    }

    /// Reading `recording` must not consume or mutate the balancing, so a
    /// second read gives the same answer.
    @Test func readingTheRecordingTwiceIsStable() {
        let context = GraphicsContext()
        context.saveGState()
        context.fill(Rect(x: 0, y: 0, width: 10, height: 10))
        #expect(context.recording == context.recording)
        #expect(context.recording.commands.count == 3)
    }

    /// State is restored, not just the canvas: a color set inside a scope does
    /// not leak past it.
    @Test func restoringUndoesStateChanges() {
        let context = GraphicsContext()
        context.fillColor = Color(1, 0, 0, 1)
        context.withGraphicsState {
            context.fillColor = Color(0, 0, 1, 1)
        }
        #expect(context.fillColor == Color(1, 0, 0, 1))
    }
}

/// Stroke style reaching the command.
///
/// `lineCap` and `lineJoin` were public settable state that nothing encoded, so
/// a caller could ask for a rounded stroke and get a butt-capped one with no
/// indication anything had been ignored. The rasterizer's half is covered by
/// pixels in `StrokeCapJoinTests`; this is the producer's half.
@MainActor
@Suite struct StrokeStyleEncodingTests {
    private func strokedCommand(
        cap: LineCap, join: LineJoin
    ) -> NucleusTypes.PaintCommand? {
        let graphics = GraphicsContext()
        graphics.lineWidth = 4
        graphics.lineCap = cap
        graphics.lineJoin = join
        var path = Path()
        path.move(to: Point(x: 0, y: 0))
        path.addLine(to: Point(x: 10, y: 10))
        graphics.stroke(path)
        return graphics.recording.commands.first
    }

    @Test func theDefaultsCarryNoBits() {
        let command = strokedCommand(cap: .butt, join: .miter)
        #expect(command?.flags.contains(.capRound) == false)
        #expect(command?.flags.contains(.capSquare) == false)
        #expect(command?.flags.contains(.joinRound) == false)
        #expect(command?.flags.contains(.joinBevel) == false)
    }

    @Test func eachCapEncodesDistinctly() {
        #expect(strokedCommand(cap: .round, join: .miter)?.flags.contains(.capRound) == true)
        #expect(strokedCommand(cap: .square, join: .miter)?.flags.contains(.capSquare) == true)
        // A cap must not imply the other one.
        #expect(strokedCommand(cap: .round, join: .miter)?.flags.contains(.capSquare) == false)
    }

    @Test func eachJoinEncodesDistinctly() {
        #expect(strokedCommand(cap: .butt, join: .round)?.flags.contains(.joinRound) == true)
        #expect(strokedCommand(cap: .butt, join: .bevel)?.flags.contains(.joinBevel) == true)
        #expect(strokedCommand(cap: .butt, join: .round)?.flags.contains(.joinBevel) == false)
    }

    /// A fill has no ends and no corners to treat, so it must not claim to.
    @Test func aFillCarriesNoStrokeStyle() {
        let graphics = GraphicsContext()
        graphics.lineCap = .round
        graphics.lineJoin = .bevel
        graphics.fill(Rect(x: 0, y: 0, width: 10, height: 10))

        let command = graphics.recording.commands.first
        #expect(command?.flags.contains(.capRound) == false)
        #expect(command?.flags.contains(.joinBevel) == false)
    }
}
