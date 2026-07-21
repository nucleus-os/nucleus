import NucleusAppHostBundle
import NucleusAppHostProtocols
import NucleusRenderHost
import NucleusRenderModel
@_spi(NucleusCompositor) import NucleusLayers
import Testing
@testable import NucleusUI

@MainActor
@Suite(.serialized)
struct RuntimeGraphIsolationTests {
    @MainActor
    private final class Counter {
        var value = 0
    }

    @MainActor
    private final class RuntimeGraph {
        let resourceHost: SwiftResourceHost
        let store: RetainedTreeStore
        let bundle: NucleusAppHostBundle
        let sink: RenderCommitSink
        let layersContext: NucleusLayers.Context
        let uiContext: UIContext
        let frameRequests: Counter

        init(contextID: UInt32, glyph: Character) throws {
            let resourceHost = SwiftResourceHost()
            let store = RetainedTreeStore(resourceHost: resourceHost)
            let bundle = NucleusAppHostBundle(resourceHost: resourceHost)
            let frameRequests = Counter()
            let sink = RenderCommitSink(
                store: store,
                resourceHost: resourceHost,
                runtimeHost: bundle.layersHost,
                requestFrame: { frameRequests.value += 1 })
            let catalog = GlyphCatalog(fontFamily: "Runtime\(contextID)")
            catalog.register("status", glyph)

            self.resourceHost = resourceHost
            self.store = store
            self.bundle = bundle
            self.frameRequests = frameRequests
            self.sink = sink
            self.layersContext = try NucleusLayers.Context(
                id: NucleusLayers.ContextID(rawValue: contextID),
                commitSink: sink)
            self.uiContext = UIContext(
                services: .inMemory(),
                resourceHostHandle: resourceHost.identity.rawValue,
                runtimeHost: bundle.layersHost,
                glyphCatalog: catalog)
        }

        func commitLayer() throws -> NucleusLayers.Layer {
            var transaction = LayerTransaction(context: layersContext)
            let layer = transaction.createLayer()
            try transaction.insert(layer)
            try transaction.commit()
            return layer
        }
    }

    private struct RuntimeResourceIdentity: Equatable {
        let host: ResourceHostIdentity
        let handle: UInt64
    }

