#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Foundation
import Testing
@testable import NucleusShellServices

/// XDG icon-theme resolution, against a real theme tree built in a temporary
/// directory — the filesystem layout *is* the thing under test, so faking it
/// would test nothing.
@Suite struct IconThemeResolverTests {
    /// A theme tree, torn down with the test.
    private final class Fixture {
        let root: String

        init() {
            root = "\(NSTemporaryDirectory())nucleus-icons-\(UInt32.random(in: 0...UInt32.max))"
            try? FileManager.default.createDirectory(
                atPath: root, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(atPath: root)
        }

        /// Create `<root>/<theme>/<dir>/<category>/<name>.<ext>`.
        func add(
            theme: String, directory: String, category: String = "apps",
            name: String, ext: String = "png"
        ) {
            let path = "\(root)/\(theme)/\(directory)/\(category)"
            try? FileManager.default.createDirectory(
                atPath: path, withIntermediateDirectories: true)
            FileManager.default.createFile(
                atPath: "\(path)/\(name).\(ext)", contents: Data([0]))
        }

        func makeResolver(theme: String = "Adwaita") -> IconThemeResolver {
            IconThemeResolver(themeName: theme, roots: [root])
        }
    }

    // MARK: - Size parsing

    @Test func sizesParseFromDirectoryNames() {
        #expect(IconThemeResolver.parseSize("48x48") == 48)
        #expect(IconThemeResolver.parseSize("22") == 22)
        // Categories and `symbolic` must not parse, which is how they are told
        // apart from sizes.
        #expect(IconThemeResolver.parseSize("apps") == nil)
        #expect(IconThemeResolver.parseSize("symbolic") == nil)
        #expect(IconThemeResolver.parseSize("scalable") == nil)
    }

    // MARK: - Resolution

    @Test func anExactSizeMatchWins() {
        let fixture = Fixture()
        fixture.add(theme: "Adwaita", directory: "16x16", name: "firefox")
        fixture.add(theme: "Adwaita", directory: "22x22", name: "firefox")
        fixture.add(theme: "Adwaita", directory: "48x48", name: "firefox")

        let resolved = fixture.makeResolver().resolve("firefox", size: 22)
        #expect(resolved?.contains("22x22") == true)
    }

    /// The smallest size at or above the target, so any rescale is a gentle
    /// downscale rather than crushing a 512px icon into a bar slot.
    @Test func itPrefersTheSmallestSizeAboveTheTarget() {
        let fixture = Fixture()
        fixture.add(theme: "Adwaita", directory: "16x16", name: "firefox")
        fixture.add(theme: "Adwaita", directory: "32x32", name: "firefox")
        fixture.add(theme: "Adwaita", directory: "512x512", name: "firefox")

        let resolved = fixture.makeResolver().resolve("firefox", size: 22)
        #expect(resolved?.contains("32x32") == true, "not 512, and not 16")
    }

    /// Nothing big enough: take the largest available rather than nothing.
    @Test func itFallsBackToTheLargestBelowTheTarget() {
        let fixture = Fixture()
        fixture.add(theme: "Adwaita", directory: "16x16", name: "firefox")
        fixture.add(theme: "Adwaita", directory: "24x24", name: "firefox")

        let resolved = fixture.makeResolver().resolve("firefox", size: 64)
        #expect(resolved?.contains("24x24") == true)
    }

    /// Scalable wins outright — it is exact at every size.
    @Test func scalableBeatsEveryBitmap() {
        let fixture = Fixture()
        fixture.add(theme: "Adwaita", directory: "22x22", name: "firefox")
        fixture.add(theme: "Adwaita", directory: "scalable", name: "firefox", ext: "svg")

        let resolved = fixture.makeResolver().resolve("firefox", size: 22)
        #expect(resolved?.hasSuffix(".svg") == true)
    }

    /// SVG before PNG before XPM within one directory.
    @Test func extensionsHaveAPreferenceOrder() {
        let fixture = Fixture()
        fixture.add(theme: "Adwaita", directory: "22x22", name: "app", ext: "xpm")
        fixture.add(theme: "Adwaita", directory: "22x22", name: "app", ext: "png")
        #expect(fixture.makeResolver().resolve("app", size: 22)?.hasSuffix(".png") == true)

        fixture.add(theme: "Adwaita", directory: "22x22", name: "app", ext: "svg")
        let fresh = fixture.makeResolver()
        #expect(fresh.resolve("app", size: 22)?.hasSuffix(".svg") == true)
    }

