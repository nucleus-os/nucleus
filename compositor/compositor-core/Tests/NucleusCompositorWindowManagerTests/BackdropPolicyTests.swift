import Testing
import NucleusTypes
import NucleusCompositorServerTypes
import NucleusLayers
@testable import NucleusCompositorWindowManager

@MainActor
@Suite struct BackdropPolicyTests {

    // MARK: - clip(frame:subtracting:)

    @Test func clipReturnsFrameWhenNoOccluders() {
        let frame = BackdropPolicy.Rect(x: 0, y: 0, width: 100, height: 100)
        let clipped = BackdropPolicy.clip(frame: frame, subtracting: [])
        #expect(clipped == frame)
    }

    @Test func clipReturnsNilWhenFullyOccluded() {
        let frame = BackdropPolicy.Rect(x: 0, y: 0, width: 100, height: 100)
        let occluder = BackdropPolicy.Rect(x: -10, y: -10, width: 200, height: 200)
        #expect(BackdropPolicy.clip(frame: frame, subtracting: [occluder]) == nil)
    }

    @Test func clipReturnsBoundingBoxOnPartialOcclusion() {
        let frame = BackdropPolicy.Rect(x: 0, y: 0, width: 100, height: 100)
        // Occlude the right half: remaining is x=0..50.
        let occluder = BackdropPolicy.Rect(x: 50, y: 0, width: 50, height: 100)
        let clipped = BackdropPolicy.clip(frame: frame, subtracting: [occluder])
        #expect(clipped == BackdropPolicy.Rect(x: 0, y: 0, width: 50, height: 100))
    }

    @Test func clipIgnoresEmptyOccluders() {
        let frame = BackdropPolicy.Rect(x: 0, y: 0, width: 100, height: 100)
        let zero = BackdropPolicy.Rect(x: 10, y: 10, width: 0, height: 50)
        #expect(BackdropPolicy.clip(frame: frame, subtracting: [zero]) == frame)
    }

    // MARK: - resolveState

    @Test func followsWindowActiveStateBecomesActiveForKeyWindow() {
        let resolved = BackdropPolicy.resolveState(
            requested: .followsWindowActiveState,
            owningWindowID: 42,
            keyWindowID: 42
        )
        #expect(resolved == .active)
    }

    @Test func followsWindowActiveStateBecomesInactiveForNonKeyWindow() {
        let resolved = BackdropPolicy.resolveState(
            requested: .followsWindowActiveState,
            owningWindowID: 1,
            keyWindowID: 2
        )
        #expect(resolved == .inactive)
    }

    @Test func followsWindowActiveStateBecomesInactiveWhenNoOwner() {
        let resolved = BackdropPolicy.resolveState(
            requested: .followsWindowActiveState,
            owningWindowID: nil,
            keyWindowID: 1
        )
        #expect(resolved == .inactive)
    }

    @Test func explicitStatePassesThrough() {
        #expect(BackdropPolicy.resolveState(requested: .active, owningWindowID: 1, keyWindowID: 2) == .active)
        #expect(BackdropPolicy.resolveState(requested: .inactive, owningWindowID: 1, keyWindowID: 1) == .inactive)
    }

    // MARK: - resolveGroup

    @Test func producerGroupIDIsHonoredWhenNonZero() {
        let group = BackdropPolicy.resolveGroup(
            material: .popover,
            producerGroupID: 0xCAFEBABE,
            owningWindowID: 1,
            layerID: 99
        )
        #expect(group == 0xCAFEBABE)
    }

    @Test func titlebarLayersInSameWindowShareGroup() {
        let a = BackdropPolicy.resolveGroup(material: .titlebar, producerGroupID: 0, owningWindowID: 42, layerID: 1)
        let b = BackdropPolicy.resolveGroup(material: .titlebar, producerGroupID: 0, owningWindowID: 42, layerID: 2)
        #expect(a == b)
    }

    @Test func titlebarLayersInDifferentWindowsDoNotShareGroup() {
        let a = BackdropPolicy.resolveGroup(material: .titlebar, producerGroupID: 0, owningWindowID: 1, layerID: 1)
        let b = BackdropPolicy.resolveGroup(material: .titlebar, producerGroupID: 0, owningWindowID: 2, layerID: 2)
        #expect(a != b)
    }

    @Test func popoverLayersDoNotShareGroupByDefault() {
        let a = BackdropPolicy.resolveGroup(material: .popover, producerGroupID: 0, owningWindowID: 1, layerID: 1)
        let b = BackdropPolicy.resolveGroup(material: .popover, producerGroupID: 0, owningWindowID: 1, layerID: 2)
        #expect(a != b)
    }

    // MARK: - resolve (end-to-end)

    @Test func fullyOccludedBackdropsAreOmitted() {
        let lower = BackdropPolicy.LayerInput(
            layerID: 1,
            frame: .init(x: 0, y: 0, width: 100, height: 100),
            material: .popover
        )
        let upper = BackdropPolicy.LayerInput(
            layerID: 2,
            frame: .init(x: 0, y: 0, width: 200, height: 200),
            material: .none,
            isOpaqueOccluder: true
        )
        let draws = BackdropPolicy.resolve(layers: [lower, upper], keyWindowID: nil)
        #expect(draws.isEmpty)
    }

