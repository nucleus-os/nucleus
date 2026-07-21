import class NucleusLayers.LayerRuntimeHost
import Testing
@testable import NucleusUI

@MainActor
@Suite(.uiContext, .serialized)
struct ImageRequestPipelineTests {
    @MainActor
    private final class Registrar {
        let runtimeHost = LayerRuntimeHost.inMemory()
        struct Registration: Equatable {
            var path: String
            var width: UInt32
            var height: UInt32
        }

        var registrations: [Registration] = []
        var nextHandle: UInt64 = 1

        func makeResource(
            source: String,
            size: Size,
            resourceHostHandle: UInt64
        ) -> ImageResource {
            registrations.append(Registration(
                path: source,
                width: ImageResource.pixelBound(size.width),
                height: ImageResource.pixelBound(size.height)))
            defer { nextHandle &+= 1 }
            return ImageResource(
                registeredHandle: nextHandle,
                source: source,
                decodeSize: size,
                resourceHostHandle: resourceHostHandle,
                runtimeHost: runtimeHost)
        }
    }

    private actor ResolverGate {
        private(set) var calls: [ImageSourceQuery] = []
        private var continuations:
            [CheckedContinuation<String?, Never>] = []

        func resolve(_ query: ImageSourceQuery) async -> String? {
            calls.append(query)
            return await withCheckedContinuation {
                continuations.append($0)
            }
        }

        func resumeNext(_ source: String?) {
            guard !continuations.isEmpty else { return }
            continuations.removeFirst().resume(returning: source)
        }

        var callCount: Int { calls.count }
    }

    private actor MissingResolver {
        private(set) var callCount = 0

        func resolve(_ query: ImageSourceQuery) -> String? {
            _ = query
            callCount += 1
            return nil
        }
    }

    private func installRegistrar() -> Registrar {
        let registrar = Registrar()
        return registrar
    }

    private func attach(
        _ registrar: Registrar,
        to pipeline: ImageRequestPipeline
    ) {
        pipeline.resourceFactory = { [registrar] source, size, host in
            registrar.makeResource(
                source: source,
                size: size,
                resourceHostHandle: host)
        }
    }

    private func request(
        id: UInt64,
        source: ImageRequestSource = .resource("/image.png"),
        size: Size = Size(width: 16, height: 16),
        scale: BackingScaleFactor = .one,
        appearance: Appearance = .dark,
        themeGeneration: UInt64 = 0,
        cancellationGeneration: UInt64 = 1
    ) -> ImageRequest {
        ImageRequest(
            id: ImageRequestID(rawValue: id),
            source: source,
            targetSize: size,
            backingScaleFactor: scale,
            appearance: appearance,
            iconThemeGeneration: themeGeneration,
            cancellationGeneration: cancellationGeneration)
    }

    private func hostedContext(
        resolver: ImageSourceResolver = .directResourcesOnly
    ) -> UIContext {
        UIContext(
            services: UIHostServices(
                textSystem: TextSystem(),
                pasteboard: Pasteboard(
                    adapter: InMemoryPasteboardAdapter()),
                imageSourceResolver: resolver,
                requiresTextBackend: false,
                diagnosticSink: { _ in }),
            resourceHostHandle: 7)
    }

    private func wait(
        until predicate: @escaping @MainActor () async -> Bool
    ) async {
        while !(await predicate()) {
            await Task.yield()
        }
    }

