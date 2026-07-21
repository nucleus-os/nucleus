import Testing
import NucleusUI
@_spi(NucleusCompositor) import NucleusLayers
import NucleusAppHostProtocols
import NucleusTypes

/// Counts registrations so a test can prove that an unchanged drawing does not
/// re-register. The in-memory context registrar hands out handles without
/// counting, and nothing else in the tree would notice a regression to
/// per-publish re-registration.
final class CountingPaintContentRegistrar: PaintContentRegistrar {
    var registrationCount = 0
    var lastPayloadByteCount = 0
    private var next: UInt64 = 1

    func register(
        resourceHostHandle: UInt64,
        width: Float,
        height: Float,
        commands: Span<NucleusTypes.PaintCommand>,
        payload: Span<UInt8>
    ) throws(PaintContentRegistrationError) -> UInt64 {
        registrationCount += 1
        lastPayloadByteCount = payload.count
        defer { next += 1 }
        return next
    }
}

@MainActor
private final class PayloadPaintView: View {
    var color = Palette.standard(for: .light).primary {
        didSet { setNeedsDisplay() }
    }

    override func draw(in context: GraphicsContext) {
        context.fillColor = color
        var path = Path()
        path.move(to: Point(x: 0, y: 0))
        path.addLine(to: Point(x: bounds.size.width, y: 0))
        path.addLine(to: Point(
            x: bounds.size.width,
            y: bounds.size.height))
        path.close()
        context.fill(path)
    }
}

@MainActor
@Suite(.uiContext) struct PaintRegistrationTests {
    init() {
        installTestTextBackend()
    }

    /// Install a host whose paint registrar counts, keeping every other slot
    /// stubbed.
    private func makeCountingContext() -> (
        registrar: CountingPaintContentRegistrar,
        context: Context
    ) {
        let registrar = CountingPaintContentRegistrar()
        let stub = LayerRuntimeHost.inMemory()
        let runtimeHost = LayerRuntimeHost(
            operations: Host(
            imageRegistrar: stub.operations.imageRegistrar,
            paintContentRegistrar: registrar,
            runtimeEffectRegistrar: stub.operations.runtimeEffectRegistrar,
            iosurfaceBinder: stub.operations.iosurfaceBinder,
            contextIDAllocator: stub.operations.contextIDAllocator,
            displayLinkSource: stub.operations.displayLinkSource,
            implicitActionRegistrar: stub.operations.implicitActionRegistrar),
            lifecycle: stub.lifecycle)
        return (
            registrar,
            Application.makeInMemoryVisualContext(
                runtimeHost: runtimeHost))
    }

    private func makeStyledView() -> View {
        let view = View()
        view.frame = Rect(x: 0, y: 0, width: 40, height: 20)
        view.backgroundColor = Color(0.1, 0.2, 0.3, 1)
        view.border = Border(width: 2, color: Color(1, 1, 1, 1))
        return view
    }

    // MARK: - The seam, without a view tree

    /// `PaintRegistration` is the unit React Native's mount path consumes, and
    /// RN has no publisher. Registering must therefore work with no tree walk,
    /// no backing layer, and no publisher involved at all.
    @Test func registrationNeedsNoViewTree() throws {
        let (registrar, context) = makeCountingContext()

        let graphics = GraphicsContext(textSystem: testTextSystem())
        graphics.fillColor = Color(1, 0, 0, 1)
        graphics.fill(Rect(x: 0, y: 0, width: 10, height: 10))

        let registered = try PaintRegistration.register(
            graphics.recording,
            width: 10,
            height: 10,
            in: context,
            textSystem: testTextSystem())
        #expect(registrar.registrationCount == 1)
        #expect(registered.update.content != nil, "the update binds content")
    }

    /// An empty recording clears content rather than registering an empty list
    /// or leaving the previous frame bound.
    @Test func anEmptyRecordingProducesTheClearContentUpdate() throws {
        let (registrar, context) = makeCountingContext()
        let registered = try PaintRegistration.register(
            PaintRecording(),
            width: 10,
            height: 10,
            in: context,
            textSystem: testTextSystem())

        #expect(registrar.registrationCount == 0, "nothing is registered")
        #expect(registered.update.content == LayerContent.none, "content is cleared")
    }

    /// Path geometry rides the payload blob, so a drawing containing a path
    /// must hand the registrar a non-empty payload. Without this the offsets on
    /// each command would point into nothing.
    @Test func pathGeometryReachesTheRegistrarAsPayload() throws {
        let (registrar, context) = makeCountingContext()

        let graphics = GraphicsContext(textSystem: testTextSystem())
        var path = Path()
        path.move(to: Point(x: 0, y: 0))
        path.addLine(to: Point(x: 10, y: 10))
        graphics.stroke(path)

        _ = try PaintRegistration.register(
            graphics.recording,
            width: 10,
            height: 10,
            in: context,
            textSystem: testTextSystem())
        #expect(registrar.lastPayloadByteCount > 0, "payload reached the registrar")
    }

