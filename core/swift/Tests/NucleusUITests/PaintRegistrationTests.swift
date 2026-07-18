import Testing
import NucleusUI
@_spi(NucleusCompositor) import NucleusLayers
import NucleusAppHostProtocols
import NucleusTypes

/// Counts registrations so a test can prove that an unchanged drawing does not
/// re-register. `installStubHost()`'s registrar hands out handles without
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
@Suite struct PaintRegistrationTests {
    /// Install a host whose paint registrar counts, keeping every other slot
    /// stubbed.
    private func installCountingHost() -> CountingPaintContentRegistrar {
        installStubHost()
        let registrar = CountingPaintContentRegistrar()
        let stub = currentHost()!
        installHost(Host(
            imageRegistrar: stub.imageRegistrar,
            paintContentRegistrar: registrar,
            runtimeEffectRegistrar: stub.runtimeEffectRegistrar,
            iosurfaceBinder: stub.iosurfaceBinder,
            contextIDAllocator: stub.contextIDAllocator,
            displayLinkSource: stub.displayLinkSource,
            implicitActionRegistrar: stub.implicitActionRegistrar))
        return registrar
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
        let registrar = installCountingHost()
        let context = Application.defaultContext

        let graphics = GraphicsContext()
        graphics.fillColor = Color(1, 0, 0, 1)
        graphics.fill(Rect(x: 0, y: 0, width: 10, height: 10))

        let registered = try PaintRegistration.register(
            graphics.recording, width: 10, height: 10, in: context)
        #expect(registrar.registrationCount == 1)
        #expect(registered.update.content != nil, "the update binds content")
    }

    /// An empty recording clears content rather than registering an empty list
    /// or leaving the previous frame bound.
    @Test func anEmptyRecordingProducesTheClearContentUpdate() throws {
        let registrar = installCountingHost()
        let registered = try PaintRegistration.register(
            PaintRecording(), width: 10, height: 10, in: Application.defaultContext)

        #expect(registrar.registrationCount == 0, "nothing is registered")
        #expect(registered.update.content == LayerContent.none, "content is cleared")
    }

    /// Path geometry rides the payload blob, so a drawing containing a path
    /// must hand the registrar a non-empty payload. Without this the offsets on
    /// each command would point into nothing.
    @Test func pathGeometryReachesTheRegistrarAsPayload() throws {
        let registrar = installCountingHost()

        let graphics = GraphicsContext()
        var path = Path()
        path.move(to: Point(x: 0, y: 0))
        path.addLine(to: Point(x: 10, y: 10))
        graphics.stroke(path)

        _ = try PaintRegistration.register(
            graphics.recording, width: 10, height: 10, in: Application.defaultContext)
        #expect(registrar.lastPayloadByteCount > 0, "payload reached the registrar")
    }

    // MARK: - The re-registration gate

    /// Publishing an unchanged view must not re-register its paint content.
    /// This is the regression the plan flagged as untested: recording-time
    /// handle minting would make every text-bearing recording unequal to the
    /// previous one and re-register on every publish.
    @Test func republishingAnUnchangedViewDoesNotReRegister() throws {
        let registrar = installCountingHost()
        let context = Application.defaultContext
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
        let registrar = installCountingHost()
        let context = Application.defaultContext
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
        let registrar = installCountingHost()
        let context = Application.defaultContext
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
}
