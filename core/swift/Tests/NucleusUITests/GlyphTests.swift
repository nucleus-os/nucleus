import Testing
@testable import NucleusUI

/// Icon glyphs. Icons are font glyphs rather than bitmaps, so an icon
/// recolours and rescales for free and costs a codepoint rather than a decode.
@MainActor
@Suite(.uiContext) struct GlyphTests {
    init() {
        installTestTextBackend()
    }

    private func makeCatalog() -> GlyphCatalog {
        let catalog = GlyphCatalog(fontFamily: "TestIcons")
        catalog.register("battery", "\u{e900}")
        catalog.register("wifi", "\u{e901}")
        return catalog
    }

    // MARK: - The catalog

    @Test func namesResolveToCodepoints() {
        let catalog = makeCatalog()
        #expect(catalog.lookup("battery") == "\u{e900}")
        #expect(catalog.contains("wifi"))
        #expect(catalog.lookup("nonexistent") == nil)
        #expect(!catalog.contains("nonexistent"))
    }

    @Test func aBulkRegistrationMerges() {
        let catalog = makeCatalog()
        catalog.register(["bluetooth": "\u{e902}", "volume": "\u{e903}"])
        #expect(catalog.count == 4)
        #expect(catalog.lookup("bluetooth") == "\u{e902}")
        #expect(catalog.lookup("battery") == "\u{e900}", "existing entries survive")
    }

    @Test func aLaterRegistrationWins() {
        let catalog = makeCatalog()
        catalog.register("battery", "\u{e9ff}")
        #expect(catalog.lookup("battery") == "\u{e9ff}")
    }

    /// Icon sets rename things between releases, and a widget naming a retired
    /// icon should keep working rather than silently render nothing.
    @Test func aliasesResolveToTheirTarget() {
        let catalog = makeCatalog()
        catalog.alias("power", to: "battery")
        #expect(catalog.lookup("power") == "\u{e900}")
        #expect(catalog.contains("power"))
    }

    @Test func anAliasToNothingResolvesToNothing() {
        let catalog = makeCatalog()
        catalog.alias("ghost", to: "missing")
        #expect(catalog.lookup("ghost") == nil)
    }

    @Test func namesAreSorted() {
        #expect(makeCatalog().names == ["battery", "wifi"])
    }

    // MARK: - The view

    @Test func theViewResolvesItsNameThroughItsCatalog() {
        let view = GlyphView(name: "battery")
        view.catalog = makeCatalog()
        #expect(view.resolvedCharacter == "\u{e900}")
    }

    /// An explicit codepoint wins, for glyphs a widget computes rather than
    /// names.
    @Test func anExplicitCharacterBypassesTheCatalog() {
        let view = GlyphView(name: "battery")
        view.catalog = makeCatalog()
        view.character = "\u{eabc}"
        #expect(view.resolvedCharacter == "\u{eabc}")
    }

    /// A shell showing a *wrong* icon is worse than one showing a gap, because
    /// the gap is visibly a bug.
    @Test func anUnresolvableNameRendersNothing() {
        let view = GlyphView(name: "nonexistent")
        view.catalog = makeCatalog()
        #expect(view.resolvedCharacter == nil)
        // Nothing to lay out means nothing to draw, and a zero intrinsic size
        // means the gap does not even reserve space.
        #expect(view.intrinsicContentSize == .zero)
    }

    @Test func withoutACatalogNothingResolves() {
        let context = UIContext(services: .inMemory())
        let view = context.construct { GlyphView(name: "battery") }
        #expect(view.resolvedCharacter == nil)
    }

    /// A semantic UI graph owns its icon catalog, so widgets inherit the
    /// catalog from their context without relying on process-global state.
    @Test func theOwningContextCatalogIsTheDefault() {
        let context = UIContext(
            services: .inMemory(),
            glyphCatalog: makeCatalog())
        let view = context.construct { GlyphView(name: "wifi") }
        #expect(view.resolvedCharacter == "\u{e901}")
    }

    @Test func anOwnCatalogOverridesTheContextCatalog() {
        let other = GlyphCatalog(fontFamily: "OtherIcons")
        other.register("wifi", "\u{f000}")

        let context = UIContext(
            services: .inMemory(),
            glyphCatalog: makeCatalog())
        let view = context.construct { GlyphView(name: "wifi") }
        view.catalog = other
        #expect(view.resolvedCharacter == "\u{f000}")
    }

    @Test func contextCatalogsAreIsolated() {
        let firstCatalog = GlyphCatalog(fontFamily: "FirstIcons")
        firstCatalog.register("wifi", "\u{e901}")
        let secondCatalog = GlyphCatalog(fontFamily: "SecondIcons")
        secondCatalog.register("wifi", "\u{f000}")

        let firstContext = UIContext(
            services: .inMemory(),
            glyphCatalog: firstCatalog)
        let secondContext = UIContext(
            services: .inMemory(),
            glyphCatalog: secondCatalog)
        let firstView = firstContext.construct { GlyphView(name: "wifi") }
        let secondView = secondContext.construct { GlyphView(name: "wifi") }

        #expect(firstView.resolvedCharacter == "\u{e901}")
        #expect(secondView.resolvedCharacter == "\u{f000}")

        firstCatalog.register("wifi", "\u{e902}")
        #expect(firstView.resolvedCharacter == "\u{e902}")
        #expect(secondView.resolvedCharacter == "\u{f000}")
    }

    // MARK: - Invalidation

    @Test func changingTheNameInvalidates() {
        let view = GlyphView(name: "battery")
        view.catalog = makeCatalog()
        view.frame = Rect(x: 0, y: 0, width: 20, height: 20)
        view.displayIfNeeded()
        #expect(!view.needsDisplay)

        view.name = "wifi"
        #expect(view.needsDisplay)
        #expect(view.resolvedCharacter == "\u{e901}")
    }

    @Test func anIdenticalNameIsNotAChange() {
        let view = GlyphView(name: "battery")
        view.catalog = makeCatalog()
        view.frame = Rect(x: 0, y: 0, width: 20, height: 20)
        view.displayIfNeeded()

        view.name = "battery"
        #expect(!view.needsDisplay)
    }

    @Test func changingTheSizeInvalidates() {
        let view = GlyphView(name: "battery")
        view.catalog = makeCatalog()
        view.frame = Rect(x: 0, y: 0, width: 20, height: 20)
        view.displayIfNeeded()

        view.pointSize = 24
        #expect(view.needsDisplay)
    }

    /// The tint is a spec, so a glyph follows a retheme like everything else.
    @Test func rethemingRepaintsTheGlyph() {
        let view = GlyphView(name: "battery")
        view.catalog = makeCatalog()
        view.frame = Rect(x: 0, y: 0, width: 20, height: 20)
        view.palette = .dark
        view.displayIfNeeded()

        view.palette = .light
        #expect(view.needsDisplay)
        #expect(view.resolve(view.tint) == Palette.light.onSurface)
    }

    @Test func aGlyphDescribesItselfAsAnImage() {
        #expect(GlyphView(name: "battery").accessibilityRole == .image)
    }
}
