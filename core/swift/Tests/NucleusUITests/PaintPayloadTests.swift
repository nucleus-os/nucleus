import Testing
import class NucleusUI.GraphicsContext
import enum NucleusUI.LineCap
import enum NucleusUI.LineJoin
import enum NucleusUI.Shading
import struct NucleusUI.AffineTransform
import struct NucleusUI.Color
import struct NucleusUI.GradientStop
import struct NucleusUI.ImageHandle
import struct NucleusUI.Path
import struct NucleusUI.Point
import struct NucleusUI.Rect
import enum NucleusTypes.PaintPayload
import enum NucleusTypes.PaintPathVerb
import struct NucleusTypes.PaintCommand
import struct NucleusTypes.Color

private typealias UIColor = NucleusUI.Color
private typealias WireColor = NucleusTypes.Color

/// The payload blob is the one format written by `GraphicsContext` and read by
/// the rasterizer. Both sides live in different modules, so these tests pin the
/// round trip and — more importantly — the rejections, since a payload that
/// decodes *wrongly* would draw arbitrary geometry rather than fail.
@Suite(.uiContext) struct PaintPayloadTests {
    @Test func regionsRoundTrip() throws {
        var blob: [UInt8] = []
        let slice = PaintPayload.append(
            to: &blob,
            verbs: [.move, .line, .close],
            points: [1, 2, 3, 4],
            scalars: [0.25, 0.75],
            colors: [
                WireColor(r: 1, g: 0, b: 0, a: 1),
                WireColor(r: 0, g: 0, b: 1, a: 0.5),
            ])

        let regions = try #require(
            PaintPayload.decode(blob, offset: slice.offset, length: slice.length))
        #expect(regions.verbs == [
            PaintPathVerb.move, PaintPathVerb.line, PaintPathVerb.close,
        ])
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
@Suite(.uiContext) struct GraphicsStateTests {
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
        context.fillColor = UIColor(1, 0, 0, 1)
        context.withGraphicsState {
            context.fillColor = UIColor(0, 0, 1, 1)
        }
        #expect(context.fillColor == UIColor(1, 0, 0, 1))
    }
}

/// Stroke style reaching the command.
///
/// `lineCap` and `lineJoin` were public settable state that nothing encoded, so
/// a caller could ask for a rounded stroke and get a butt-capped one with no
/// indication anything had been ignored. The rasterizer's half is covered by
/// pixels in `StrokeCapJoinTests`; this is the producer's half.
@MainActor
@Suite(.uiContext) struct StrokeStyleEncodingTests {
    private func strokedCommand(
        cap: LineCap, join: LineJoin
    ) -> PaintCommand? {
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

/// What the recorder does with the current transform.
@MainActor
@Suite(.uiContext) struct TransformEncodingTests {
    private func imageCommand(
        _ configure: (GraphicsContext) -> Void
    ) -> NucleusTypes.PaintCommand? {
        let graphics = GraphicsContext()
        configure(graphics)
        graphics.draw(ImageHandle(id: 1), in: Rect(x: 0, y: 0, width: 10, height: 20))
        return graphics.recording.commands.first
    }

    /// Translation, scale, rotation, and skew all use one command-local matrix
    /// path. Geometry never changes coordinate systems during recording.
    @Test func translationAndScaleAreCarriedWithLocalGeometry() {
        let translated = imageCommand { $0.translateBy(x: 5, y: 7) }
        #expect(translated?.flags.contains(.hasTransform) == true)
        #expect(translated?.x == 0)
        #expect(translated?.y == 0)
        #expect(translated?.transformTX == 5)
        #expect(translated?.transformTY == 7)

        let scaled = imageCommand { $0.scaleBy(x: 2, y: 3) }
        #expect(scaled?.flags.contains(.hasTransform) == true)
        #expect(scaled?.w == 10)
        #expect(scaled?.h == 20)
        #expect(scaled?.transformA == 2)
        #expect(scaled?.transformD == 3)
    }

    /// Rotation does not. Folding it in leaves an axis-aligned bounding box,
    /// which is the defect: the image drew upright at the wrong size.
    @Test func rotationIsCarriedRatherThanFolded() {
        let command = imageCommand { $0.rotateBy(degrees: 45) }
        #expect(command?.flags.contains(.hasTransform) == true)
        // Geometry stays as authored, in the space the matrix maps from.
        #expect(command?.x == 0)
        #expect(command?.y == 0)
        #expect(command?.w == 10)
        #expect(command?.h == 20)
        // The matrix is a real rotation: the off-diagonal terms are non-zero.
        #expect(abs((command?.transformB ?? 0)) > 0.5)
        #expect(abs((command?.transformC ?? 0)) > 0.5)
    }

    /// The matrix transforms scalar geometry as an outline. The recorder never
    /// approximates anisotropic scale with one determinant-derived factor.
    @Test func transformsDoNotPreScaleScalars() {
        let graphics = GraphicsContext()
        graphics.scaleBy(x: 4, y: 2)
        graphics.draw(
            ImageHandle(id: 1), in: Rect(x: 0, y: 0, width: 10, height: 10),
            cornerRadius: 3)

        let command = graphics.recording.commands.first
        #expect(command?.flags.contains(.hasTransform) == true)
        #expect(command?.radius == 3, "local radius; the matrix carries the scale")
    }

    @Test func identityIsStillAnExplicitTransform() {
        let graphics = GraphicsContext()
        graphics.draw(
            ImageHandle(id: 1), in: Rect(x: 0, y: 0, width: 10, height: 10),
            cornerRadius: 3)

        let command = graphics.recording.commands.first
        #expect(command?.flags.contains(.hasTransform) == true)
        #expect(command?.transformA == 1)
        #expect(command?.transformD == 1)
        #expect(command?.radius == 3)
    }

    @Test func pathsAndTheirGradientsStayLocalUnderRotation() throws {
        let graphics = GraphicsContext()
        graphics.rotateBy(degrees: 45)
        graphics.fill(
            Rect(x: 0, y: 0, width: 10, height: 10),
            with: .linearGradient(
                from: Point(x: 0, y: 0), to: Point(x: 10, y: 0),
                stops: [
                    GradientStop(location: 0, color: UIColor(0, 0, 0, 1)),
                    GradientStop(location: 1, color: UIColor(1, 1, 1, 1)),
                ]))

        let recording = graphics.recording
        let command = try #require(recording.commands.first)
        #expect(command.kind == .path)
        #expect(command.flags.contains(.hasTransform))
        let regions = try #require(PaintPayload.decode(
            recording.payload,
            offset: command.payloadOffset,
            length: command.payloadLength))
        #expect(Array(regions.points.prefix(4)) == [0, 0, 10, 0])
        #expect(Array(regions.scalars.prefix(4)) == [0, 0, 10, 0])
    }
}

