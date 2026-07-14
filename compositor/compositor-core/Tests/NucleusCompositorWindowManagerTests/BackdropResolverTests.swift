import Testing
import NucleusLayers
@testable import NucleusCompositorWindowManager

@MainActor
@Suite struct BackdropResolverTests {
    private let producers = BackdropCatalog.Producers(
        defaultMaterial: .init(offset: 3, noise: 0.02, saturation: 1.5),
        waylandMaterial: .init(offset: 2.5, noise: 0.01, saturation: 1.4),
        shellOverlayMaterial: .init(offset: 4, noise: 0.03, saturation: 1.6,
                                    tint: SIMD4(0.1, 0.2, 0.3, 0.4))
    )

    @Test func catalogSelectsProducerByRole() {
        let defaultRow = BackdropCatalog.resolve(
            key: .init(role: .default, appearance: .light, reduceTransparency: false,
                       increaseContrast: false, state: .active, emphasized: false),
            producers: producers)
        let contentRow = BackdropCatalog.resolve(
            key: .init(role: .contentBackground, appearance: .light, reduceTransparency: false,
                       increaseContrast: false, state: .active, emphasized: false),
            producers: producers)
        let overlayRow = BackdropCatalog.resolve(
            key: .init(role: .popover, appearance: .dark, reduceTransparency: false,
                       increaseContrast: false, state: .active, emphasized: false),
            producers: producers)
        #expect(defaultRow.offset == 3)
        #expect(contentRow.offset == 2.5)
        #expect(overlayRow.offset == 4)
        #expect(overlayRow.foregroundVariant == .dark)
    }

    @Test func accessibilityResolvesExactlyOnceIntoMaterial() {
        let contrast = BackdropCatalog.resolve(
            key: .init(role: .popover, appearance: .light, reduceTransparency: false,
                       increaseContrast: true, state: .active, emphasized: false),
            producers: producers)
        #expect(contrast.saturation == 2)
        #expect(contrast.tint.w == 0.6)

        let reduced = BackdropCatalog.resolve(
            key: .init(role: .popover, appearance: .dark, reduceTransparency: true,
                       increaseContrast: true, state: .active, emphasized: false),
            producers: producers)
        #expect(!reduced.enabled)
        #expect(reduced.offset == 0)
        #expect(reduced.solidFallback.x == 0.18)
    }

    @Test func intensityCurveMatchesMigratedDefaults() {
        let expected: [(Float, Float)] = [
            (0, 0), (0.2, 2.352), (0.4, 2.55), (0.6, 2.775), (0.8, 3), (1, 3.75),
        ]
        for (intensity, offset) in expected {
            var settings = BackdropDynamics.Settings()
            settings.intensity = intensity
            settings.enabled = intensity > 0
            #expect(abs(BackdropDynamics.resolveDefault(settings).offset - offset) < 0.001)
        }
        var firstSettings = BackdropDynamics.Settings()
        firstSettings.intensity = 0.2
        let first = BackdropDynamics.resolveDefault(firstSettings)
        #expect(abs(first.noise - 0.00655) < 0.0001)
        #expect(abs(first.saturation - 1.16375) < 0.001)

        let standard = BackdropDynamics.resolveDefault(.init())
        #expect(standard.passes == 3)
        #expect(standard.offset == 3)
        #expect(standard.noise == 0.02)
        #expect(standard.saturation == 1.5)
    }

    @Test func presentationAnimationUsesFrameClockAndSmoothstep() {
        var dynamics = BackdropDynamics()
        let setInitial = dynamics.setIntensity(0.2, policy: .immediate)
        #expect(setInitial)
        let setTarget = dynamics.setIntensity(0.4, policy: .animate)
        #expect(setTarget)
        let start = dynamics.resolve(frameTime: 10).defaultMaterial
        let next = dynamics.resolve(frameTime: 10 + 1.0 / 60.0).defaultMaterial
        let target = BackdropDynamics.resolveDefault(dynamics.target)
        #expect(next.offset > start.offset)
        #expect(next.offset < target.offset)
        _ = dynamics.resolve(frameTime: 10.25)
        #expect(!dynamics.hasActiveAnimation)
    }

    @Test func advancedControlsInterpolateWithoutTopologySwitching() {
        var dynamics = BackdropDynamics()
        var target = BackdropDynamics.Settings()
        target.mode = .advanced
        target.advanced.offset = 6
        target.advanced.noise = 0.08
        target.advanced.saturation = 2
        target.advanced.alpha = 0.5
        target.advanced.tint = SIMD4(0.2, 0.3, 0.4, 0.6)
        let applied = dynamics.apply(target, policy: .animate)
        #expect(applied)
        _ = dynamics.resolve(frameTime: 20)
        let intermediate = dynamics.resolve(frameTime: 20.11).defaultMaterial
        #expect(intermediate.offset > 3 && intermediate.offset < 6)
        #expect(intermediate.noise > 0.02 && intermediate.noise < 0.08)
        #expect(intermediate.saturation > 1.5 && intermediate.saturation < 2)
        #expect(intermediate.tint.w > 0 && intermediate.tint.w < 0.6)
    }

    @Test func resolverRetainsStateAndAppearanceForSpatialPass() {
        let resolver = BackdropResolver()
        let records = resolver.resolveBackdrops(
            identities: [.init(layerID: 7, material: .titlebar,
                               requestedState: .followsWindowActiveState, appearance: .auto,
                               isEmphasized: true, owningWindowID: 42, tint: .zero, opacity: 1)],
            keyWindowID: 42,
            accessibility: .init(systemAppearance: .dark),
            increaseContrast: false,
            frameTime: 1
        )
        #expect(records.first?.material.resolvedState == .active)
        #expect(records.first?.material.resolvedAppearance == .dark)
        let draws = resolver.resolveSpatial(geometries: [
            .init(layerID: 7, frame: .init(x: 0, y: 0, width: 100, height: 40),
                  isOpaqueOccluder: false, producerGroupID: 0),
        ])
        #expect(draws.first?.resolvedState == .active)
        #expect(draws.first?.resolvedAppearance == .dark)
    }
}
