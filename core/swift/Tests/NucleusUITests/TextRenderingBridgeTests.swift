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

        let barrier =
            unsafe nucleus.text.testing.TextLayoutBorrowBarrier(
                handle)
        let bodyEntered = unsafe barrier.waitUntilBodyEntered()
        #expect(bodyEntered)

        layout = nil
        #expect(
            !nucleus.text.testing.borrowInvokesBody(
                handle))

        unsafe barrier.allowBodyToReturn()
        let bodyReturned = unsafe barrier.waitUntilBodyCompleted()
        let borrowSucceeded = unsafe barrier.borrowSucceeded()
        let bodyCompleted = unsafe barrier.bodyCompleted()
        #expect(bodyReturned)
        #expect(borrowSucceeded)
        #expect(bodyCompleted)
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
            unsafe nucleus.skia.makeRasterSurface(200, 64)
        let surfaceIsValid = unsafe surface.isValid()
        try #require(surfaceIsValid)
        let canvas = unsafe surface.getCanvas()
        var clear = nucleus.skia.Color()
        clear.a = 1
        unsafe canvas.clear(clear)
        var destination = nucleus.skia.RectF()
        destination.width = 180
        destination.height = 64
        unsafe canvas.drawTextLayout(
            handle,
            destination,
            1)

        var pixels = [UInt8](
            repeating: 0,
            count: 200 * 64 * 4)
        let read = pixels.withUnsafeMutableBufferPointer {
            unsafe surface.readPixelsRGBA(
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