@Suite(.uiContext) struct PathStateTests {
    private func expectClose(
        _ point: Point?, _ expected: Point,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            abs((point?.x ?? .infinity) - expected.x) < 1e-9 &&
                abs((point?.y ?? .infinity) - expected.y) < 1e-9,
            sourceLocation: sourceLocation)
    }

    @Test func anArcOpensAtItsRealStartAndEndsAtItsRealEnd() {
        var path = Path()
        path.addArc(
            in: Rect(x: 0, y: 0, width: 20, height: 10),
            start: 0, sweep: 90)

        #expect(path.verbs == [.move, .arc])
        #expect(Array(path.points.prefix(2)) == [20, 5])
        expectClose(path.currentPoint, Point(x: 10, y: 10))
    }

    @Test func anArcConnectsAnExistingContourToItsStart() {
        var path = Path()
        path.move(to: Point(x: 0, y: 0))
        path.addArc(
            in: Rect(x: 0, y: 0, width: 20, height: 10),
            start: 0, sweep: -90)

        #expect(path.verbs == [.move, .line, .arc])
        #expect(Array(path.points[2...3]) == [20, 5])
        expectClose(path.currentPoint, Point(x: 10, y: 0))
    }

    @Test func aFullSweepReturnsToTheAuthoredStartAndCloseUsesIt() throws {
        var path = Path()
        path.addArc(
            in: Rect(x: 10, y: 20, width: 40, height: 20),
            start: 45, sweep: 720)
        let start = try #require(path.currentPoint)
        path.close()

        expectClose(path.currentPoint, start)
        #expect(path.verbs == [.move, .arc, .close])
    }

    @Test func invalidOrEmptyGeometryDoesNotEnterAPath() {
        var path = Path()
        path.move(to: Point(x: .nan, y: 0))
        path.addRect(Rect(x: 0, y: 0, width: -10, height: 10))
        path.addArc(
            in: Rect(x: 0, y: 0, width: 10, height: 10),
            start: 0, sweep: .infinity)
        #expect(path.isEmpty)
        #expect(path.currentPoint == nil)
    }
}

@MainActor
@Suite(.uiContext) struct GraphicsInputValidationTests {
    @Test func aRectangleWithEitherZeroDimensionIsEmptyForUnion() {
        let content = Rect(x: 10, y: 20, width: 30, height: 40)
        #expect(
            Rect(x: -100, y: -100, width: 0, height: 50)
                .union(content) == content)
        #expect(
            Rect(x: -100, y: -100, width: 50, height: 0)
                .union(content) == content)
        #expect(
            Rect(x: 0, y: 0, width: -1, height: 10)
                .union(content) == content)
    }

    @Test func invalidGeometryOrTransformProducesNoCommand() {
        let graphics = GraphicsContext()
        graphics.fill(Rect(x: 0, y: 0, width: .nan, height: 10))
        graphics.concatenate(AffineTransform(tx: .infinity))
        graphics.fill(Rect(x: 0, y: 0, width: 10, height: 10))
        #expect(graphics.recording.commands.isEmpty)
        #expect(graphics.recording.payload.isEmpty)
    }

    @Test func saturationAndGradientStopsAreCanonicalized() throws {
        let imageContext = GraphicsContext()
        imageContext.draw(
            ImageHandle(id: 1),
            in: Rect(x: 0, y: 0, width: 10, height: 10),
            saturation: 4)
        #expect(imageContext.recording.commands.first?.saturation == 1)

        let gradientContext = GraphicsContext()
        gradientContext.fill(
            Rect(x: 0, y: 0, width: 10, height: 10),
            with: .linearGradient(
                from: .zero, to: Point(x: 10, y: 0),
                stops: [
                    GradientStop(location: 1.5, color: UIColor(1, 1, 1, 1)),
                    GradientStop(location: -1, color: UIColor(0, 0, 0, 1)),
                    GradientStop(location: 0, color: UIColor(1, 0, 0, 1)),
                ]))
        let recording = gradientContext.recording
        let command = try #require(recording.commands.first)
        let regions = try #require(PaintPayload.decode(
            recording.payload,
            offset: command.payloadOffset,
            length: command.payloadLength))
        #expect(Array(regions.scalars.dropFirst(4)) == [0, 0, 1])
        #expect(regions.colors[0].r == 0)
        #expect(regions.colors[1].r == 1, "equal stops preserve input order")
    }
}