    @Test
    func completeRuntimeGraphsRemainIsolatedThroughTeardown() throws {
        var first: RuntimeGraph? = try RuntimeGraph(
            contextID: 101,
            glyph: "\u{e101}")
        let second = try RuntimeGraph(
            contextID: 202,
            glyph: "\u{e202}")
        #expect(first!.resourceHost.identity != second.resourceHost.identity)
        #expect(first!.store !== second.store)
        #expect(first!.bundle.layersHost !== second.bundle.layersHost)

        _ = try first!.commitLayer()
        #expect(first!.store.revision == 1)
        #expect(first!.frameRequests.value == 1)
        #expect(second.store.revision == 0)
        #expect(second.frameRequests.value == 0)
        #expect(second.store.liveLayerIDs.isEmpty)

        var firstGlyph: GlyphView? = first!.uiContext.construct {
            GlyphView(name: "status")
        }
        let secondGlyph = second.uiContext.construct {
            GlyphView(name: "status")
        }
        #expect(firstGlyph?.resolvedCharacter == "\u{e101}")
        #expect(secondGlyph.resolvedCharacter == "\u{e202}")

        var firstActions = ImplicitActionTable()
        firstActions.replace([ImplicitActionRow(
            role: .notification,
            keyPath: .opacity,
            kind: .scalar,
            duration: 1)])
        var secondActions = ImplicitActionTable()
        secondActions.replace([ImplicitActionRow(
            role: .notification,
            keyPath: .opacity,
            kind: .scalar,
            duration: 2)])
        first!.resourceHost.replaceImplicitActions(firstActions)
        second.resourceHost.replaceImplicitActions(secondActions)
        #expect(first!.resourceHost.implicitActions
            .opacityFor(.notification)?.duration == 1)
        #expect(second.resourceHost.implicitActions
            .opacityFor(.notification)?.duration == 2)

        var firstImage: ImageResource? = ImageResource(
            path: "/same.png",
            resourceHostHandle: first!.resourceHost.identity.rawValue,
            runtimeHost: first!.bundle.layersHost)
        var duplicateFirstImage: ImageResource? = ImageResource(
            path: "/same.png",
            resourceHostHandle: first!.resourceHost.identity.rawValue,
            runtimeHost: first!.bundle.layersHost)
        var secondImage: ImageResource? = ImageResource(
            path: "/same.png",
            resourceHostHandle: second.resourceHost.identity.rawValue,
            runtimeHost: second.bundle.layersHost)
        let firstHandle = try #require(firstImage?.handle.id)
        #expect(duplicateFirstImage?.handle.id == firstHandle)
        #expect(first!.resourceHost.images.count == 1)
        #expect(second.resourceHost.images.count == 1)
        #expect(RuntimeResourceIdentity(
            host: first!.resourceHost.identity,
            handle: firstHandle) != RuntimeResourceIdentity(
                host: second.resourceHost.identity,
                handle: try #require(secondImage?.handle.id)))

        var firstCompletion: PresentationCompletionResult?
        let firstToken = first!.bundle.layersHost.presentationCompletions
            .register { firstCompletion = $0 }
        var secondCompletion: PresentationCompletionResult?
        let secondToken = second.bundle.layersHost.presentationCompletions
            .register { secondCompletion = $0 }
        #expect(first!.bundle.layersHost.presentationCompletions.pendingCount == 1)
        #expect(second.bundle.layersHost.presentationCompletions.pendingCount == 1)

        firstImage = nil
        duplicateFirstImage = nil
        #expect(first!.resourceHost.images.count == 0)
        #expect(second.resourceHost.images.count == 1)

        let lateHandle = try first!.bundle.imageRegistrar.register(
            path: "/late.png",
            maxWidth: 0,
            maxHeight: 0)
        var lateLifecycle: (any ImageLifecycle)? =
            first!.bundle.imageLifecycle
        let firstIdentity = first!.resourceHost.identity.rawValue
        weak let retiredHost = first!.resourceHost
        weak let retiredStore = first!.store

        first!.bundle.invalidate()
        #expect(firstCompletion == .cancelled)
        #expect(secondCompletion == nil)
        #expect(first!.bundle.layersHost.presentationCompletions.pendingCount == 0)
        #expect(second.bundle.layersHost.presentationCompletions.pendingCount == 1)

        lateLifecycle?.release(
            resourceHostHandle: firstIdentity,
            handle: lateHandle)
        #expect(first!.resourceHost.images.count == 1)
        lateLifecycle?.release(
            resourceHostHandle: second.resourceHost.identity.rawValue,
            handle: try #require(secondImage?.handle.id))
        #expect(second.resourceHost.images.count == 1)

        firstGlyph = nil
        first = nil
        #expect(retiredHost != nil, "late callback context keeps only its retired host alive")
        #expect(retiredStore == nil)
        lateLifecycle?.release(
            resourceHostHandle: firstIdentity,
            handle: lateHandle)
        lateLifecycle = nil
        #expect(retiredHost == nil)

        second.bundle.layersHost.presentationCompletions.resolve(
            secondToken,
            result: .completed)
        #expect(secondCompletion == .completed)
        #expect(second.bundle.layersHost.presentationCompletions.pendingCount == 0)
        second.bundle.layersHost.presentationCompletions.resolve(
            rawToken: firstToken.rawValue,
            result: .failed)
        #expect(firstCompletion == .cancelled)

        secondImage = nil
        #expect(second.resourceHost.images.count == 0)
        #expect(second.store.revision == 0)
        #expect(second.frameRequests.value == 0)
    }
}
