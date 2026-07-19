import Testing
import NucleusUI

/// The palette model: roles, specs, and the repaint path a retheme needs.
@Suite struct PaletteValueTests {
    @Test func rolesRoundTripThroughTheirTokens() {
        for role in ColorRole.allCases {
            #expect(ColorRole(token: role.token) == role)
        }
        // Tokens are the serialized form, so a theme file cannot be silently
        // reinterpreted by adding a role later.
        #expect(ColorRole.onSurfaceVariant.token == "on_surface_variant")
        #expect(ColorRole(token: "not_a_role") == nil)
    }

    @Test func theSubscriptReadsAndWritesEveryRole() {
        var palette = Palette.dark
        for role in ColorRole.allCases {
            palette[role] = Color(0.1, 0.2, 0.3, 1)
            #expect(palette[role] == Color(0.1, 0.2, 0.3, 1))
        }
    }

    /// A spec stores intent, so the same spec paints differently under a
    /// different palette. This is what lets a retheme skip rebuilding the tree.
    @Test func aRoleSpecFollowsThePalette() {
        let spec = ColorSpec.role(.primary)
        #expect(spec.resolve(in: .dark) == Palette.dark.primary)
        #expect(spec.resolve(in: .light) == Palette.light.primary)
        #expect(spec.resolve(in: .dark) != spec.resolve(in: .light))
    }

    /// A literal ignores the palette — for the cases that genuinely are not
    /// themeable.
    @Test func aFixedSpecIgnoresThePalette() {
        let spec = ColorSpec.fixed(Color(1, 0, 0, 1))
        #expect(spec.resolve(in: .dark) == Color(1, 0, 0, 1))
        #expect(spec.resolve(in: .light) == Color(1, 0, 0, 1))
    }

    /// Alpha multiplies rather than replaces, so one role serves a solid fill
    /// and a faint wash without needing a role for each.
    @Test func alphaMultipliesTheResolvedColour() {
        var palette = Palette.dark
        palette.primary = Color(1, 1, 1, 0.8)

        let full = ColorSpec.role(.primary).resolve(in: palette)
        let half = ColorSpec(role: .primary, alpha: 0.5).resolve(in: palette)
        #expect(full.a == 0.8)
        #expect(half.a == 0.4, "0.8 * 0.5, not replaced with 0.5")
        #expect(half.r == full.r, "only alpha moves")
    }

    @Test func opacityCompounds() {
        let spec = ColorSpec(role: .primary, alpha: 0.5).opacity(0.5)
        #expect(spec.alpha == 0.25)
    }

    @Test func lightnessComesFromTheSurface() {
        #expect(Palette.light.isLight)
        #expect(!Palette.dark.isLight)
    }

    @Test func interpolationCrossFadesEveryRole() {
        let mid = Palette.lerp(.dark, .light, 0.5)
        for role in ColorRole.allCases {
            let a = Palette.dark[role]
            let b = Palette.light[role]
            let m = mid[role]
            #expect(m.r >= min(a.r, b.r) - 0.001)
            #expect(m.r <= max(a.r, b.r) + 0.001)
        }
        #expect(Palette.lerp(.dark, .light, 0) == .dark)
        #expect(Palette.lerp(.dark, .light, 1) == .light)
        // Out-of-range clamps rather than extrapolating into invalid colours.
        #expect(Palette.lerp(.dark, .light, 5) == .light)
    }

    /// `SemanticColor` is now a view onto the palette rather than a parallel
    /// system, so a themed palette retints every existing call site.
    @Test func semanticColoursResolveThroughThePalette() {
        var palette = Palette.dark
        palette.onSurface = Color(1, 0, 0, 1)

        #expect(SemanticColor.label.resolve(in: palette) == Color(1, 0, 0, 1))
        // The label ramp is one role at descending alpha, which is what the old
        // hardcoded constants already were.
        let tertiary = SemanticColor.tertiaryLabel.resolve(in: palette)
        #expect(tertiary.r == 1)
        #expect(tertiary.a < 1)
        #expect(tertiary.a > SemanticColor.quaternaryLabel.resolve(in: palette).a)
    }
}

/// Palette inheritance and the repaint that a change has to cause.
@MainActor
@Suite struct PaletteViewTests {
    private func makeScene(root: View) -> WindowScene {
        root.frame = Rect(x: 0, y: 0, width: 100, height: 100)
        let window = Window(title: "Scene")
        window.setContentView(root)
        window.orderFront()
        let scene = WindowScene(windows: [window])
        scene.makeKey(window)
        return scene
    }

