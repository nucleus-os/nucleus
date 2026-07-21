import Foundation
import Testing
import NucleusAppHostProtocols
@testable import NucleusRenderModel

/// Raw pixel buffers, as notifications deliver them over D-Bus: an arbitrary
/// channel order, a possibly-padded stride, and straight (unpremultiplied) alpha.
@Suite struct RawPixelBufferTests {
    /// One opaque pixel in each order, all naming the same colour.
    private func single(_ order: PixelChannelOrder, _ bytes: [UInt8]) -> RawPixelBuffer {
        RawPixelBuffer(width: 1, height: 1, order: order, pixels: bytes)
    }

    // MARK: - Channel order

    @Test func everyOrderNormalizesToRGBA() {
        let expected: [UInt8] = [10, 20, 30, 255]
        #expect(single(.rgba, [10, 20, 30, 255]).normalizedRGBA() == expected)
        #expect(single(.bgra, [30, 20, 10, 255]).normalizedRGBA() == expected)
        #expect(single(.argb, [255, 10, 20, 30]).normalizedRGBA() == expected)
        #expect(single(.rgb, [10, 20, 30]).normalizedRGBA() == expected)
        #expect(single(.bgr, [30, 20, 10]).normalizedRGBA() == expected)
    }

    /// A three-channel order has no alpha to carry, so it is opaque.
    @Test func anOrderWithoutAlphaIsOpaque() {
        #expect(!PixelChannelOrder.rgb.hasAlpha)
        #expect(single(.rgb, [1, 2, 3]).normalizedRGBA()?[3] == 255)
    }

    @Test func bytesPerPixelFollowsTheOrder() {
        #expect(PixelChannelOrder.rgba.sourceBytesPerPixel == 4)
        #expect(PixelChannelOrder.bgr.sourceBytesPerPixel == 3)
    }

    // MARK: - Stride

    /// Senders pad rows. Assuming `width * bytesPerPixel` skews every row after
    /// the first, which shows up as a diagonal smear rather than a clean failure.
    @Test func paddingBetweenRowsIsSkipped() {
        // 2x2 RGB with 2 bytes of padding per row.
        let pixels: [UInt8] = [
            1, 1, 1, 2, 2, 2, 0, 0,
            3, 3, 3, 4, 4, 4, 0, 0,
        ]
        let buffer = RawPixelBuffer(
            width: 2, height: 2, rowStride: 8, order: .rgb, pixels: pixels)
        let out = buffer.normalizedRGBA()
        #expect(out?.count == 16)
        #expect(out?[0] == 1)
        #expect(out?[4] == 2)
        #expect(out?[8] == 3, "the second row must start after the padding")
        #expect(out?[12] == 4)
    }

    /// The final row needs only its pixels, not its padding — senders routinely
    /// omit the trailing bytes, and rejecting those rejects valid buffers.
    @Test func aMissingFinalPaddingIsStillWellFormed() {
        let buffer = RawPixelBuffer(
            width: 2, height: 2, rowStride: 8, order: .rgb,
            pixels: [UInt8](repeating: 7, count: 8 + 6))
        #expect(buffer.isWellFormed)
        #expect(buffer.normalizedRGBA() != nil)
    }

    // MARK: - Premultiplication

    /// The notification spec sends straight alpha; the GPU wants premultiplied.
    @Test func straightAlphaIsPremultiplied() {
        let buffer = single(.rgba, [255, 255, 255, 128])
        let out = buffer.normalizedRGBA()
        #expect(out?[0] == 128, "white at half alpha premultiplies to half")
        #expect(out?[3] == 128, "alpha itself is unchanged")
    }

    @Test func alreadyPremultipliedPixelsAreLeftAlone() {
        let buffer = RawPixelBuffer(
            width: 1, height: 1, order: .rgba, isPremultiplied: true,
            pixels: [64, 64, 64, 128])
        #expect(buffer.normalizedRGBA()?[0] == 64)
    }

    /// Truncating instead of rounding loses half a level on every channel of
    /// every pixel, which reads as a uniform darkening.
    @Test func premultiplicationRounds() {
        #expect(RawPixelBuffer.premultiply(255, 255) == 255)
        #expect(RawPixelBuffer.premultiply(255, 0) == 0)
        #expect(RawPixelBuffer.premultiply(128, 128) == 64, "truncation would give 63")
    }

    @Test func fullyTransparentPixelsPremultiplyToNothing() {
        #expect(single(.rgba, [200, 100, 50, 0]).normalizedRGBA() == [0, 0, 0, 0])
    }

    // MARK: - Validation

    @Test func aBufferShorterThanItsGeometryIsRejected() {
        let buffer = RawPixelBuffer(width: 4, height: 4, order: .rgba, pixels: [1, 2, 3, 4])
        #expect(!buffer.isWellFormed)
        #expect(buffer.normalizedRGBA() == nil)
    }

    @Test func aStrideNarrowerThanTheRowIsRejected() {
        let buffer = RawPixelBuffer(
            width: 4, height: 2, rowStride: 8, order: .rgba,
            pixels: [UInt8](repeating: 0, count: 64))
        #expect(!buffer.isWellFormed, "4 RGBA pixels need 16 bytes, not 8")
    }

    @Test func emptyGeometryIsRejected() {
        #expect(!RawPixelBuffer(width: 0, height: 4, order: .rgba, pixels: []).isWellFormed)
        #expect(!RawPixelBuffer(width: 4, height: 0, order: .rgba, pixels: []).isWellFormed)
    }