    // MARK: - The re-registration gate

    /// Publishing an unchanged view must not re-register its paint content.
    /// This is the regression the plan flagged as untested: recording-time
    /// handle minting would make every text-bearing recording unequal to the
    /// previous one and re-register on every publish.
    @Test func republishingAnUnchangedViewDoesNotReRegister() throws {
        let (registrar, context) = makeCountingContext()
        let window = Window(title: "Gate")
        let root = makeStyledView()
        window.setContentView(root)
        window.orderFront()

        let publisher = WindowLayerPublisher(context: context)
        _ = try publisher.publish(windows: [window])
        let afterFirst = registrar.registrationCount
        #expect(afterFirst >= 1, "the first publish registers")

        _ = try publisher.publish(windows: [window])
        #expect(registrar.registrationCount == afterFirst, "an unchanged view re-registers nothing")
    }

    @Test func changingTheDrawingReRegisters() throws {
        let (registrar, context) = makeCountingContext()
        let window = Window(title: "Gate")
        let root = makeStyledView()
        window.setContentView(root)
        window.orderFront()

        let publisher = WindowLayerPublisher(context: context)
        _ = try publisher.publish(windows: [window])
        let afterFirst = registrar.registrationCount

        root.backgroundColor = Color(0.9, 0.1, 0.1, 1)
        _ = try publisher.publish(windows: [window])
        #expect(registrar.registrationCount > afterFirst, "a changed drawing re-registers")
    }

    /// Text is the case that would silently regress: a recording references
    /// layouts by index, so two recordings of the same text compare equal. If
    /// handles were minted while drawing, they would differ every time.
    @Test func republishingUnchangedTextDoesNotReRegister() throws {
        let (registrar, context) = makeCountingContext()
        let window = Window(title: "Text gate")
        let label = Label("Nucleus")
        label.frame = Rect(x: 0, y: 0, width: 120, height: 20)
        window.setContentView(label)
        window.orderFront()

        let publisher = WindowLayerPublisher(context: context)
        _ = try publisher.publish(windows: [window])
        let afterFirst = registrar.registrationCount
        #expect(afterFirst >= 1)

        label.setNeedsDisplay()
        _ = try publisher.publish(windows: [window])
        #expect(
            registrar.registrationCount == afterFirst,
            "redrawing the same text must not re-register")
    }

    @Test func equalPaintAcrossViewsSharesOneBoundedRegistration() throws {
        let (registrar, context) = makeCountingContext()
        let root = View()
        let first = makeStyledView()
        let second = makeStyledView()
        root.addSubview(first)
        root.addSubview(second)
        let publisher = ViewLayerPublisher(context: context)

        _ = try publisher.publish(roots: [root])

        #expect(registrar.registrationCount == 1)
        #expect(publisher.lastMetrics.contentRegistrations == 1)
        #expect(publisher.lastMetrics.contentCacheHits == 1)
        #expect(publisher.retainedPaintRegistrationCount == 1)

        first.removeFromSuperview()
        _ = try publisher.publish(roots: [root])
        #expect(
            publisher.retainedPaintRegistrationCount == 1,
            "one accepted user keeps the shared registration alive")

        second.removeFromSuperview()
        _ = try publisher.publish(roots: [root])
        #expect(publisher.retainedPaintRegistrationCount == 0)
    }

    @Test func oneDirtyLeafHashesAndStagesOnlyItsPath() throws {
        let (registrar, context) = makeCountingContext()
        let root = View()
        var target: PayloadPaintView?
        for index in 0..<1_024 {
            let child: View
            if index == 512 {
                let payloadView = PayloadPaintView()
                payloadView.frame = Rect(
                    x: 0, y: 0, width: 40, height: 20)
                target = payloadView
                child = payloadView
            } else {
                child = makeStyledView()
            }
            root.addSubview(child)
        }
        let publisher = ViewLayerPublisher(context: context)
        _ = try publisher.publish(roots: [root])

        target?.color = Palette.standard(for: .light).error
        _ = try publisher.publish(roots: [root])

        #expect(publisher.lastMetrics.nodesVisited == 2)
        #expect(publisher.lastMetrics.snapshotsAuthored == 1)
        #expect(publisher.lastMetrics.recordingsHashed == 1)
        #expect(publisher.lastMetrics.paintPayloadBytesHashed > 0)
        #expect(
            publisher.lastMetrics.paintPayloadBytesHashed
                == UInt64(registrar.lastPayloadByteCount))
        #expect(publisher.lastMetrics.paintCacheKeysReconciled == 2)
        #expect(publisher.lastMetrics.registrationsCreated == 1)
        #expect(publisher.lastMetrics.cacheUpserts == 2)
        #expect(publisher.lastMetrics.cacheRemovals == 0)
    }
}
