import Testing
@testable import NucleusRenderer
import NucleusRenderModel

// per-layer geometry (world matrix / clip / visible rect / combined opacity),
// remote-host inline resolution + damage fact, the damage-fact lowering family,
// native/external tracking gates, and the visual-state signatures.
// Hardware-independent.
@Suite struct PresentationSceneTests {
    static func approxD(_ a: Double, _ b: Double, _ eps: Double = 1e-4) -> Bool { abs(a - b) <= eps }

    static func target() -> RenderTarget {
        RenderTarget(
            outputId: 1, logicalRect: LogicalRect(x: 0, y: 0, width: 200, height: 200),
            pixelSize: PixelSize(width: 400, height: 400), scale: 1, fractionalScale: 2,
            overlayUsableArea: UsableArea(x: 0, y: 0, w: 200, h: 200))
    }

    static func dockLayer() -> Layer {
        var layer = Layer(id: 1, kind: .container)
        layer.role = .dock
        layer.model.properties.bounds = Bounds(w: 100, h: 50)
        return layer
    }

    @Test func lowerLayerInputGeometry() {
        // world geometry + combined opacity.
        var layer = Layer(id: 1, kind: .container)
        layer.model.properties.position = Point2D(x: 10, y: 20)
        layer.model.properties.bounds = Bounds(w: 100, h: 50)
        layer.model.properties.opacity = 0.5
        let input = lowerLayerInput(layerId: 1, layer: layer, parentMatrix: M44.identity,
                                    parentOpacity: 0.8, parentClip: .none,
                                    layerOpacity: layer.effectiveOpacity())!
        #expect(Self.approxD(input.layerRect.x, 10) && Self.approxD(input.layerRect.y, 20), "input-rect-origin")
        #expect(Self.approxD(input.layerRect.width, 100) && Self.approxD(input.layerRect.height, 50), "input-rect-size")
        #expect(abs(input.combinedOpacity - 0.4) < 1e-5, "input-combined-opacity")
        #expect(input.visibleRect != nil, "input-visible")
    }