    @Test func adversarialGeometryNeverOverflowsValidationOrHashing() {
        let cases = [
            RawPixelBuffer(
                width: .max, height: .max, order: .rgba, pixels: []),
            RawPixelBuffer(
                width: .max, height: 2, rowStride: .max,
                order: .rgb, pixels: []),
            RawPixelBuffer(
                width: -1, height: -1, rowStride: .min,
                order: .argb, pixels: []),
        ]
        for buffer in cases {
            #expect(!buffer.isWellFormed)
            #expect(buffer.normalizedRGBA() == nil)
            _ = buffer.contentHash()
        }
    }

    @Test func boundedRandomLayoutsNormalizeExactlyWhenWellFormed() {
        var random = RawPixelRandom(seed: propertySeed())
        let orders: [PixelChannelOrder] = [.rgba, .bgra, .argb, .rgb, .bgr]
        for _ in 0..<1_024 {
            let width = 1 + random.index(32)
            let height = 1 + random.index(32)
            let order = orders[random.index(orders.count)]
            let minimumStride = width * order.sourceBytesPerPixel
            let rowStride = minimumStride + random.index(17)
            let exactCount = (height - 1) * rowStride + minimumStride
            let truncate = random.index(5) == 0
            let byteCount = truncate && exactCount > 0
                ? exactCount - 1
                : exactCount
            let pixels = (0..<byteCount).map { _ in random.byte() }
            let buffer = RawPixelBuffer(
                width: width,
                height: height,
                rowStride: rowStride,
                order: order,
                isPremultiplied: random.index(2) == 0,
                pixels: pixels)
            #expect(buffer.isWellFormed == !truncate)
            let normalized = buffer.normalizedRGBA()
            #expect((normalized != nil) == !truncate)
            if let normalized {
                #expect(normalized.count == width * height * 4)
            }
        }
    }

    // MARK: - Identity

    /// Raw buffers have no path to key on, and a notification re-sending an
    /// unchanged icon on every update must not register a fresh decode each time.
    @Test func identicalBuffersHashAlike() {
        let a = single(.rgba, [1, 2, 3, 4])
        let b = single(.rgba, [1, 2, 3, 4])
        #expect(a.contentHash() == b.contentHash())
    }

    @Test func differingPixelsHashApart() {
        #expect(single(.rgba, [1, 2, 3, 4]).contentHash()
                != single(.rgba, [1, 2, 3, 5]).contentHash())
    }

    /// The same bytes read as a different layout are a different image.
    @Test func theLayoutIsPartOfTheIdentity() {
        #expect(single(.rgba, [1, 2, 3, 4]).contentHash()
                != single(.bgra, [1, 2, 3, 4]).contentHash())
    }
}

private func propertySeed() -> UInt64 {
    guard let value = ProcessInfo.processInfo.environment["NUCLEUS_TEST_SEED"]
    else { return 0x5241_5750_4958_454c }
    let digits = value.hasPrefix("0x") ? String(value.dropFirst(2)) : value
    return UInt64(digits, radix: 16) ?? 0x5241_5750_4958_454c
}

private struct RawPixelRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func index(_ upperBound: Int) -> Int {
        precondition(upperBound > 0)
        state = state &* 6_364_136_223_846_793_005
            &+ 1_442_695_040_888_963_407
        return Int(state % UInt64(upperBound))
    }

    mutating func byte() -> UInt8 {
        UInt8(truncatingIfNeeded: index(256))
    }
}

/// How a registered source decides it is the same source as another.
@Suite struct ImageSourceIdentityTests {
    @Test func theSameFileAtTheSameBoundsIsOneRegistration() {
        let a = ImageSource(path: "/a.png", maxWidth: 22, maxHeight: 22)
        let b = ImageSource(path: "/a.png", maxWidth: 22, maxHeight: 22)
        #expect(a.dedupeKey == b.dedupeKey)
    }

    /// Bounds are part of what gets decoded, so they are part of the identity.
    @Test func theSameFileAtDifferentBoundsIsNot() {
        let a = ImageSource(path: "/a.png", maxWidth: 22, maxHeight: 22)
        let b = ImageSource(path: "/a.png", maxWidth: 48, maxHeight: 48)
        #expect(a.dedupeKey != b.dedupeKey)
    }

    @Test func identicalEncodedBytesAreOneRegistration() {
        let a = ImageSource(content: .encoded(bytes: [1, 2, 3]))
        let b = ImageSource(content: .encoded(bytes: [1, 2, 3]))
        #expect(a.dedupeKey == b.dedupeKey)
        #expect(a.dedupeKey != ImageSource(content: .encoded(bytes: [1, 2, 4])).dedupeKey)
    }

    /// A path and a blob that happen to stringify alike must not collide.
    @Test func contentKindsDoNotCollide() {
        let file = ImageSource(path: "x", maxWidth: 0, maxHeight: 0)
        let encoded = ImageSource(content: .encoded(bytes: Array("x".utf8)))
        #expect(file.dedupeKey != encoded.dedupeKey)
    }

    @Test func onlyAFileSourceHasAPath() {
        #expect(ImageSource(path: "/a.png", maxWidth: 0, maxHeight: 0).path == "/a.png")
        #expect(ImageSource(content: .encoded(bytes: [1])).path == nil)
    }
}
