import NucleusHostProjectionTestSupport
import NucleusRendererTestSupport
import NucleusResourceTestSupport
import NucleusRetainedSceneTestSupport
import NucleusUI
import NucleusUIEmbedder
@_spi(NucleusCompositor) import NucleusLayers
import Testing

@MainActor
@Suite(.uiContext)
struct FoundationConformanceTests {
    @Test
    func baselineSceneUsesOneSemanticOwnerThroughInMemoryLifecycle()
        throws
    {
        let uiContext = testUIContext()
        let fixture = BaselineRetainedSceneFactory.make(in: uiContext)
        let scene = WindowScene(inMemoryWindows: fixture.windows)

        #expect(fixture.views.count == BaselineSemanticID.allCases.count)
        #expect(fixture.views.values.allSatisfy {
            $0.uiContext === uiContext
        })
        #expect(fixture.windows.allSatisfy {
            $0.uiContext === uiContext
        })
        #expect(fixture.secureField.accessibilityValue == nil)

        scene.transition(to: .active)
        fixture.windows[0].makeKey()
        #expect(scene.keyWindow === fixture.windows[0])

        let first = try scene.publish()
        #expect(first.visualContent.count == 2)
        let stableIDs = fixture.views.mapValues(\.id)

        fixture[.title].isHidden = true
        fixture[.paintedContent].frame = Rect(
            x: 24, y: 60, width: 190, height: 80)
        let changed = try scene.publish()
        #expect(changed.visualContent.count == 2)
        #expect(fixture.views.mapValues(\.id) == stableIDs)

        try scene.disconnect()
        #expect(scene.activationState == .disconnected)
        #expect(scene.windows.isEmpty)
    }

    @Test
    func directPublicationSuppressesACompletelyCleanScene() throws {
        let sink = InMemoryCommitSink()
        let publication = try WindowScenePublicationContext(
            visualContextID: ContextID(rawValue: 9_201),
            commitSink: sink,
            services: testUIContext().services)
        let fixture = BaselineRetainedSceneFactory.make(
            in: publication.semanticContext)
        let scene = publication.makeWindowScene(windows: fixture.windows)
        scene.transition(to: .active)

        _ = try scene.publish()
        let firstTransactionCount = sink.transactions.count
        #expect(firstTransactionCount > 0)

        _ = try scene.publish()
        #expect(sink.transactions.count == firstTransactionCount)

        fixture[.toggle].isHidden = true
        _ = try scene.publish()
        #expect(sink.transactions.count == firstTransactionCount + 1)

        try scene.disconnect()
        #expect(publication.visualContext.layers.isEmpty)
    }

    @Test
    func projectionCapabilitiesRequireExplicitSupportOrOmission() {
        let declarations = FoundationHostCapabilities.declarations
        #expect(declarations.count == FoundationHostProjection.allCases.count)
        #expect(Set(declarations.map(\.projection)).count
            == FoundationHostProjection.allCases.count)
        let fabric = declarations.first { $0.projection == .fabric }
        #expect(fabric?.supports(.retainedViews) == true)
        #expect(fabric?.supports(.nativeInput) == false)
    }

    @Test
    func pixelFixturesCarryBackendMetadataAndDocumentedTolerance() {
        let exact = PixelFixtureMetadata(
            backend: "Skia CPU raster",
            colorFormat: .rgba8888,
            colorSpace: "sRGB")
        #expect(PixelFixtureComparator.compare(
            actual: [10, 20, 30, 255],
            expected: [10, 20, 30, 255],
            metadata: exact).matches)

        let tolerant = PixelFixtureMetadata(
            backend: "Skia native text",
            colorFormat: .rgba8888,
            colorSpace: "sRGB",
            channelTolerance: 2)
        #expect(PixelFixtureComparator.compare(
            actual: [10, 21, 28, 255],
            expected: [10, 20, 30, 255],
            metadata: tolerant).matches)
    }

    @Test
    func workCounterDeltasExpressStructuralZeroWork() {
        let baseline = FoundationWorkCounters(
            visits: 20,
            commits: 4,
            registrations: 7,
            acquisitions: 2,
            presentations: 2,
            liveResources: 12)
        let unchanged = baseline.delta(from: baseline)
        #expect(unchanged.performsNoWork)
        #expect(unchanged.liveResources == 0)
    }
}
