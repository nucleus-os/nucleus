import Foundation
import Testing
import NucleusSkiaGraphiteBridge

/// Bounded decode of encoded image files.
///
/// Tests encode their own PNGs rather than shipping fixtures: the interesting
/// inputs are pixel patterns chosen to make a resampling defect visible, and a
/// checked-in binary would hide what it contains.
@Suite struct EncodedImageDecodeTests {
    // MARK: - A minimal PNG encoder

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }

    private static func beBytes(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF),
         UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    private static func chunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        let tagged = Array(type.utf8) + payload
        return beBytes(UInt32(payload.count)) + tagged + beBytes(crc32(tagged))
    }

    /// Encode RGBA8888 pixels as a PNG. The zlib stream uses stored (uncompressed)
    /// deflate blocks — valid, trivially correct, and size is irrelevant here.
    private static func encodePNG(width: Int, height: Int, rgba: [UInt8]) -> Data {
        var raw: [UInt8] = []
        raw.reserveCapacity(height * (1 + width * 4))
        for row in 0..<height {
            raw.append(0)  // filter: none
            raw.append(contentsOf: rgba[(row * width * 4)..<((row + 1) * width * 4)])
        }

        var zlib: [UInt8] = [0x78, 0x01]
        var offset = 0
        repeat {
            let count = min(65535, raw.count - offset)
            let isFinal = offset + count >= raw.count
            zlib.append(isFinal ? 1 : 0)
            zlib.append(contentsOf: [UInt8(count & 0xFF), UInt8(count >> 8 & 0xFF)])
            let inverted = ~UInt16(count)
            zlib.append(contentsOf: [UInt8(inverted & 0xFF), UInt8(inverted >> 8 & 0xFF)])
            zlib.append(contentsOf: raw[offset..<(offset + count)])
            offset += count
        } while offset < raw.count
        zlib.append(contentsOf: beBytes(adler32(raw)))

        let header = beBytes(UInt32(width)) + beBytes(UInt32(height))
            + [8, 6, 0, 0, 0]  // 8-bit, RGBA, deflate, no filter, no interlace
        var png: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        png += chunk("IHDR", header)
        png += chunk("IDAT", zlib)
        png += chunk("IEND", [])
        return Data(png)
    }

    /// A PNG on disk, removed with the test.
    private final class Fixture {
        let path: String

        init(width: Int, height: Int, rgba: [UInt8]) {
            path = "\(NSTemporaryDirectory())nucleus-decode-"
                + "\(UInt32.random(in: 0...UInt32.max)).png"
            try? encodePNG(width: width, height: height, rgba: rgba).write(
                to: URL(fileURLWithPath: path))
        }

        deinit { try? FileManager.default.removeItem(atPath: path) }
    }

    private static func solid(width: Int, height: Int,
                             _ r: UInt8, _ g: UInt8, _ b: UInt8) -> [UInt8] {
        var pixels: [UInt8] = []
        pixels.reserveCapacity(width * height * 4)
        for _ in 0..<(width * height) { pixels.append(contentsOf: [r, g, b, 255]) }
        return pixels
    }

    private func decode(_ fixture: Fixture, maxWidth: Int32, maxHeight: Int32)
        -> nucleus.skia.RasterImage
    {
        nucleus.skia.makeEncodedImageFromFile(fixture.path, maxWidth, maxHeight)
    }

    // MARK: - The encoder is trustworthy

    /// The tests below only mean something if Skia agrees the PNGs are valid.
    @Test func theTestEncoderProducesADecodablePNG() {
        let fixture = Fixture(width: 4, height: 3,
                              rgba: Self.solid(width: 4, height: 3, 10, 200, 30))
        let image = decode(fixture, maxWidth: 0, maxHeight: 0)
        #expect(image.isValid())
        #expect(image.width() == 4)
        #expect(image.height() == 3)
    }

    // MARK: - Bounds

    /// The defect under test: bounds were stored, deduped on, and ignored,
    /// so a wallpaper and a tray icon decoded identically.
    @Test func aBoundedDecodeShrinksTheImage() {
        let fixture = Fixture(width: 256, height: 256,
                              rgba: Self.solid(width: 256, height: 256, 128, 128, 128))
        let image = decode(fixture, maxWidth: 32, maxHeight: 32)
        #expect(image.isValid())
        #expect(image.width() == 32)
        #expect(image.height() == 32)
    }

    /// The bound is a box the result fits inside, not the result's size.
    @Test func aBoundedDecodePreservesAspectRatio() {
        let fixture = Fixture(width: 400, height: 100,
                              rgba: Self.solid(width: 400, height: 100, 200, 50, 50))
        let image = decode(fixture, maxWidth: 100, maxHeight: 100)
        #expect(image.width() == 100)
        #expect(image.height() == 25, "the wide axis binds; the short axis follows it")
    }

    /// Upscaling to fill the box would burn memory to blur.
    @Test func anImageInsideTheBoxIsNotEnlarged() {
        let fixture = Fixture(width: 16, height: 16,
                              rgba: Self.solid(width: 16, height: 16, 0, 0, 255))
        let image = decode(fixture, maxWidth: 512, maxHeight: 512)
        #expect(image.width() == 16)
        #expect(image.height() == 16)
    }

    /// A zero bound means unbounded on that axis.
    @Test func anUnboundedDecodeIsFullSize() {
        let fixture = Fixture(width: 64, height: 48,
                              rgba: Self.solid(width: 64, height: 48, 1, 2, 3))
        let image = decode(fixture, maxWidth: 0, maxHeight: 0)
        #expect(image.width() == 64)
        #expect(image.height() == 48)
    }

    // MARK: - Colour

    /// Downscaling must average in linear space. Image bytes are sRGB-encoded, so
    /// averaging them directly darkens the result — a black/white checkerboard
    /// collapses to 128 instead of the correct ~188, and every small icon comes
    /// out muddy. This is the one assertion that would catch a regression to a
    /// naive resample.
    @Test func downscalingAveragesInLinearSpace() {
        let side = 64
        var checkerboard: [UInt8] = []
        for y in 0..<side {
            for x in 0..<side {
                let value: UInt8 = (x + y) % 2 == 0 ? 255 : 0
                checkerboard.append(contentsOf: [value, value, value, 255])
            }
        }
        let fixture = Fixture(width: side, height: side, rgba: checkerboard)
        let image = decode(fixture, maxWidth: 1, maxHeight: 1)
        #expect(image.isValid())
        #expect(image.width() == 1)

        var pixel = [UInt8](repeating: 0, count: 4)
        let read = pixel.withUnsafeMutableBufferPointer {
            image.readPixelsRGBA($0.baseAddress, $0.count, 4)
        }
        #expect(read)
        // Linear-correct: ~188. Naive sRGB averaging: ~128. The gap is wide
        // enough that filter choice cannot account for it.
        #expect(pixel[0] > 170, "got \(pixel[0]); a value near 128 means a naive average")
    }

    @Test func aBoundedDecodePreservesColour() {
        let fixture = Fixture(width: 64, height: 64,
                              rgba: Self.solid(width: 64, height: 64, 220, 40, 90))
        let image = decode(fixture, maxWidth: 8, maxHeight: 8)
        var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
        let read = pixels.withUnsafeMutableBufferPointer {
            image.readPixelsRGBA($0.baseAddress, $0.count, 8 * 4)
        }
        #expect(read)
        // A solid colour survives any correct resample exactly.
        #expect(abs(Int(pixels[0]) - 220) <= 1)
        #expect(abs(Int(pixels[1]) - 40) <= 1)
        #expect(abs(Int(pixels[2]) - 90) <= 1)
        #expect(pixels[3] == 255)
    }

    /// Transparency must survive the linear round trip — tray icons are mostly
    /// transparent, and premultiplication is where this goes wrong.
    @Test func aBoundedDecodePreservesAlpha() {
        var pixels: [UInt8] = []
        for _ in 0..<(32 * 32) { pixels.append(contentsOf: [255, 0, 0, 0]) }
        let fixture = Fixture(width: 32, height: 32, rgba: pixels)
        let image = decode(fixture, maxWidth: 4, maxHeight: 4)

        var out = [UInt8](repeating: 255, count: 4 * 4 * 4)
        let read = out.withUnsafeMutableBufferPointer {
            image.readPixelsRGBA($0.baseAddress, $0.count, 4 * 4)
        }
        #expect(read)
        #expect(out[3] == 0, "fully transparent in must stay fully transparent out")
    }

    // MARK: - In-memory bytes

    /// A `data:` URI holds exactly what a file holds, so it must decode exactly
    /// the same way — same formats, same bounds, same everything.
    @Test func encodedBytesDecodeLikeAFile() {
        let png = Self.encodePNG(
            width: 8, height: 8, rgba: Self.solid(width: 8, height: 8, 30, 60, 90))
        let bytes = [UInt8](png)
        let image = bytes.withUnsafeBufferPointer {
            nucleus.skia.makeEncodedImageFromMemory($0.baseAddress, $0.count, 0, 0)
        }
        #expect(image.isValid())
        #expect(image.width() == 8)
        #expect(image.height() == 8)
    }

    @Test func encodedBytesHonourBounds() {
        let png = Self.encodePNG(
            width: 64, height: 64, rgba: Self.solid(width: 64, height: 64, 1, 2, 3))
        let bytes = [UInt8](png)
        let image = bytes.withUnsafeBufferPointer {
            nucleus.skia.makeEncodedImageFromMemory($0.baseAddress, $0.count, 16, 16)
        }
        #expect(image.width() == 16)
    }

    @Test func emptyBytesDecodeToNothing() {
        let empty: [UInt8] = []
        let image = empty.withUnsafeBufferPointer {
            nucleus.skia.makeEncodedImageFromMemory($0.baseAddress, $0.count, 0, 0)
        }
        #expect(!image.isValid())
    }

    // MARK: - ICO

    /// Tray icons are ICO, and they are mostly transparent.
    ///
    /// The reference hand-rolls an ICO decoder because Skia's BMP codec forces
    /// alpha to 0xFF on 32bpp images. That is *not* true of Skia's ICO path here,
    /// which is why no hand-rolled decoder exists in this tree — so this test
    /// exists to notice if that ever stops being true.
    @Test func icoPreservesPerPixelAlpha() {
        let fixture = IcoFixture(alphas: [0, 64, 255, 128])
        let image = nucleus.skia.makeEncodedImageFromFile(fixture.path, 0, 0)
        #expect(image.isValid())
        #expect(image.width() == 2)

        var px = [UInt8](repeating: 0, count: 2 * 2 * 4)
        let read = px.withUnsafeMutableBufferPointer {
            image.readPixelsRGBA($0.baseAddress, $0.count, 2 * 4)
        }
        #expect(read)
        #expect([px[3], px[7], px[11], px[15]] == [0, 64, 255, 128],
                "every alpha survives; all-255 would mean the BMP path flattened them")
    }

    /// A 2x2 32bpp ICO with per-pixel alpha, written by hand — the format is
    /// simple enough to state outright, and a checked-in binary would hide the
    /// one property under test.
    private final class IcoFixture {
        let path: String

        /// - Parameter alphas: top-left, top-right, bottom-left, bottom-right.
        init(alphas: [UInt8]) {
            path = "\(NSTemporaryDirectory())nucleus-ico-"
                + "\(UInt32.random(in: 0...UInt32.max)).ico"

            var dib = Data()
            func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { dib.append(contentsOf: $0) } }
            func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { dib.append(contentsOf: $0) } }
            func i32(_ v: Int32) { withUnsafeBytes(of: v.littleEndian) { dib.append(contentsOf: $0) } }

            // BITMAPINFOHEADER: height is doubled to cover the (unused) AND mask.
            u32(40); i32(2); i32(4); u16(1); u16(32)
            u32(0); u32(16); i32(0); i32(0); u32(0); u32(0)

            // BGRA pixels, bottom-up: the last row is written first.
            let rows: [[UInt8]] = [[alphas[2], alphas[3]], [alphas[0], alphas[1]]]
            for row in rows {
                for alpha in row {
                    dib.append(contentsOf: [255, 255, 255, alpha])
                }
            }
            dib.append(contentsOf: [0, 0, 0, 0])  // AND mask

            var ico = Data()
            func h16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { ico.append(contentsOf: $0) } }
            func h32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { ico.append(contentsOf: $0) } }
            h16(0); h16(1); h16(1)                      // reserved, type=icon, count
            ico.append(contentsOf: [2, 2, 0, 0])        // width, height, palette, reserved
            h16(1); h16(32)                             // planes, bit depth
            h32(UInt32(dib.count)); h32(22)             // size, offset
            ico.append(dib)

            try? ico.write(to: URL(fileURLWithPath: path))
        }

        deinit { try? FileManager.default.removeItem(atPath: path) }
    }

    // MARK: - Failure

    @Test func aMissingFileDecodesToNothing() {
        let image = nucleus.skia.makeEncodedImageFromFile(
            "\(NSTemporaryDirectory())nucleus-absent-\(UInt32.random(in: 0...UInt32.max)).png",
            32, 32)
        #expect(!image.isValid())
    }

    @Test func anEmptyPathDecodesToNothing() {
        #expect(!nucleus.skia.makeEncodedImageFromFile("", 32, 32).isValid())
    }

    /// Bounded and unbounded take different code paths, so garbage must be
    /// rejected on both.
    @Test func anUndecodableFileDecodesToNothing() {
        let path = "\(NSTemporaryDirectory())nucleus-garbage-"
            + "\(UInt32.random(in: 0...UInt32.max)).png"
        try? Data([0xDE, 0xAD, 0xBE, 0xEF]).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(!nucleus.skia.makeEncodedImageFromFile(path, 16, 16).isValid())
        #expect(!nucleus.skia.makeEncodedImageFromFile(path, 0, 0).isValid())
    }
}