    /// The category-then-size layout appears in the wild alongside
    /// size-then-category, and both must work without an index.theme parser.
    @Test func bothDirectoryLayoutsResolve() {
        let fixture = Fixture()
        // <theme>/apps/48/name.png — category first.
        let path = "\(fixture.root)/Adwaita/apps/48"
        try? FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "\(path)/thunar.png", contents: Data([0]))

        #expect(fixture.makeResolver().resolve("thunar", size: 48) != nil)
    }

    /// hicolor is the theme every application is guaranteed to install into, so
    /// a themed lookup must fall through to it.
    @Test func itFallsBackToHicolor() {
        let fixture = Fixture()
        fixture.add(theme: "hicolor", directory: "48x48", name: "obscure-app")

        let resolved = fixture.makeResolver(theme: "Adwaita")
            .resolve("obscure-app", size: 48)
        #expect(resolved?.contains("hicolor") == true)
    }

    @Test func anUnknownIconResolvesToNothing() {
        let fixture = Fixture()
        fixture.add(theme: "Adwaita", directory: "48x48", name: "firefox")
        #expect(fixture.makeResolver().resolve("not-installed") == nil)
    }

    @Test func anEmptyNameResolvesToNothing() {
        #expect(Fixture().makeResolver().resolve("") == nil)
    }

    /// Applications set icon fields to full paths often enough that treating one
    /// as a theme name would fail for no reason.
    @Test func anAbsolutePathIsUsedDirectly() {
        let fixture = Fixture()
        let direct = "\(fixture.root)/direct.png"
        FileManager.default.createFile(atPath: direct, contents: Data([0]))

        let resolver = fixture.makeResolver()
        #expect(resolver.resolve(direct) == direct)
        #expect(resolver.resolve("\(fixture.root)/absent.png") == nil,
                "an absolute path that does not exist is still a miss")
    }

    /// A flat directory with no theme structure, which is what
    /// /usr/share/pixmaps is.
    @Test func aFlatRootIsSearchedLast() {
        let fixture = Fixture()
        FileManager.default.createFile(
            atPath: "\(fixture.root)/legacy.png", contents: Data([0]))
        #expect(fixture.makeResolver().resolve("legacy", size: 22) != nil)
    }

    // MARK: - Caching

    /// A miss is cached as a miss. A taskbar rebuilding often would otherwise
    /// re-walk the filesystem for every icon known to be absent, which is the
    /// expensive case rather than the cheap one.
    @Test func missesAreCachedAndInvalidationClearsThem() {
        let fixture = Fixture()
        let resolver = fixture.makeResolver()
        #expect(resolver.resolve("appears-later", size: 48) == nil)

        fixture.add(theme: "Adwaita", directory: "48x48", name: "appears-later")
        #expect(resolver.resolve("appears-later", size: 48) == nil,
                "still the cached miss")

        resolver.invalidate()
        #expect(resolver.resolve("appears-later", size: 48) != nil)
    }

    /// A caller holding resolved paths compares the generation to know its icons
    /// are stale, without needing a callback.
    @Test func theGenerationAdvancesOnInvalidation() {
        let resolver = Fixture().makeResolver()
        let before = resolver.generation
        resolver.invalidate()
        #expect(resolver.generation > before)
    }

    @Test func changingTheThemeInvalidates() {
        let resolver = Fixture().makeResolver()
        let before = resolver.generation
        resolver.themeName = "Papirus"
        #expect(resolver.generation > before)

        // An identical assignment is not a change.
        let after = resolver.generation
        resolver.themeName = "Papirus"
        #expect(resolver.generation == after)
    }

    // MARK: - The search path

    /// The user's own icons come before the system's, so an override wins.
    @Test func theDefaultSearchPathIsOrderedUserFirst() {
        let roots = IconThemeResolver.defaultRoots()
        #expect(roots.first?.hasSuffix("/.icons") == true)
        #expect(roots.contains { $0 == "/usr/share/pixmaps" },
                "the legacy location older applications still use")

        guard let userIndex = roots.firstIndex(where: { $0.hasSuffix("/.icons") }),
              let systemIndex = roots.firstIndex(where: { $0.hasPrefix("/usr/share") })
        else {
            Issue.record("expected both a user and a system root")
            return
        }
        #expect(userIndex < systemIndex)
    }
}
