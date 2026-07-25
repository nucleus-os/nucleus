import NucleusSkiaGraphiteBridge
import NucleusTextBackend
import NucleusTextRenderingTestSupport
import Testing
@testable import NucleusUI

@MainActor
@Suite(.serialized)
struct TextRenderingBridgeTests {
    private func makeLayout(
        in system: TextSystem,
        text: String = "Borrowed"
    ) throws -> TextLayoutResult {
        system.layout(
            AttributedText(
                text,
                style: TextStyle(
                    font: .systemFont(ofSize: 24),
                    color: Color(1, 1, 1, 1))
            ),
            containerWidth: 180,
            paragraphStyle: ParagraphStyle(
                lineBreakMode: .byClipping,
                maximumLineCount: 1)
        )
    }

    @Test
    func installationIsRequiredIdempotentAndRejectsConflict()
        throws
    {
        let first = TextSystem()
        let second = TextSystem()
        #expect(SkiaTextLayoutBackend.install(in: first))
        #expect(SkiaTextLayoutBackend.install(in: second))
        #expect(first.hasInstalledBackend)
        #expect(second.hasInstalledBackend)
        #expect(nucleus.skia.hasTextLayoutBorrow())
        #expect(
            nucleus.text.testing
                .missingProviderIsRejected())
        #expect(
            nucleus.text.testing
                .conflictingProviderIsRejected())
    }

    @Test
    func borrowOwnsParagraphUntilSynchronousBodyReturns()
        throws
    {
        let system = TextSystem()
        try #require(
            SkiaTextLayoutBackend.install(in: system))
        var layout: TextLayoutResult? =
            try makeLayout(in: system)
        let handle = try #require(
            layout?.storage?.handle.rawValue)

        let probe =
            nucleus.text.testing.TextLayoutBorrowProbe(
                handle)
        #expect(probe.waitUntilBodyEntered())

        layout = nil
        #expect(
            !nucleus.text.testing.borrowInvokesBody(
                handle))

        probe.allowBodyToReturn()
        #expect(probe.waitUntilBodyCompleted())
        #expect(probe.borrowSucceeded())
        #expect(probe.bodyCompleted())
    }

    @Test
    func unknownAndReleasedHandlesNeverInvokeBorrowBody()
        throws
    {
        let system = TextSystem()
        try #require(
            SkiaTextLayoutBackend.install(in: system))
        #expect(
            !nucleus.text.testing.borrowInvokesBody(0))
        #expect(
            !nucleus.text.testing.borrowInvokesBody(
                UInt64.max))

        var layout: TextLayoutResult? =
            try makeLayout(in: system)
        let handle = try #require(
            layout?.storage?.handle.rawValue)
        #expect(
            nucleus.text.testing.borrowInvokesBody(
                handle))
        layout = nil
        #expect(
            !nucleus.text.testing.borrowInvokesBody(
                handle))
    }

    @Test
    func realParagraphPaintsInsideOwningBorrow()
        throws
    {
        let system = TextSystem()
        try #require(
            SkiaTextLayoutBackend.install(in: system))
        let layout = try makeLayout(
            in: system,
            text: "Nucleus")
        let handle = try #require(
            layout.storage?.handle.rawValue)
        let surface =
            nucleus.skia.makeRasterSurface(200, 64)
        try #require(surface.isValid())
        let canvas = surface.getCanvas()
        var clear = nucleus.skia.Color()
        clear.a = 1
        canvas.clear(clear)
        var destination = nucleus.skia.RectF()
        destination.width = 180
        destination.height = 64
        canvas.drawTextLayout(
            handle,
            destination,
            1)

        var pixels = [UInt8](
            repeating: 0,
            count: 200 * 64 * 4)
        let read = pixels.withUnsafeMutableBufferPointer {
            surface.readPixelsRGBA(
                $0.baseAddress,
                $0.count,
                200 * 4)
        }
        #expect(read)
        #expect(
            pixels.enumerated().contains {
                $0.offset % 4 != 3 && $0.element > 0
            })
    }
}
