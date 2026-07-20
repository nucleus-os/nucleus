import Testing
// A selective import: NucleusLayers carries its own `Size`/`Rect`, and a plain
// import would make every geometry mention below ambiguous. Qualifying does not
// help — NucleusUI declares an inner `NucleusUI` enum that shadows the module
// name, so `NucleusUI.Size` does not resolve either.
import func NucleusLayers.installStubHost
import protocol NucleusLayers.CommitSink
import struct NucleusLayers.EncodedTransaction
import enum NucleusLayers.LayerError
import class NucleusLayers.Context
import struct NucleusLayers.ContextID
@testable import NucleusUI

/// A commit sink that reports a real resource host, which is what registration
/// requires: a handle it cannot release is one it should not take.
@MainActor
private final class HostedCommitSink: CommitSink {
    let resourceHostHandle: UInt64 = 42
    func commit(_ transaction: EncodedTransaction) throws(LayerError) {}
}

/// Build a view inside a context with a resource host. A view captures its
/// context at init, so the context must be current *then*, not merely later.
@MainActor
private func withHostedContext<T>(_ body: () throws -> T) rethrows -> T {
    installStubHost()
    guard let context = try? Context(id: .root, commitSink: HostedCommitSink()) else {
        return try body()
    }
    return try Application.withContext(context, body)
}

/// `ImageView` fit modes and source registration.
@MainActor
@Suite(.uiContext) struct ImageViewTests {
    private func makeView(image: Size, frame: Size) -> ImageView {
        let view = ImageView(image: ImageHandle(id: 1), imageSize: image)
        view.frame = Rect(origin: .zero, size: frame)
        return view
    }

    // MARK: - Fit

    @Test func stretchFillsTheFrameExactly() {
        let view = makeView(image: Size(width: 100, height: 50), frame: Size(width: 40, height: 40))
        view.contentMode = .stretch
        #expect(view.destinationRect() == Rect(x: 0, y: 0, width: 40, height: 40))
    }

    /// Contain fits entirely inside, so the *larger* ratio is the one that must
    /// not be exceeded.
    @Test func containFitsInsideAndLetterboxes() {
        let view = makeView(image: Size(width: 100, height: 50), frame: Size(width: 40, height: 40))
        view.contentMode = .contain

        let rect = view.destinationRect()
        #expect(rect.size.width == 40)
        #expect(rect.size.height == 20)
        #expect(rect.origin.x == 0)
        #expect(rect.origin.y == 10, "centred vertically in the leftover space")
    }

    /// Cover fills the frame and overflows, which is why `draw` clips.
    @Test func coverFillsTheFrameAndOverflows() {
        let view = makeView(image: Size(width: 100, height: 50), frame: Size(width: 40, height: 40))
        view.contentMode = .cover

        let rect = view.destinationRect()
        #expect(rect.size.height == 40)
        #expect(rect.size.width == 80)
        #expect(rect.origin.x == -20, "the overflow is split evenly, so the crop is centred")
        #expect(rect.origin.y == 0)
    }

    @Test func aMatchingAspectRatioIsUnchangedByEitherMode() {
        for mode in [ImageContentMode.contain, .cover] {
            let view = makeView(image: Size(width: 50, height: 50), frame: Size(width: 25, height: 25))
            view.contentMode = mode
            #expect(view.destinationRect() == Rect(x: 0, y: 0, width: 25, height: 25))
        }
    }

    /// Decode happens in the renderer, so this side may never have seen the
    /// pixels. Filling the frame is the only honest thing to do without a ratio.
    @Test func anUnknownImageSizeFallsBackToFillingTheFrame() {
        for mode in [ImageContentMode.contain, .cover] {
            let view = makeView(image: .zero, frame: Size(width: 30, height: 20))
            view.contentMode = mode
            #expect(view.destinationRect() == Rect(x: 0, y: 0, width: 30, height: 20))
        }
    }

    @Test func anEmptyFrameHasNothingToDraw() {
        let view = makeView(image: Size(width: 10, height: 10), frame: .zero)
        view.contentMode = .contain
        #expect(view.destinationRect().size == Size(width: 0, height: 0))
    }

    // MARK: - Intrinsic size

    @Test func theIntrinsicSizeIsTheImageSize() {
        let view = makeView(image: Size(width: 64, height: 32), frame: Size(width: 10, height: 10))
        #expect(view.intrinsicContentSize == Size(width: 64, height: 32))
    }

    @Test func withoutAnImageThereIsNoIntrinsicSize() {
        let view = ImageView(imageSize: Size(width: 64, height: 32))
        #expect(view.intrinsicContentSize == .zero)
    }

