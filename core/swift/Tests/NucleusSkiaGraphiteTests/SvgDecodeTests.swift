import Foundation
import Testing
import NucleusSkiaGraphiteBridge

/// SVG rasterization, through the same entry point as every other image file.
///
/// SVG fixtures are written inline: unlike a PNG, the document *is* readable, so
/// a test says exactly what it draws.
@Suite struct SvgDecodeTests {
    private final class Fixture {
        let path: String

        init(_ svg: String, extension ext: String = "svg") {
            path = "\(NSTemporaryDirectory())nucleus-svg-"
                + "\(UInt32.random(in: 0...UInt32.max)).\(ext)"
            try? svg.write(toFile: path, atomically: true, encoding: .utf8)
        }

        deinit { try? FileManager.default.removeItem(atPath: path) }
    }

    /// A red square filling its viewport, sized in absolute units.
    private static let redSquare = """
        <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
          <rect width="100" height="100" fill="#FF0000"/>
        </svg>
        """

    /// Twice as wide as it is tall, for aspect-ratio checks.
    private static let wideRectangle = """
        <svg xmlns="http://www.w3.org/2000/svg" width="200" height="100">
          <rect width="200" height="100" fill="#00FF00"/>
        </svg>
        """

    private func decode(_ fixture: Fixture, _ maxWidth: Int32, _ maxHeight: Int32)
        -> nucleus.skia.RasterImage
    {
        nucleus.skia.makeEncodedImageFromFile(fixture.path, maxWidth, maxHeight)
    }

    /// Read the whole image and return one pixel. Reading must be whole-image —
    /// `readPixelsRGBA` rejects a buffer too small for the full surface, and a
    /// rejected read leaves zeroes that look exactly like a transparent pixel.
    private func pixel(_ image: nucleus.skia.RasterImage, x: Int, y: Int)
        -> (UInt8, UInt8, UInt8, UInt8)
    {
        let width = Int(image.width())
        var px = [UInt8](repeating: 0, count: width * Int(image.height()) * 4)
        let ok = px.withUnsafeMutableBufferPointer {
            image.readPixelsRGBA($0.baseAddress, $0.count, Int32(width * 4))
        }
        #expect(ok, "readback failed")
        let i = (y * width + x) * 4
        return (px[i], px[i + 1], px[i + 2], px[i + 3])
    }

    // MARK: - Rasterization

    /// The point of the whole path: a vector rasterizes *at* the requested size
    /// rather than being decoded and rescaled.
    @Test func anSvgRasterizesAtTheRequestedSize() {
        let fixture = Fixture(Self.redSquare)
        let image = decode(fixture, 32, 32)
        #expect(image.isValid())
        #expect(image.width() == 32)
        #expect(image.height() == 32)
    }

    /// The same document at a different size is a genuinely different raster, not
    /// a rescale — which is why decode bounds are part of a handle's identity.
    @Test func theSameDocumentRastersAtAnySizeExactly() {
        let fixture = Fixture(Self.redSquare)
        for size in [Int32(16), 64, 256] {
            let image = decode(fixture, size, size)
            #expect(image.width() == size)
            #expect(image.height() == size)
        }
    }

    @Test func anSvgActuallyDrawsItsContent() {
        let fixture = Fixture(Self.redSquare)
        let (r, g, b, a) = pixel(decode(fixture, 8, 8), x: 4, y: 4)
        #expect(r > 200)
        #expect(g < 50)
        #expect(b < 50)
        #expect(a == 255)
    }

    /// An icon is a shape over whatever is behind it, so the untouched area must
    /// be transparent rather than opaque black.
    @Test func theUncoveredAreaIsTransparent() {
        let fixture = Fixture("""
            <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
              <rect x="50" y="50" width="50" height="50" fill="#0000FF"/>
            </svg>
            """)
        let image = decode(fixture, 10, 10)
        #expect(pixel(image, x: 0, y: 0).3 == 0, "top-left is outside the drawn rect")
        #expect(pixel(image, x: 8, y: 8).3 > 0, "and the drawn rect really is drawn")
    }

    // MARK: - Sizing

    /// Bounds are a box, as they are for bitmaps — the document's own aspect
    /// ratio is preserved inside it.
    @Test func aspectRatioIsPreservedInsideTheBounds() {
        let fixture = Fixture(Self.wideRectangle)
        let image = decode(fixture, 100, 100)
        #expect(image.width() == 100)
        #expect(image.height() == 50)
    }

    /// Unbounded means the document's own size, when it states one.
    @Test func anUnboundedSvgUsesItsIntrinsicSize() {
        let fixture = Fixture(Self.wideRectangle)
        let image = decode(fixture, 0, 0)
        #expect(image.width() == 200)
        #expect(image.height() == 100)
    }

    /// A document sized in relative units has no intrinsic size, so bounds are
    /// all the information there is.
    @Test func aRelativelySizedDocumentTakesTheBounds() {
        let fixture = Fixture("""
            <svg xmlns="http://www.w3.org/2000/svg" width="100%" height="100%" viewBox="0 0 10 10">
              <rect width="10" height="10" fill="#FF0000"/>
            </svg>
            """)
        let image = decode(fixture, 40, 24)
        #expect(image.width() == 40)
        #expect(image.height() == 24)
    }

    /// Neither a stated size nor bounds: something has to be picked, and a
    /// vector at least rasterizes cleanly at whatever is chosen.
    @Test func aSizelessUnboundedDocumentGetsADefaultSize() {
        let fixture = Fixture("""
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
              <rect width="10" height="10" fill="#FF0000"/>
            </svg>
            """)
        let image = decode(fixture, 0, 0)
        #expect(image.isValid())
        #expect(image.width() == 512)
    }

    // MARK: - Detection

    /// Extensions lie. Icon themes ship `.png` files that are really SVG, and a
    /// name-based decision renders them as nothing.
    @Test func svgIsDetectedByContentNotExtension() {
        let fixture = Fixture(Self.redSquare, extension: "png")
        let image = decode(fixture, 20, 20)
        #expect(image.isValid())
        #expect(image.width() == 20, "rasterized as SVG despite the .png name")
    }

    /// An XML declaration, doctype, or comment before the root element is
    /// ordinary, so detection searches rather than testing the prefix.
    @Test func aLeadingDeclarationDoesNotHideTheRoot() {
        let fixture = Fixture("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!-- exported by a drawing program -->
            <svg xmlns="http://www.w3.org/2000/svg" width="50" height="50">
              <rect width="50" height="50" fill="#FF0000"/>
            </svg>
            """)
        let image = decode(fixture, 25, 25)
        #expect(image.isValid())
        #expect(image.width() == 25)
    }

    // MARK: - Failure

    @Test func amalformedDocumentRastersNothing() {
        let fixture = Fixture("<svg is not really xml at all")
        #expect(!decode(fixture, 16, 16).isValid())
    }

    /// A file that merely mentions svg in its text is not an SVG, and must not
    /// be diverted away from the codec path.
    @Test func aPlainTextFileIsNotAnSvg() {
        let fixture = Fixture("this file talks about <svgx> but is not one", extension: "txt")
        #expect(!decode(fixture, 16, 16).isValid())
    }
}
