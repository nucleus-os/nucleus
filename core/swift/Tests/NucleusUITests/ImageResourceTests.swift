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
