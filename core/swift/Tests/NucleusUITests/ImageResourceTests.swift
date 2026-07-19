import Testing
import NucleusAppHostProtocols
import NucleusLayers
@testable import NucleusUI

/// The producer seam: naming an image file from the view tier, and owning the
/// registration that results.
@MainActor
@Suite struct ImageResourceTests {
    // MARK: - Recording host

    /// Records what was registered, so the lifetime contract is observable
    /// rather than merely plausible.
    final class RecordingRegistrar: ImageRegistrar {
        struct Registration: Equatable {
            var path: String
            var maxWidth: UInt32
            var maxHeight: UInt32
        }

        var registrations: [Registration] = []
        var failsWith: ImageRegistrationError?
        var returnsZero = false
        private var next: UInt64 = 1

        /// Encoded and raw registrations, recorded as byte counts and geometry —
        /// enough to tell them apart without restating the pixels.
        var encodedByteCounts: [Int] = []
        var rawGeometry: [(width: UInt32, height: UInt32, stride: UInt32, order: UInt8)] = []

        func register(path: String, maxWidth: UInt32, maxHeight: UInt32)
            throws(ImageRegistrationError) -> UInt64
        {
            if let failsWith { throw failsWith }
            registrations.append(
                Registration(path: path, maxWidth: maxWidth, maxHeight: maxHeight))
            if returnsZero { return 0 }
            defer { next += 1 }
            return next
        }

        func register(encoded: Span<UInt8>, maxWidth: UInt32, maxHeight: UInt32)
            throws(ImageRegistrationError) -> UInt64
        {
            if let failsWith { throw failsWith }
            encodedByteCounts.append(encoded.count)
            if returnsZero { return 0 }
            defer { next += 1 }
            return next
        }

        func register(
            pixels: Span<UInt8>, width: UInt32, height: UInt32, rowStride: UInt32,
            channelOrder: UInt8, isPremultiplied: Bool
        ) throws(ImageRegistrationError) -> UInt64 {
            if let failsWith { throw failsWith }
            rawGeometry.append((width, height, rowStride, channelOrder))
            if returnsZero { return 0 }
            defer { next += 1 }
            return next
        }
    }

    final class RecordingLifecycle: ImageLifecycle, @unchecked Sendable {
        nonisolated(unsafe) static var released: [UInt64] = []
        func retain(resourceHostHandle: UInt64, handle: UInt64) {}
        func release(resourceHostHandle: UInt64, handle: UInt64) {
            RecordingLifecycle.released.append(handle)
        }
    }

    /// Install a host whose image slots record, leaving the rest stubbed.
    private func withRecordingHost(
        _ body: (RecordingRegistrar) throws -> Void
    ) rethrows {
        let registrar = RecordingRegistrar()
        RecordingLifecycle.released = []
        installStubHost()
        guard let stub = currentHost() else { return }
        installHost(Host(
            imageRegistrar: registrar,
            paintContentRegistrar: stub.paintContentRegistrar,
            runtimeEffectRegistrar: stub.runtimeEffectRegistrar,
            iosurfaceBinder: stub.iosurfaceBinder,
            contextIDAllocator: stub.contextIDAllocator,
            displayLinkSource: stub.displayLinkSource,
            implicitActionRegistrar: stub.implicitActionRegistrar))
        guard let lifecycle = currentLifecycleHost() else { return }
        installLifecycleHost(LifecycleHost(
            imageLifecycle: RecordingLifecycle(),
            paintContentLifecycle: lifecycle.paintContentLifecycle,
            runtimeEffectLifecycle: lifecycle.runtimeEffectLifecycle,
            snapshotLifecycle: lifecycle.snapshotLifecycle,
            iosurfaceLifecycle: lifecycle.iosurfaceLifecycle,
            contextIDAllocator: lifecycle.contextIDAllocator))
        try body(registrar)
    }

    // MARK: - Registration

