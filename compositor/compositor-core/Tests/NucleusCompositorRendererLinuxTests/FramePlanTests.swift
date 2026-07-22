import Testing
@testable import NucleusRenderer
import NucleusRenderModel

// ops, counters, inline backdrop commands, capacity-retaining reset, scanout/
// callbacks) and the pure plan-command lowering (textured quad native vs fill
// sizing, source-rect basis, opaque coverage, rounded clip mask).
// Hardware-independent.
@Suite struct FramePlanTests {
    static func target() -> RenderTarget {
        RenderTarget(
            outputId: 1, logicalRect: LogicalRect(x: 0, y: 0, width: 200, height: 200),
            pixelSize: PixelSize(width: 400, height: 400), scale: 1, fractionalScale: 2,
            overlayUsableArea: UsableArea())
    }

    static func input(layerRect: LogicalRect, bounds: Bounds, clip: ClipState = .none) -> LayerInput {
        LayerInput(layerId: 1, layer: Layer(id: 1, kind: .container), bounds: bounds,
                   parentMatrix: M44.identity, worldMatrix: M44.identity, clip: clip,
                   layerRect: layerRect, visibleRect: layerRect, combinedOpacity: 1)
    }

    @Test func planContainerOps() {
        let plan = FramePlan()
        plan.appendTextureQuad(TextureQuad(texture: TextureHandle(raw: 1),
                                           dst: PlanRect(x: 0, y: 0, w: 10, h: 10),
                                           src: PlanRect(x: 0, y: 0, w: 10, h: 10), alpha: 1))
        plan.appendFillQuad(FillQuad(dst: PlanRect(x: 0, y: 0, w: 5, h: 5), color: (1, 0, 0, 1)))
        #expect(plan.ops.count == 2, "ops-count")
        #expect(plan.counters.textureQuads == 1 && plan.counters.fillQuads == 1, "counters")
        if case .textureQuad = plan.ops[0] { #expect(true, "op-order") } else { #expect(Bool(false), "op-order") }
    }

    @Test func appendDamageRectSkipsZeroArea() {
        let plan = FramePlan()
        plan.appendDamageRect(PlanRect(x: 0, y: 0, w: 0, h: 10))
        plan.appendDamageRect(PlanRect(x: 0, y: 0, w: 10, h: 10))
        #expect(plan.damageRects.count == 1 && plan.counters.damageRects == 1, "damage-skip-zero")
    }

    @Test func backdropCommandsPreserveInsertionOrder() {
        let plan = FramePlan()
        func spec(_ layer: UInt64, z: Int32) -> ExecSpec {
            ExecSpec(layerId: layer, zBand: z, groupId: 1, region: PlanRect(x: 0, y: 0, w: 10, h: 10),
                     shape: .rect((0, 0, 10, 10)), mask: .none)
        }
        plan.appendBackdropExecSpec(spec(5, z: 4))
        plan.appendBackdropExecSpec(spec(6, z: 2))
        plan.appendBackdropExecSpec(spec(7, z: 4))
        let backdropLayers = plan.ops.compactMap { op -> UInt64? in
            if case .backdrop(let command) = op { return command.layerId }
            return nil
        }
        #expect(backdropLayers == [5, 6, 7], "backdrop-insertion-order")
        #expect(plan.backdropDrawCount() == 3, "backdrop-draw-count")
    }

    @Test func backdropRemainsBetweenUnderlyingContentAndChrome() {
        let plan = FramePlan()
        plan.appendFillQuad(FillQuad(
            dst: PlanRect(x: 0, y: 0, w: 100, h: 100), color: (0, 0, 0, 1)))
        plan.appendBackdropExecSpec(ExecSpec(
            layerId: 2, groupId: 1,
            region: PlanRect(x: 0, y: 0, w: 100, h: 40),
            shape: .rect((0, 0, 100, 40)), mask: .none))
        plan.appendTextureQuad(TextureQuad(
            layerId: 3, role: .paint, texture: TextureHandle(raw: 9),
            dst: PlanRect(x: 8, y: 8, w: 72, h: 28),
            src: PlanRect(x: 0, y: 0, w: 108, h: 42), alpha: 1))
        #expect(plan.ops.count == 3)
        if case .fillQuad = plan.ops[0] {} else { #expect(Bool(false)) }
        if case .backdrop = plan.ops[1] {} else { #expect(Bool(false)) }
        if case .textureQuad = plan.ops[2] {} else { #expect(Bool(false)) }
    }

    @Test func opaqueCoverageCullsOnlyFullyHiddenDraws() {
        let plan = FramePlan()
        let rect = PlanRect(x: 0, y: 0, w: 100, h: 100)
        plan.appendTextureQuad(TextureQuad(
            layerId: 1, role: .content, texture: TextureHandle(raw: 1),
            dst: rect, src: rect, alpha: 1))
        plan.appendTextureQuad(TextureQuad(
            layerId: 2, role: .content, texture: TextureHandle(raw: 2),
            dst: rect, src: rect, alpha: 1, opaqueRect: rect))
        plan.cullOccludedOps()
        #expect(plan.ops.count == 1)
        if case .textureQuad(let quad) = plan.ops[0] {
            #expect(quad.layerId == 2)
        } else { #expect(Bool(false)) }

        let fractional = FramePlan()
        fractional.appendTextureQuad(TextureQuad(
            layerId: 1, role: .content, texture: TextureHandle(raw: 1),
            dst: PlanRect(x: 0, y: 0, w: 10, h: 10),
            src: rect, alpha: 1))
        fractional.appendTextureQuad(TextureQuad(
            layerId: 2, role: .content, texture: TextureHandle(raw: 2),
            dst: rect, src: rect, alpha: 1,
            opaqueRect: PlanRect(x: 0.2, y: 0.2, w: 9.6, h: 9.6)))
        fractional.cullOccludedOps()
        #expect(fractional.ops.count == 2, "inward opaque rounding must not over-cull")

        let rounded = FramePlan()
        rounded.appendTextureQuad(TextureQuad(
            layerId: 1, role: .content, texture: TextureHandle(raw: 1),
            dst: rect, src: rect, alpha: 1))
        rounded.appendFillQuad(FillQuad(
            dst: rect, color: (0, 0, 0, 1), blendMode: .src,
            maskRRect: RRectMask(rect: rect, radii: (8, 8, 8, 8))))
        rounded.cullOccludedOps()
        #expect(rounded.ops.count == 2, "rounded opaque draws do not cover their corner pixels")
    }

    @Test func resetRetainsCapacityClearsIdentity() {
        let plan = FramePlan()
        plan.appendTextureQuad(TextureQuad(texture: nil, dst: PlanRect(), src: PlanRect(), alpha: 1))
        plan.appendFrameCallback(42)
        plan.directScanout = DirectScanoutPlan(candidateLayerId: 3, eligible: true)
        plan.reset(FrameInfo(outputId: 7, planSerial: 11))
        #expect(plan.ops.isEmpty && plan.frameCallbacks.isEmpty, "reset-clears")
        #expect(plan.directScanout == nil && plan.frame.outputId == 7 && plan.frame.planSerial == 11, "reset-identity")
        #expect(plan.counters == PlanCounters(), "reset-counters")
    }

    @Test func frameCallbacks() {
        let plan = FramePlan()
        plan.appendFrameCallback(1); plan.appendFrameCallback(2)
        #expect(plan.frameCallbacks == [1, 2], "callbacks")
    }

    @Test func lowerTextureQuadNative() {
        // identity (native) mapping with a 2× buffer.
        let content = TextureContent(texture: TextureHandle(raw: 1), kind: .waylandExternal, role: .content,
                                     srcWidth: 200, srcHeight: 100, logicalSize: Bounds(w: 100, h: 50),
                                     opaqueFullSurface: true)
        let quad = lowerTextureQuad(Self.target(), Self.input(layerRect: LogicalRect(x: 0, y: 0, width: 100, height: 50),
                                                    bounds: Bounds(w: 100, h: 50)), content)!
        #expect(quad.dst == PlanRect(x: 0, y: 0, w: 200, h: 100), "native-dst")
        #expect(quad.src == PlanRect(x: 0, y: 0, w: 200, h: 100), "native-src")
        #expect(quad.opaqueRect == quad.dst, "native-opaque")
        #expect(quad.maskRRect == nil && quad.role == .content, "native-mask-role")
    }

    @Test func lowerTextureQuadScaled() {
        // a scaled layer fills its rect; source basis = rendered.
        let content = TextureContent(texture: TextureHandle(raw: 1), kind: .waylandExternal, role: .content,
                                     srcWidth: 200, srcHeight: 100, logicalSize: Bounds(w: 100, h: 50))
        let quad = lowerTextureQuad(Self.target(), Self.input(layerRect: LogicalRect(x: 0, y: 0, width: 200, height: 100),
                                                    bounds: Bounds(w: 100, h: 50)), content)!
        #expect(quad.dst == PlanRect(x: 0, y: 0, w: 400, h: 200), "scaled-dst")
        #expect(quad.src == PlanRect(x: 0, y: 0, w: 200, h: 100), "scaled-src")
        #expect(quad.opaqueRect == nil, "scaled-not-opaque")
    }

    @Test func roundedClipMaskEmission() {
        // rounded clip emits a physical mask; square clip nil.
        let rounded = ClipState.rect(RoundedClip(rect: LogicalRect(x: 0, y: 0, width: 100, height: 100),
                                                 radii: (8, 8, 8, 8)))
        let mask = roundedClipMask(Self.target(), rounded)!
        #expect(mask.rect == PlanRect(x: 0, y: 0, w: 200, h: 200), "mask-rect")
        #expect(float4Equal(mask.radii, (16, 16, 16, 16)), "mask-radii")
        let square = ClipState.rect(RoundedClip(rect: LogicalRect(x: 0, y: 0, width: 100, height: 100)))
        #expect(roundedClipMask(Self.target(), square) == nil, "mask-square-nil")
        #expect(roundedClipMask(Self.target(), .none) == nil, "mask-none-nil")
    }
}
