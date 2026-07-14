import Testing
@testable import NucleusRenderer
import NucleusRenderModel

// Converted from PresentationWalkFixture (Phase 10b.4j): walk a constructed
// Phase 8 LayerTree into a complete FramePlan and assert the renderer-coupled
// emission — a backdrop ExecSpec, the resolved content TextureQuads (with
// rounded-clip mask + opacity + the foreground-vibrancy reference to the ancestor
// backdrop group), and a decoration shadow — plus the geometry projection. Pure
// Swift; the GPU render of the plan is covered by the NucleusRenderer suite.
@Suite struct PresentationWalkTests {
    static func layer(_ id: UInt64, kind: LayerKind = .container,
                      x: Float, y: Float, w: Float, h: Float, opacity: Float = 1) -> Layer {
        var l = Layer(id: id, kind: kind)
        l.model.properties.position = Point2D(x: x, y: y)
        l.model.properties.bounds = Bounds(w: w, h: h)
        l.model.properties.anchorPoint = Point2D(x: 0, y: 0)
        l.model.properties.opacity = opacity
        return l
    }

    @Test func walkLayerTreeIntoFramePlan() {
        var tree = LayerTree()

        // Root 1: a backdrop-bearing container (200×200), with an external-content
        // child (100×100) that opts into light vibrancy.
        var backdropRoot = Self.layer(1, x: 0, y: 0, w: 200, h: 200)
        backdropRoot.backdropAttachment = BackdropAttachment(
            materialRole: .default, blendingMode: .behindWindow, state: .active,
            appearance: .auto, emphasized: false, mask: .none, shape: .rect((0, 0, 200, 200)))
        backdropRoot.children = [2]
        tree.insertLayer(backdropRoot)

        var contentChild = Self.layer(2, x: 10, y: 10, w: 100, h: 100)
        contentChild.presentation.content = .external(IOSurfaceID(raw: 5))
        contentChild.presentation.contentSample = ContentSample(
            sourceSurfaceId: 2, srcOrigin: (4, 8), srcSize: (200, 200),
            logicalSize: Bounds(w: 100, h: 100), opaqueFullSurface: true)
        contentChild.foregroundVibrancy = .light
        tree.insertLayer(contentChild)

        // Root 3: paint content with rounded corners → masked texture quad.
        var painted = Self.layer(3, x: 120, y: 20, w: 80, h: 80)
        painted.presentation.content = .paint(PaintContentHandle(raw: 9))
        painted.model.visualStyle = VisualStyle(
            backgroundColor: (0.1, 0.2, 0.3, 0.8),
            borderTop: BorderEdge(width: 1, color: (1, 0, 0, 1)),
            borderRight: BorderEdge(width: 2, color: (0, 1, 0, 1)),
            borderBottom: BorderEdge(width: 3, color: (0, 0, 1, 1)),
            borderLeft: BorderEdge(width: 4, color: (1, 1, 0, 1)),
            cornerRadii: (16, 12, 8, 4))
        tree.insertLayer(painted)

        // Root 4: a shadow decoration, no content.
        var shadowed = Self.layer(4, x: 10, y: 120, w: 60, h: 60)
        shadowed.model.visualStyle = VisualStyle(shadow: LayerShadow(
            offsetX: 0, offsetY: 4, blurRadius: 8, spreadRadius: 0,
            color: (0, 0, 0, 0.5)))
        shadowed.model.visualRevision = 7
        tree.insertLayer(shadowed)

        // Root 5: a pure structural container — contributes nothing.
        tree.insertLayer(Self.layer(5, x: 130, y: 130, w: 50, h: 50))

        // Root 6: a remote-host portal. It targets context 9, whose root has
        // content and itself hosts context 10. Neither context 9 nor 10 is a
        // compositor root; their layers render only through the remote hosts.
        tree.insertLayer(Self.layer(6, kind: .remoteHost(ContextID(raw: 9)), x: 30, y: 40, w: 0, h: 0))

        var hostedRoot = Self.layer(20, x: 5, y: 5, w: 20, h: 20)
        hostedRoot.presentation.content = .external(IOSurfaceID(raw: 17))
        hostedRoot.children = [21]
        tree.insertLayer(hostedRoot)
        tree.insertLayer(Self.layer(21, kind: .remoteHost(ContextID(raw: 10)), x: 40, y: 0, w: 0, h: 0))

        var nestedRoot = Self.layer(30, x: 0, y: 0, w: 10, h: 10)
        nestedRoot.presentation.content = .paint(PaintContentHandle(raw: 31))
        tree.insertLayer(nestedRoot)

        tree.contextRoots[compositorContextId] = [1, 3, 4, 5, 6]
        tree.contextRoots[ContextID(raw: 9)] = [20]
        tree.contextRoots[ContextID(raw: 10)] = [30]

        let target = RenderTarget(
            outputId: 1,
            logicalRect: LogicalRect(x: 0, y: 0, width: 200, height: 200),
            pixelSize: PixelSize(width: 400, height: 400),
            scale: 1, fractionalScale: 2, overlayUsableArea: UsableArea())

        let plan = PresentationWalk.buildFramePlan(tree: tree, target: target, frame: FrameInfo(outputId: 1))

        // Backdrop is an inline command at the backdrop layer's exact z position.
        #expect(plan.backdropDrawCount() == 1, "walk-backdrop-count")
        let backdrop = plan.ops.compactMap { op -> ExecSpec? in
            if case .backdrop(let command) = op { return command }
            return nil
        }.first
        #expect(backdrop?.groupId == 1, "walk-backdrop-group")

        // Content: four textured quads (external + paint + hosted external +
        // nested hosted paint); the pure container emits nothing and the shadow
        // layer emits no content.
        #expect(plan.counters.textureQuads == 4, "walk-texture-quad-count")
        #expect(plan.counters.shadowQuads == 1, "walk-shadow-quad-count")
        #expect(plan.counters.fillQuads == 1, "walk-visual-style-count")

        // op[0] = external content of layer 2, projected (10,10,100,100)→(20,20,200,200),
        // carrying a foreground-vibrancy reference to the ancestor backdrop group.
        let external = plan.ops.compactMap { op -> TextureQuad? in
            if case .textureQuad(let q) = op, q.layerId == 2 { return q }
            return nil
        }.first
        if let q = external {
            #expect(q.layerId == 2 && q.role == .content, "walk-external-content")
            #expect(q.dst == PlanRect(x: 20, y: 20, w: 200, h: 200), "walk-content-projection")
            #expect(q.src == PlanRect(x: 4, y: 8, w: 200, h: 200), "walk-content-sample")
            #expect(q.opaqueRect == q.dst, "walk-opaque-coverage")
            #expect(q.foregroundVibrancy?.backdropGroupId == 1, "walk-vibrancy-group")
            #expect(q.foregroundVibrancy?.variant == .light, "walk-vibrancy-variant")
            #expect(q.maskRRect == nil, "walk-content-no-mask")
        } else {
            #expect(Bool(false), "walk-op0-texture")
        }

        // op[1] = paint content of layer 3 with a rounded-clip mask (radii × scale).
        let paintedContent = plan.ops.compactMap { op -> TextureQuad? in
            if case .textureQuad(let q) = op, q.layerId == 3 { return q }
            return nil
        }.first
        if let q = paintedContent {
            #expect(q.layerId == 3 && q.role == .paint, "walk-paint-content")
            #expect(q.maskRRect != nil, "walk-paint-mask")
            #expect(q.maskRRect?.radii.0 == 32 && q.maskRRect?.radii.3 == 8,
                    "walk-paint-mask-radii-scaled")
            #expect(q.foregroundVibrancy == nil, "walk-paint-no-vibrancy")
        } else {
            #expect(Bool(false), "walk-op1-texture")
        }