    @Test func duplicateRequestsCoalesceResolutionAndRegistration() async {
        let registrar = installRegistrar()
        let gate = ResolverGate()
        let pipeline = ImageRequestPipeline(
            resourceHostHandle: 7,
            resolver: ImageSourceResolver {
                await gate.resolve($0)
            })
        attach(registrar, to: pipeline)
        let source = ImageRequestSource.icon(
            name: "browser",
            theme: "Adwaita")
        var handles: [UInt64] = []
        let first = pipeline.request(request(id: 1, source: source)) {
            if case .success(let resource) = $0.outcome {
                handles.append(resource.handle.id)
            }
        }
        let second = pipeline.request(request(id: 2, source: source)) {
            if case .success(let resource) = $0.outcome {
                handles.append(resource.handle.id)
            }
        }
        _ = [first, second]

        await wait { await gate.callCount == 1 }
        #expect(pipeline.inFlightRequestCount == 1)
        #expect(pipeline.consumerCount == 2)
        await gate.resumeNext("/icons/browser.svg")
        await wait { handles.count == 2 }

        #expect(handles[0] == handles[1])
        #expect(registrar.registrations == [
            .init(path: "/icons/browser.svg", width: 16, height: 16)
        ])
        #expect(pipeline.inFlightRequestCount == 0)
        #expect(pipeline.cachedEntryCount == 1)
    }

    @Test func cancellingOneCoalescedConsumerLeavesTheOtherAlive() async {
        let registrar = installRegistrar()
        let gate = ResolverGate()
        let pipeline = ImageRequestPipeline(
            resourceHostHandle: 7,
            resolver: ImageSourceResolver {
                await gate.resolve($0)
            })
        attach(registrar, to: pipeline)
        let source = ImageRequestSource.icon(
            name: "terminal",
            theme: "Adwaita")
        var completed: [UInt64] = []
        let first = pipeline.request(request(id: 1, source: source)) {
            completed.append($0.requestID.rawValue)
        }
        let second = pipeline.request(request(id: 2, source: source)) {
            completed.append($0.requestID.rawValue)
        }
        first.cancel()
        _ = second

        await wait { await gate.callCount == 1 }
        await gate.resumeNext("/icons/terminal.svg")
        await wait { !completed.isEmpty }
        #expect(completed == [2])
        #expect(pipeline.consumerCount == 0)
    }

    @Test func cacheKeysSeparateScaleAppearanceAndThemeGeneration() async {
        let registrar = installRegistrar()
        let pipeline = ImageRequestPipeline(
            resourceHostHandle: 7,
            resolver: ImageSourceResolver { _ in "/icon.svg" })
        attach(registrar, to: pipeline)
        let icon = ImageRequestSource.icon(
            name: "app",
            theme: "test")
        var completions = 0
        var tokens: [ImageRequestToken] = []
        for value in [
            request(id: 1, source: icon),
            request(
                id: 2,
                source: icon,
                scale: BackingScaleFactor(Double(2))),
            request(id: 3, source: icon, appearance: .light),
            request(id: 4, source: icon, themeGeneration: 1),
        ] {
            let expected = completions + 1
            tokens.append(pipeline.request(value) { _ in
                completions += 1
            })
            await wait { completions == expected }
        }
        #expect(registrar.registrations.map {
            ($0.width, $0.height)
        }.elementsEqual([
            (16, 16),
            (32, 32),
            (16, 16),
            (16, 16),
        ], by: ==))
        #expect(pipeline.cachedEntryCount == 4)
    }

    @Test func positiveAndNegativeCachesRemainBounded() async {
        let registrar = installRegistrar()
        let pipeline = ImageRequestPipeline(
            resourceHostHandle: 7,
            limits: ImageRequestCacheLimits(
                maximumEntries: 2,
                maximumDecodedBytes: 2 * 16 * 16 * 4,
                maximumNegativeEntries: 2,
                maximumInFlightRequests: 2,
                negativeResultLifetime: .seconds(5)))
        attach(registrar, to: pipeline)
        var completions = 0
        var tokens: [ImageRequestToken] = []
        for index in 0..<10 {
            let expected = completions + 1
            tokens.append(pipeline.request(request(
                id: UInt64(index + 1),
                source: .resource("/\(index).png")
            )) { _ in completions += 1 })
            await wait { completions == expected }
        }
        #expect(registrar.registrations.count == 10)
        #expect(pipeline.cachedEntryCount == 2)
        #expect(pipeline.cachedDecodedByteCost <= 2 * 16 * 16 * 4)

        let missPipeline = ImageRequestPipeline(
            resourceHostHandle: 7,
            resolver: ImageSourceResolver { _ in nil },
            limits: ImageRequestCacheLimits(
                maximumEntries: 2,
                maximumDecodedBytes: 2_048,
                maximumNegativeEntries: 2,
                maximumInFlightRequests: 2,
                negativeResultLifetime: .seconds(5)))
        var misses = 0
        for index in 0..<10 {
            tokens.append(missPipeline.request(request(
                id: UInt64(index + 100),
                source: .icon(name: "\(index)", theme: "test")
            )) { _ in misses += 1 })
            await wait { misses == index + 1 }
        }
        #expect(missPipeline.negativeEntryCount == 2)
    }

    @Test func negativeResultsSuppressRepeatedWorkThenRetry() async {
        _ = installRegistrar()
        let missing = MissingResolver()
        let pipeline = ImageRequestPipeline(
            resourceHostHandle: 7,
            clock: testUIContext().clock,
            resolver: ImageSourceResolver {
                await missing.resolve($0)
            },
            limits: ImageRequestCacheLimits(
                maximumEntries: 2,
                maximumDecodedBytes: 2_048,
                maximumNegativeEntries: 2,
                maximumInFlightRequests: 2,
                negativeResultLifetime: .milliseconds(5)))
        let source = ImageRequestSource.icon(
            name: "missing",
            theme: "test")
        var completed = 0
        var tokens: [ImageRequestToken] = []
        tokens.append(pipeline.request(request(
            id: 1,
            source: source
        )) { _ in completed += 1 })
        await wait { completed == 1 }
        tokens.append(pipeline.request(request(
            id: 2,
            source: source
        )) { _ in completed += 1 })
        #expect(completed == 2)
        #expect(await missing.callCount == 1)

        testUIClock().advance(by: .nanoseconds(4_999_999))
        tokens.append(pipeline.request(request(
            id: 3,
            source: source
        )) { _ in completed += 1 })
        await wait { completed == 3 }
        #expect(await missing.callCount == 1)

        testUIClock().advance(by: .nanoseconds(1))
        tokens.append(pipeline.request(request(
            id: 4,
            source: source
        )) { _ in completed += 1 })
        await wait { completed == 4 }
        #expect(await missing.callCount == 2)
        _ = tokens
    }

    @Test func directResourcesIgnoreAppearanceAndIconThemeChanges() async {
        let registrar = installRegistrar()
        let pipeline = ImageRequestPipeline(resourceHostHandle: 7)
        attach(registrar, to: pipeline)
        var completed = 0
        var tokens: [ImageRequestToken] = []
        for value in [
            request(id: 1),
            request(id: 2, appearance: .light),
            request(id: 3, themeGeneration: 42),
        ] {
            let expected = completed + 1
            tokens.append(pipeline.request(value) { _ in completed += 1 })
            await wait { completed == expected }
        }
        #expect(registrar.registrations.count == 1)
        #expect(pipeline.cachedEntryCount == 1)
        _ = tokens
    }

    @Test func sourceReplacementAndDetachRejectLateMutation() async {
        let registrar = installRegistrar()
        let gate = ResolverGate()
        let services = UIHostServices(
            textSystem: TextSystem(),
            pasteboard: Pasteboard(adapter: InMemoryPasteboardAdapter()),
            imageSourceResolver: ImageSourceResolver {
                await gate.resolve($0)
            },
            requiresTextBackend: false,
            diagnosticSink: { _ in })
        let context = UIContext(
            services: services,
            resourceHostHandle: 7)
        attach(registrar, to: context.imageRequests)
        let view = context.construct {
            let view = ImageView()
            view.frame = Rect(x: 0, y: 0, width: 16, height: 16)
            view.source = .icon(name: "old", theme: "test")
            view.layoutIfNeeded()
            return view
        }
        await wait { await gate.callCount == 1 }
        view.source = .icon(name: "new", theme: "test")
        await wait { await gate.callCount == 2 }
        await gate.resumeNext("/old.png")
        await gate.resumeNext("/new.png")
        await wait { view.loadState == .loaded }
        #expect(view.resource?.path == "/new.png")
        #expect(registrar.registrations.map(\.path) == ["/new.png"])

        view.source = .icon(name: "pending", theme: "test")
        await wait { await gate.callCount == 3 }
        let window = context.construct {
            let window = Window(
                frame: Rect(x: 0, y: 0, width: 16, height: 16))
            window.setContentView(view)
            return window
        }
        _ = window
        view.removeFromSuperview()
        #expect(view.resource == nil)
        #expect(context.imageRequests.consumerCount == 0)
        await gate.resumeNext("/pending.png")
        await Task.yield()
        #expect(view.resource == nil)
    }

    @Test func imageViewOwnsPlaceholderFailureAndScalePolicy() async {
        let registrar = installRegistrar()
        let context = hostedContext(
            resolver: ImageSourceResolver { _ in nil })
        let failed = context.construct {
            let view = ImageView()
            view.placeholderImage = ImageHandle(id: 90)
            view.failureImage = ImageHandle(id: 91)
            view.frame = Rect(x: 0, y: 0, width: 12, height: 10)
            view.source = .icon(name: "missing", theme: "test")
            view.layoutIfNeeded()
            return view
        }
        #expect(failed.loadState == .loading)
        #expect(failed.image == ImageHandle(id: 90))
        await wait {
            if case .failed = failed.loadState { return true }
            return false
        }
        #expect(failed.image == ImageHandle(id: 91))

        let directContext = hostedContext()
        attach(registrar, to: directContext.imageRequests)
        let direct = directContext.construct {
            let view = ImageView()
            view.frame = Rect(x: 0, y: 0, width: 12, height: 10)
            view.source = .resource("/scale.png")
            view.layoutIfNeeded()
            return view
        }
        await wait { direct.loadState == .loaded }
        #expect(registrar.registrations.last == .init(
            path: "/scale.png",
            width: 12,
            height: 10))
        direct.requestBackingScaleFactor =
            BackingScaleFactor(Double(2))
        await wait {
            direct.loadState == .loaded
                && direct.resource?.decodeSize
                    == Size(width: 24, height: 20)
        }
        #expect(registrar.registrations.last == .init(
            path: "/scale.png",
            width: 24,
            height: 20))
    }

    @Test func memoryPressureAndShutdownHaveExplicitTerminalState() async {
        let registrar = installRegistrar()
        let pipeline = ImageRequestPipeline(resourceHostHandle: 7)
        attach(registrar, to: pipeline)
        var completed = 0
        let token = pipeline.request(request(id: 1)) { _ in completed += 1 }
        _ = token
        await wait { completed == 1 }
        #expect(pipeline.cachedEntryCount == 1)
        pipeline.handleMemoryPressure()
        #expect(pipeline.cachedEntryCount == 0)

        pipeline.shutdown()
        var failure: ImageRequestFailure?
        _ = pipeline.request(request(id: 2)) {
            if case .failure(let value) = $0.outcome {
                failure = value
            }
        }
        #expect(failure == .shutdown)
    }

    @Test func continuousImageListScrollingStaysWithinEveryUIBound() async {
        let registrar = installRegistrar()
        let context = hostedContext()
        attach(registrar, to: context.imageRequests)
        let list = context.construct {
            let list = ListView()
            list.frame = Rect(x: 0, y: 0, width: 120, height: 96)
            list.rowHeight = 24
            list.overscan = 1
            list.makeRow = { ImageView() }
            list.configureRow = { view, _, index in
                guard let image = view as? ImageView else { return }
                image.source = .resource("/icons/\(index).png")
            }
            list.applySnapshot(
                try! CollectionSnapshot(ids: Array(0..<10_000)))
            list.layoutIfNeeded()
            return list
        }

        for step in 0..<500 {
            list.contentOffset.y = Double(step * 48)
            await Task.yield()
        }
        await wait {
            context.imageRequests.inFlightRequestCount == 0
        }

        #expect(list.materializedRowCount <= 7)
        #expect(list.reusePoolCount <= 16)
        #expect(context.imageRequests.cachedEntryCount <= 128)
        #expect(
            context.imageRequests.cachedDecodedByteCost
                <= 64 * 1_024 * 1_024)
        #expect(registrar.registrations.count < 10_000)
        context.imageRequests.handleMemoryPressure()
        #expect(context.imageRequests.cachedEntryCount == 0)
    }
}