    @Test func fullyClippedLayerNil() {
        let layer = Layer(id: 1, kind: .container)
        #expect(lowerLayerInput(layerId: 1, layer: layer, parentMatrix: M44.identity,
                                parentOpacity: 1, parentClip: .empty, layerOpacity: 1) == nil, "input-clipped-nil")
    }

    @Test func remoteHostInlineResolution() {
        var layer = Layer(id: 5, kind: .remoteHost(ContextID(raw: 9)))
        layer.model.properties.bounds = Bounds(w: 100, h: 100)
        let input = lowerLayerInput(layerId: 5, layer: layer, parentMatrix: M44.identity,
                                    parentOpacity: 1, parentClip: .none, layerOpacity: 1)!
        let geom = HostedContextGeometry(rootLayerId: 77, sourceRect: Rect(x: 0, y: 0, w: 100, h: 100))
        guard case .inlineSubtree(let inlineHost) = lowerRemoteHost(input, geom, destinationPassRequired: true)! else {
            #expect(Bool(false), "remote-inline"); return
        }
        #expect(inlineHost.rootLayerId == 77 && inlineHost.destinationPassRequired, "remote-inline")
        if case .rect(let rc) = inlineHost.clip {
            #expect(Self.approxD(rc.rect.width, 100) && Self.approxD(rc.rect.height, 100), "remote-clip")
        } else { #expect(Bool(false), "remote-clip") }

        let fact = lowerRemoteHostDamageFact(Self.target(), input, hostContextId: ContextID(raw: 9),
                                             geom, contextRevision: 3)!
        #expect(fact.hostLayerId == 5 && fact.rootLayerId == 77 && fact.contextRevision == 3, "remote-fact")
        #expect(fact.visibleRect == PhysicalRect(x: 0, y: 0, width: 200, height: 200), "remote-fact-rect")
    }

    @Test func damageFactLowering() {
        // remote host vs native vs nothing.
        var rh = Layer(id: 5, kind: .remoteHost(ContextID(raw: 9)))
        rh.model.properties.bounds = Bounds(w: 100, h: 100)
        let rhInput = lowerLayerInput(layerId: 5, layer: rh, parentMatrix: M44.identity,
                                      parentOpacity: 1, parentClip: .none, layerOpacity: 1)!
        let hosted = RemoteHostDamageInput(
            hostContextId: ContextID(raw: 9),
            geometry: HostedContextGeometry(rootLayerId: 77, sourceRect: Rect(x: 0, y: 0, w: 100, h: 100)),
            contextRevision: 1)
        let rhFacts = lowerLayerDamageFacts(Self.target(), rhInput, remoteHost: hosted)
        #expect(rhFacts.remoteHost != nil && !rhFacts.descendChildren, "facts-remote")

        let dock = Self.dockLayer()
        let dockInput = lowerLayerInput(layerId: 1, layer: dock, parentMatrix: M44.identity,
                                        parentOpacity: 1, parentClip: .none, layerOpacity: 1)!
        let dockFacts = lowerLayerDamageFacts(Self.target(), dockInput, remoteHost: nil)
        #expect(dockFacts.nativeLayer != nil && dockFacts.descendChildren, "facts-native")

        let generic = Layer(id: 2, kind: .container)
        let gInput = lowerLayerInput(layerId: 2, layer: generic, parentMatrix: M44.identity,
                                     parentOpacity: 1, parentClip: .none, layerOpacity: 1)!
        let gFacts = lowerLayerDamageFacts(Self.target(), gInput, remoteHost: nil)
        #expect(gFacts.nativeLayer == nil && gFacts.external == nil, "facts-none")
    }

    @Test func externalDamageFact() {
        var layer = Layer(id: 3, kind: .container)
        layer.model.properties.bounds = Bounds(w: 100, h: 100)
        layer.presentation.content = .external(IOSurfaceID(raw: 5))
        let input = lowerLayerInput(layerId: 3, layer: layer, parentMatrix: M44.identity,
                                    parentOpacity: 1, parentClip: .none, layerOpacity: 1)!
        let fact = lowerExternalDamageFact(Self.target(), input)!
        if case .compositorExternal = fact.source { #expect(true, "external-source") }
        else { #expect(Bool(false), "external-source") }
        // A non-external layer yields no external fact.
        #expect(lowerExternalDamageFact(Self.target(), lowerLayerInput(
            layerId: 4, layer: Layer(id: 4, kind: .container), parentMatrix: M44.identity,
            parentOpacity: 1, parentClip: .none, layerOpacity: 1)!) == nil, "external-none")
    }

    @Test func nativeTrackingGateByRole() {
        #expect(shouldTrackNativeLayerDamage(Self.dockLayer()), "track-dock")
        var notif = Layer(id: 1, kind: .container); notif.role = .notification
        #expect(shouldTrackNativeLayerDamage(notif), "track-notification")
        #expect(!shouldTrackNativeLayerDamage(Layer(id: 1, kind: .container)), "track-generic-no")
    }

    @Test func visualStateSignatures() {
        let dock = Self.dockLayer()
        let input = lowerLayerInput(layerId: 1, layer: dock, parentMatrix: M44.identity,
                                    parentOpacity: 1, parentClip: .none, layerOpacity: 1)!
        let sigA = nativeLayerVisualSignature(input.layer, input.combinedOpacity)
        let sigA2 = nativeLayerVisualSignature(input.layer, input.combinedOpacity)
        #expect(sigA == sigA2, "sig-stable")
        var changed = dock
        changed.model.visualRevision = 99
        #expect(nativeLayerVisualSignature(changed, input.combinedOpacity) != sigA, "sig-changes")

        // Remote-host signature: stable, opacity-sensitive.
        let r1 = remoteHostSignature(ContextID(raw: 9), M44.identity, 1.0)
        #expect(r1 == remoteHostSignature(ContextID(raw: 9), M44.identity, 1.0), "remote-sig-stable")
        #expect(r1 != remoteHostSignature(ContextID(raw: 9), M44.identity, 0.5), "remote-sig-opacity")
    }

    @Test func outputScaleGenerationAndBackdropIds() {
        let g1 = outputScaleGeneration(Self.target())
        var t2 = Self.target(); t2.pixelSize = PixelSize(width: 800, height: 400)
        #expect(g1 != outputScaleGeneration(t2), "scale-gen-changes")
        let id1 = surfaceBackdropLayerId(5, .waylandSurface, 0)
        let id2 = surfaceBackdropLayerId(5, .kdeSurface, 0)
        #expect(id1 != 0 && id2 != 0 && id1 != id2, "backdrop-id-distinct")
    }
}