    @Test func registeringYieldsAHandle() {
        withRecordingHost { registrar in
            let resource = ImageResource(
                path: "/icons/firefox.png",
                decodeSize: Size(width: 22, height: 22),
                resourceHostHandle: 7)
            #expect(resource != nil)
            #expect(resource?.handle.id != 0)
            #expect(registrar.registrations == [
                .init(path: "/icons/firefox.png", maxWidth: 22, maxHeight: 22)
            ])
        }
    }

    /// The bounds are the registration's identity, not decoration — the store
    /// dedupes on path *and* bounds.
    @Test func theDecodeSizeIsCarriedThrough() {
        withRecordingHost { registrar in
            _ = ImageResource(
                path: "/w.png", decodeSize: Size(width: 1920, height: 1080),
                resourceHostHandle: 1)
            #expect(registrar.registrations.first?.maxWidth == 1920)
            #expect(registrar.registrations.first?.maxHeight == 1080)
        }
    }

    /// A fractional layout size must round up. Rounding down would decode a pixel
    /// short and upscale to cover the gap.
    @Test func aFractionalSizeRoundsUp() {
        #expect(ImageResource.pixelBound(21.2) == 22)
        #expect(ImageResource.pixelBound(22.0) == 22)
    }

    /// Zero means unbounded, which is how a full-size decode is asked for.
    @Test func aNonPositiveSizeIsUnbounded() {
        #expect(ImageResource.pixelBound(0) == 0)
        #expect(ImageResource.pixelBound(-5) == 0)
        #expect(ImageResource.pixelBound(.infinity) == 0)
        #expect(ImageResource.pixelBound(.nan) == 0)
    }

    // MARK: - Failure

    @Test func anEmptyPathRegistersNothing() {
        withRecordingHost { registrar in
            #expect(ImageResource(path: "", resourceHostHandle: 1) == nil)
            #expect(registrar.registrations.isEmpty)
        }
    }

    /// Without a resource host there is nowhere to register, and that is the
    /// pre-bring-up case rather than a caller error.
    @Test func aZeroResourceHostRegistersNothing() {
        withRecordingHost { registrar in
            #expect(ImageResource(path: "/a.png", resourceHostHandle: 0) == nil)
            #expect(registrar.registrations.isEmpty)
        }
    }

    @Test func aFailedRegistrationYieldsNothing() {
        withRecordingHost { registrar in
            registrar.failsWith = .invalidArgument
            #expect(ImageResource(path: "/a.png", resourceHostHandle: 1) == nil)
        }
    }

    /// A zero handle is the registrar's "no" and must not be mistaken for one.
    @Test func aZeroHandleYieldsNothing() {
        withRecordingHost { registrar in
            registrar.returnsZero = true
            #expect(ImageResource(path: "/a.png", resourceHostHandle: 1) == nil)
        }
    }

    // MARK: - In-memory sources

    @Test func encodedBytesRegister() {
        withRecordingHost { registrar in
            let resource = ImageResource(
                encoded: [1, 2, 3, 4], decodeSize: Size(width: 16, height: 16),
                resourceHostHandle: 1)
            #expect(resource != nil)
            #expect(registrar.encodedByteCounts == [4])
        }
    }

    @Test func emptyEncodedBytesRegisterNothing() {
        withRecordingHost { registrar in
            #expect(ImageResource(encoded: [], resourceHostHandle: 1) == nil)
            #expect(registrar.encodedByteCounts.isEmpty)
        }
    }

    /// The sender's geometry travels intact; a stride guessed from the width
    /// would skew every row after the first.
    @Test func rawPixelsRegisterWithTheirGeometry() {
        withRecordingHost { registrar in
            let resource = ImageResource(
                pixels: [UInt8](repeating: 0, count: 2 * 12), width: 2, height: 2,
                rowStride: 12, order: .bgra, resourceHostHandle: 1)
            #expect(resource != nil)
            #expect(registrar.rawGeometry.count == 1)
            #expect(registrar.rawGeometry.first?.width == 2)
            #expect(registrar.rawGeometry.first?.stride == 12)
            #expect(registrar.rawGeometry.first?.order == PixelChannelOrder.bgra.rawValue)
        }
    }

    /// Omitting the stride means the rows are packed, which is the common case.
    @Test func anOmittedStrideIsDerivedFromTheWidth() {
        withRecordingHost { registrar in
            _ = ImageResource(
                pixels: [UInt8](repeating: 0, count: 16), width: 2, height: 2,
                order: .rgba, resourceHostHandle: 1)
            #expect(registrar.rawGeometry.first?.stride == 8)
        }
    }

    /// Raw pixels are already decoded, so the resource's size is the sender's.
    @Test func rawPixelsCarryTheirOwnSize() {
        withRecordingHost { _ in
            let resource = ImageResource(
                pixels: [UInt8](repeating: 0, count: 16), width: 2, height: 2,
                order: .rgba, resourceHostHandle: 1)
            #expect(resource?.decodeSize == Size(width: 2, height: 2))
        }
    }

    // MARK: - Source strings

    /// Callers get icon strings from applications and cannot know which kind they
    /// hold, so one entry point decides.
    @Test func aSourceStringRoutesByKind() {
        withRecordingHost { registrar in
            _ = ImageResource(source: "/icons/app.png", resourceHostHandle: 1)
            #expect(registrar.registrations.count == 1)
            #expect(registrar.encodedByteCounts.isEmpty)

            _ = ImageResource(source: "data:image/png;base64,SGkh", resourceHostHandle: 1)
            #expect(registrar.registrations.count == 1, "not registered as a path")
            #expect(registrar.encodedByteCounts == [3])
        }
    }

    /// A string that fails to parse as a data URI falls through to the path
    /// branch. It will not resolve to a file, which is the correct outcome — the
    /// alternative is deciding here that it *was* meant as a URI and failing
    /// with a more confident error than the evidence supports.
    @Test func anUnparseableDataURIFallsThroughToThePath() {
        withRecordingHost { registrar in
            let resource = ImageResource(
                source: "data:;base64,not valid!!", resourceHostHandle: 1)
            #expect(resource != nil)
            #expect(registrar.registrations.count == 1)
            #expect(registrar.encodedByteCounts.isEmpty)
        }
    }

    // MARK: - Lifetime

    /// Registration hands back refcount one, so dropping the owner must release
    /// it. This is the contract that makes "releasing is forgetting" true.
    @Test func droppingTheResourceReleasesTheRegistration() {
        withRecordingHost { _ in
            var handle: UInt64 = 0
            do {
                let resource = ImageResource(path: "/a.png", resourceHostHandle: 3)
                handle = resource?.handle.id ?? 0
                #expect(handle != 0)
                #expect(RecordingLifecycle.released.isEmpty, "still held")
            }
            #expect(RecordingLifecycle.released == [handle])
        }
    }

    /// A failed registration owns nothing, so it must not release anything.
    @Test func aFailedRegistrationReleasesNothing() {
        withRecordingHost { registrar in
            registrar.returnsZero = true
            do { _ = ImageResource(path: "/a.png", resourceHostHandle: 1) }
            #expect(RecordingLifecycle.released.isEmpty)
        }
    }
}
