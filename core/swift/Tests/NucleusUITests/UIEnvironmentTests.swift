import Testing
@_spi(NucleusCompositor) @testable import NucleusLayers
@_spi(NucleusCompositor) @testable import NucleusUI

@MainActor
@Suite(.uiContext) struct UIEnvironmentTests {
    private final class EnvironmentProbe: View {
        let dependencies: UIEnvironmentChanges
        var received: [UIEnvironmentChanges] = []

        init(dependencies: UIEnvironmentChanges) {
            self.dependencies = dependencies
            super.init()
        }

        override var environmentDependencies: UIEnvironmentChanges {
            dependencies
        }

        override func environmentDidChange(
            _ changes: UIEnvironmentChanges
        ) {
            received.append(changes)
            super.environmentDidChange(changes)
        }
    }

    init() {
        installTestTextBackend()
    }

    private func withContext<T>(
        _ body: (UIContext) throws -> T
    ) throws -> T {
        let sink = InMemoryCommitSink()
        let visual = try Context(
            contextID: UInt32.random(in: 100...100_000),
            commitSink: sink)
        let semantic = UIContext(
            services: .inMemory(),
            runtimeHost: visual.runtimeHost)
        return try Application.withContexts(
            uiContext: semantic,
            visualContext: visual
        ) {
            try body(semantic)
        }
    }

    @Test func oneUpdateAppliesEveryEnvironmentPolicy() throws {
        try withContext { context in
            let label = Label("Readable")
            let effect = VisualEffectView(material: .popover)
            let motionProbe = EnvironmentProbe(
                dependencies: .reducedMotion)
            let appearanceProbe = EnvironmentProbe(
                dependencies: [.appearance, .increasedContrast])
            let originalSize = label.intrinsicContentSize
            let originalBackdrop = effect.resolvedBackdropMaterial()
            #expect(originalBackdrop != .none)

            context.updateEnvironment(UIEnvironment(
                reducesMotion: true,
                reducesTransparency: true,
                increasesContrast: true,
                appearance: .light,
                textScale: 2))

            #expect(context.environment.textScale == 2)
            #expect(label.intrinsicContentSize.width > originalSize.width)
            #expect(label.effectiveAppearance == .light)
            #expect(label.effectivePalette != Palette.light)
            #expect(effect.resolvedBackdropMaterial() == .none)
            #expect(effect.backgroundColor == effect.effectivePalette.surface)
            #expect(motionProbe.received == [.reducedMotion])
            #expect(appearanceProbe.received == [[
                .appearance, .increasedContrast,
            ]])

            let owner = EnvironmentProbe(dependencies: [])
            let handle = context.animateValue(
                owner: owner,
                property: AnimationPropertyKey(rawValue: "environment-test"),
                from: 0,
                to: 1,
                update: { _ in })
            #expect(handle.outcome == .skippedReducedMotion)
        }
    }

    @Test func irrelevantConsumersAreNotInvalidated() throws {
        try withContext { context in
            let textProbe = EnvironmentProbe(dependencies: .textScale)
            let transparencyProbe = EnvironmentProbe(
                dependencies: .reducedTransparency)

            context.updateEnvironment(UIEnvironment(reducesMotion: true))

            #expect(textProbe.received.isEmpty)
            #expect(transparencyProbe.received.isEmpty)
        }
    }

    @Test func unchangedSnapshotDoesNotInvalidateConsumers() throws {
        try withContext { context in
            let probe = EnvironmentProbe(dependencies: [
                .appearance, .increasedContrast, .reducedMotion,
                .reducedTransparency, .textScale,
            ])

            context.updateEnvironment(context.environment)

            #expect(probe.received.isEmpty)
        }
    }

    @Test func enablingReducedMotionSettlesActiveMotionScaledValues() throws {
        try withContext { context in
            let owner = EnvironmentProbe(dependencies: [])
            var value = 0.0
            let handle = context.animateValue(
                owner: owner,
                property: AnimationPropertyKey(
                    rawValue: "active-environment-test"),
                from: 0,
                to: 42,
                options: ValueAnimationOptions(
                    timing: AnimationTiming(duration: 10),
                    timeMode: .motionScaled),
                update: { value = $0 })

            context.updateEnvironment(UIEnvironment(reducesMotion: true))

            #expect(value == 42)
            #expect(handle.outcome == .skippedReducedMotion)
            #expect(!context.advanceAnimations(
                predictedPresentationNanoseconds: 1))
        }
    }

    @Test func initialEnvironmentExistsBeforeConstruction() {
        let context = UIContext(
            services: .inMemory(),
            environment: UIEnvironment(
                reducesMotion: true,
                appearance: .light,
                textScale: 1.5))

        let view = context.construct { Label("Initial") }

        #expect(view.effectiveAppearance == .light)
        #expect(context.environment.reducesMotion)
        #expect(context.environment.textScale == 1.5)
    }

    @Test func nestedConstructionScopesRestoreTheirOwningContext() {
        let outer = UIContext(services: .inMemory())
        let inner = UIContext(services: .inMemory())
        outer.updateEnvironment(UIEnvironment(appearance: .light))
        inner.updateEnvironment(UIEnvironment(appearance: .dark))

        let (first, nested, last) = outer.construct {
            let first = View()
            let nested = inner.construct { View() }
            let last = View()
            return (first, nested, last)
        }

        #expect(first.effectiveAppearance == .light)
        #expect(nested.effectiveAppearance == .dark)
        #expect(last.effectiveAppearance == .light)
        #expect(first.uiContext === outer)
        #expect(nested.uiContext === inner)
        #expect(last.uiContext === outer)
    }
}