    @Test func partiallyOccludedBackdropClipsRegion() {
        let lower = BackdropPolicy.LayerInput(
            layerID: 1,
            frame: .init(x: 0, y: 0, width: 100, height: 100),
            material: .popover
        )
        let upper = BackdropPolicy.LayerInput(
            layerID: 2,
            frame: .init(x: 50, y: 0, width: 50, height: 100),
            material: .none,
            isOpaqueOccluder: true
        )
        let draws = BackdropPolicy.resolve(layers: [lower, upper], keyWindowID: nil)
        #expect(draws.count == 1)
        #expect(draws[0].layerID == 1)
        #expect(draws[0].region == .init(x: 0, y: 0, width: 50, height: 100))
    }

    @Test func resolveAppliesStatePropagation() {
        let input = BackdropPolicy.LayerInput(
            layerID: 1,
            frame: .init(x: 0, y: 0, width: 50, height: 50),
            material: .windowBackground,
            requestedState: .followsWindowActiveState,
            owningWindowID: 7
        )
        let activeDraws = BackdropPolicy.resolve(layers: [input], keyWindowID: 7)
        let inactiveDraws = BackdropPolicy.resolve(layers: [input], keyWindowID: 99)
        #expect(activeDraws.first?.resolvedState == .active)
        #expect(inactiveDraws.first?.resolvedState == .inactive)
    }

    @Test func resolveSharesTitlebarGroupAcrossSiblingsInSameWindow() {
        let a = BackdropPolicy.LayerInput(
            layerID: 11,
            frame: .init(x: 0, y: 0, width: 100, height: 20),
            material: .titlebar,
            owningWindowID: 1
        )
        let b = BackdropPolicy.LayerInput(
            layerID: 12,
            frame: .init(x: 100, y: 0, width: 100, height: 20),
            material: .titlebar,
            owningWindowID: 1
        )
        let draws = BackdropPolicy.resolve(layers: [a, b], keyWindowID: 1)
        #expect(draws.count == 2)
        #expect(draws[0].groupID == draws[1].groupID)
    }

    @Test func reduceTransparencyKeepsSpatialDrawForSolidFallback() {
        let input = BackdropPolicy.LayerInput(
            layerID: 1,
            frame: .init(x: 0, y: 0, width: 50, height: 50),
            material: .popover
        )
        let draws = BackdropPolicy.resolve(
            layers: [input],
            keyWindowID: nil,
            accessibility: .init(reduceTransparency: true)
        )
        #expect(draws.count == 1)
    }

    @Test func nonBackdropLayersAreSkipped() {
        let none = BackdropPolicy.LayerInput(
            layerID: 1,
            frame: .init(x: 0, y: 0, width: 50, height: 50),
            material: .none
        )
        let draws = BackdropPolicy.resolve(layers: [none], keyWindowID: nil)
        #expect(draws.isEmpty)
    }

    @Test func explicitAppearancePassesThrough() {
        let input = BackdropPolicy.LayerInput(
            layerID: 1,
            frame: .init(x: 0, y: 0, width: 50, height: 50),
            material: .popover,
            appearance: .dark
        )
        let draws = BackdropPolicy.resolve(
            layers: [input],
            keyWindowID: nil,
            accessibility: .init(systemAppearance: .light)
        )
        #expect(draws.first?.resolvedAppearance == .dark)
    }

    @Test func autoAppearanceFollowsSystemDefault() {
        let input = BackdropPolicy.LayerInput(
            layerID: 1,
            frame: .init(x: 0, y: 0, width: 50, height: 50),
            material: .popover,
            appearance: .auto
        )
        let lightSystem = BackdropPolicy.resolve(
            layers: [input],
            keyWindowID: nil,
            accessibility: .init(systemAppearance: .light)
        )
        let darkSystem = BackdropPolicy.resolve(
            layers: [input],
            keyWindowID: nil,
            accessibility: .init(systemAppearance: .dark)
        )
        #expect(lightSystem.first?.resolvedAppearance == .light)
        #expect(darkSystem.first?.resolvedAppearance == .dark)
    }

    @Test func hostBackdropPolicyResolveReturnsDraws() throws {
        var input = WireBackdropLayerInput(
            layerId: 77,
            frameX: 10,
            frameY: 20,
            frameWidth: 30,
            frameHeight: 40,
            isOpaqueOccluder: false,
            reserved0: 0,
            reserved1: 0,
            reserved2: 0,
            producerGroupId: 0,
        )
        let draws = try WindowManager.shared.backdropPolicyResolve(
            inputs: &input,
            inputsLen: 1
        )

        #expect(draws.count == 1)
        let draw = try #require(draws.first)
        #expect(draw.layerId == 77)
        #expect(draw.regionX == 10)
        #expect(draw.regionY == 20)
        #expect(draw.regionWidth == 30)
        #expect(draw.regionHeight == 40)
        #expect(draw.resolvedAppearance == BackdropPolicy.ResolvedAppearance.light.rawValue)
    }
}