    @Test func aViewInheritsThePaletteFromItsAncestors() {
        let root = View()
        let child = View()
        root.addSubview(child)

        var custom = Palette.dark
        custom.primary = Color(0.5, 0, 0, 1)
        root.palette = custom

        #expect(child.effectivePalette.primary == Color(0.5, 0, 0, 1))
        #expect(child.resolve(.role(.primary)) == Color(0.5, 0, 0, 1))
    }

    /// A nearer override wins, which is what makes a preview swatch possible
    /// without pretending the whole shell rethemed.
    @Test func theNearestOverrideWins() {
        let root = View()
        let middle = View()
        let leaf = View()
        root.addSubview(middle)
        middle.addSubview(leaf)

        root.palette = .dark
        middle.palette = .light
        #expect(leaf.effectivePalette.primary == Palette.light.primary)
    }

    @Test func theSceneSuppliesThePaletteWhenNoViewOverrides() {
        let root = View()
        let scene = makeScene(root: root)
        scene.palette = .light
        #expect(root.effectivePalette.primary == Palette.light.primary)
    }

    /// Without a scene or an override, the appearance's standard palette.
    @Test func theAppearanceSuppliesTheFallback() {
        let view = View()
        view.appearance = .light
        #expect(view.effectivePalette.primary == Palette.light.primary)
    }

    // MARK: - The repaint path

    /// The part `SemanticColor` never had: changing colours has to repaint what
    /// was drawn with them.
    @Test func rethemingTheSceneRepaintsTheTree() {
        let root = View()
        let child = View()
        root.addSubview(child)
        let scene = makeScene(root: root)

        root.displayIfNeeded()
        child.displayIfNeeded()
        #expect(!child.needsDisplay)

        scene.palette = .light
        #expect(root.needsDisplay)
        #expect(child.needsDisplay, "the whole subtree, not just the root")
    }

    @Test func assigningAViewPaletteRepaintsItsSubtree() {
        let root = View()
        let child = View()
        root.addSubview(child)
        root.displayIfNeeded()
        child.displayIfNeeded()

        root.palette = .light
        #expect(child.needsDisplay)
    }

    /// Notification stops at a descendant that overrides the palette: nothing
    /// below it paints differently, so repainting it would be wasted work.
    @Test func theWalkStopsAtAnOverridingDescendant() {
        let root = View()
        let overriding = View()
        let below = View()
        root.addSubview(overriding)
        overriding.addSubview(below)
        overriding.palette = .light

        root.displayIfNeeded()
        overriding.displayIfNeeded()
        below.displayIfNeeded()

        root.palette = .dark
        #expect(!below.needsDisplay, "its colours did not change")
    }

    @Test func anIdenticalPaletteIsNotAChange() {
        let root = View()
        let scene = makeScene(root: root)
        scene.palette = .light
        root.displayIfNeeded()
        #expect(!root.needsDisplay)

        scene.palette = .light
        #expect(!root.needsDisplay, "nothing moved, nothing to repaint")
    }

    /// Changing the appearance also has to repaint — it selects the fallback
    /// palette, and previously nothing invalidated at all.
    @Test func changingTheAppearanceRepaints() {
        let root = View()
        let child = View()
        root.addSubview(child)
        root.displayIfNeeded()
        child.displayIfNeeded()

        root.appearance = .light
        #expect(child.needsDisplay)
    }

    /// A view resolving specs at draw time paints the new colours after a
    /// retheme without being rebuilt — the whole point of storing intent.
    @Test func aViewRepaintsWithTheNewColoursAfterARetheme() {
        let root = SpecDrawingView()
        let scene = makeScene(root: root)
        scene.palette = .dark
        root.displayIfNeeded()
        #expect(root.lastResolved == Palette.dark.primary)

        scene.palette = .light
        root.displayIfNeeded()
        #expect(root.lastResolved == Palette.light.primary)
    }
}

@MainActor
private final class SpecDrawingView: View {
    var lastResolved: Color?

    override func draw(in context: GraphicsContext) {
        let color = resolve(.role(.primary))
        lastResolved = color
        context.fillColor = color
        context.fill(bounds)
    }
}