    @Test func anImageDescribesItselfAsAnImage() {
        #expect(ImageView().accessibilityRole == .image)
    }

    // MARK: - Source registration

    @Test func assigningAResourceAdoptsItsHandle() {
        installStubHost()
        let view = ImageView()
        let resource = ImageResource(path: "/a.png", resourceHostHandle: 5)
        view.resource = resource
        #expect(view.image == resource?.handle)

        view.resource = nil
        #expect(view.image == nil, "dropping the resource drops the handle with it")
    }

    /// Registration waits for a size, because the size is part of what is being
    /// registered.
    @Test func aSourceWithoutASizeDoesNotRegisterYet() {
        withHostedContext {
            let view = ImageView()
            view.sourcePath = "/icons/app.png"
            #expect(view.resource == nil)

            view.arrange(in: Rect(x: 0, y: 0, width: 24, height: 24))
            #expect(view.resource?.path == "/icons/app.png")
            #expect(view.resource?.decodeSize == Size(width: 24, height: 24))
        }
    }

    /// A view that grew needs a decode at the new size, not an upscale of the old
    /// one — the bounds are part of the registration's identity.
    @Test func resizingRegistersAgainAtTheNewSize() {
        withHostedContext {
            let view = ImageView()
            view.sourcePath = "/icons/app.png"
            view.arrange(in: Rect(x: 0, y: 0, width: 24, height: 24))
            let first = view.resource

            view.arrange(in: Rect(x: 0, y: 0, width: 48, height: 48))
            #expect(view.resource !== first)
            #expect(view.resource?.decodeSize == Size(width: 48, height: 48))
        }
    }

    /// Re-arranging at the same size is the common case (any relayout), and it
    /// must not churn the registration.
    @Test func rearrangingAtTheSameSizeKeepsTheRegistration() {
        withHostedContext {
            let view = ImageView()
            view.sourcePath = "/icons/app.png"
            view.arrange(in: Rect(x: 0, y: 0, width: 24, height: 24))
            let first = view.resource

            view.arrange(in: Rect(x: 0, y: 0, width: 24, height: 24))
            #expect(view.resource === first)
        }
    }

    @Test func changingTheSourceRegistersTheNewFile() {
        withHostedContext {
            let view = ImageView()
            view.sourcePath = "/icons/one.png"
            view.arrange(in: Rect(x: 0, y: 0, width: 16, height: 16))
            let first = view.resource

            view.sourcePath = "/icons/two.png"
            view.arrange(in: Rect(x: 0, y: 0, width: 16, height: 16))
            #expect(view.resource !== first)
            #expect(view.resource?.path == "/icons/two.png")
        }
    }

    @Test func theConvenienceInitializerTakesAPath() {
        withHostedContext {
                let view = ImageView(path: "/icons/app.png")
                #expect(view.sourcePath == "/icons/app.png")
        }
    }
}

/// Image tint: recolouring by alpha, and desaturation.
@MainActor
@Suite(.uiContext) struct ImageTintTests {
    private func makeView() -> ImageView {
        let view = ImageView(image: ImageHandle(id: 1), imageSize: Size(width: 10, height: 10))
        view.frame = Rect(x: 0, y: 0, width: 10, height: 10)
        return view
    }

    @Test func aTintIsAbsentByDefault() {
        #expect(makeView().tint == nil)
        #expect(makeView().saturation == 1)
    }

    @Test func settingATintRepaints() {
        let view = makeView()
        view.displayIfNeeded()
        view.tint = .role(.primary)
        #expect(view.needsDisplay)
    }

    @Test func anIdenticalTintIsNotAChange() {
        let view = makeView()
        view.tint = .role(.primary)
        view.displayIfNeeded()
        view.tint = .role(.primary)
        #expect(!view.needsDisplay)
    }

    @Test func changingSaturationRepaints() {
        let view = makeView()
        view.displayIfNeeded()
        view.saturation = 0
        #expect(view.needsDisplay)
    }

    /// The tint is a spec, so a tinted icon follows a retheme like everything
    /// else. No override is needed for this — the base repaints on an appearance
    /// change already, and adding one would only restate it.
    @Test func rethemingRepaintsATintedImage() {
        let view = makeView()
        view.tint = .role(.primary)
        view.palette = .dark
        view.displayIfNeeded()

        view.palette = .light
        #expect(view.needsDisplay)
    }

    @Test func theTintResolvesAgainstThePalette() {
        let view = makeView()
        view.tint = .role(.primary)
        view.palette = .light
        #expect(view.resolve(view.tint!) == Palette.light.primary)
    }
}