        let visualStyle = plan.ops.compactMap { op -> VisualStyleQuad? in
            if case .visualStyle(let q) = op { return q }
            return nil
        }.first
        #expect(visualStyle?.dst == PlanRect(x: 240, y: 40, w: 160, h: 160),
                "walk-style-projection")
        #expect(visualStyle.map { float4Equal($0.borderWidths, (2, 4, 6, 8)) } == true,
                "walk-style-border-widths-scaled")
        #expect(visualStyle.map { float4Equal($0.cornerRadii, (32, 24, 16, 8)) } == true,
                "walk-style-radii-scaled")
        #expect(visualStyle?.backgroundColor.3 == 0.8, "walk-style-background")

        // The shadow decoration of layer 4. At 2×, blurRadius 8 →
        // sigma 8 physical pixels, padded by 3σ=24 on every side.
        let shadow = plan.ops.compactMap { op -> ShadowQuad? in
            if case .shadowQuad(let q) = op { return q }
            return nil
        }.first
        if let q = shadow {
            #expect(q.dst == PlanRect(x: -4, y: 224, w: 168, h: 168), "walk-shadow-padded-destination")
            #expect(q.src == PlanRect(x: 0, y: 0, w: 168, h: 168), "walk-shadow-full-raster-source")
            #expect(q.material?.layerId == 4 && q.material?.revision == 7, "walk-shadow-cache-identity")
            #expect(q.material?.shapeRect == PlanRect(x: 24, y: 24, w: 120, h: 120), "walk-shadow-shape-inset")
            #expect(q.material?.blurSigma == 8, "walk-shadow-scaled-sigma")
            #expect(q.material?.color.3 == 0.5, "walk-shadow-material-alpha")
        } else {
            #expect(Bool(false), "walk-op2-shadow")
        }

        let hosted = plan.ops.compactMap { op -> TextureQuad? in
            if case .textureQuad(let q) = op, q.layerId == 20 { return q }
            return nil
        }.first
        #expect(hosted?.role == .content && hosted?.texture == TextureHandle(raw: 17), "walk-remote-host-content")
        #expect(hosted?.dst == PlanRect(x: 70, y: 90, w: 40, h: 40), "walk-remote-host-projection")

        let nested = plan.ops.compactMap { op -> TextureQuad? in
            if case .textureQuad(let q) = op, q.layerId == 30 { return q }
            return nil
        }.first
        #expect(nested?.role == .paint && nested?.texture == TextureHandle(raw: 31), "walk-nested-remote-host-content")
        #expect(nested?.dst == PlanRect(x: 150, y: 90, w: 20, h: 20), "walk-nested-remote-host-projection")
    }
}
