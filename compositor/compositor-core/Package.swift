// swift-tools-version:6.4
//
// The Nucleus compositor library package — the Linux platform backend (core/
// compositor split, migration Phase 2).
//
// This holds the Linux OS substrate + compositor policy that used to live in the
// root library package: the Wayland/DRM/input/seat C façades, the Wayland runtime,
// the DRM/KMS renderer backend + render-runtime facade, and the window/seat policy
// + shell overlay modules. It is a LIBRARY package — tested via
//   swift test --package-path compositor-core
// — and, unlike the sibling `compositor/` executable package, it takes NO
// swift-system dependency (the constraint that first split `compositor/` out of root).
//
// Its targets' sources are real files under Sources/ / Tests/ (consolidated from
// their former scattered homes). Modules are renamed to NucleusCompositor*.

import PackageDescription
import Foundation

// This package's parent is the repo root; all absolute build flags resolve against
// it (SwiftPM runs clang/ld with the package's parent as the working directory).
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().path

// ── The Nucleus render native SDK (Skia) ───────────────────────────────────────
// Consumed from a stable cache path (see the core repo's docs/repo-decomposition.md).
// This package is a pure Wayland/DRM compositor library — it links zero React, so it
// consumes only the `render` SDK (Skia). Provisioned by root `tools/nucleus bootstrap`;
// the link list points at the monorepo core.
func provisionSDK(_ name: String, links: [(String, String)]) -> String {
    let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
    let sdk = home + "/.cache/nucleus/nucleus-native-sdk/" + name
    let fm = FileManager.default
    for (dest, target) in links {
        let path = sdk + "/" + dest
        guard fm.fileExists(atPath: target) else { continue }
        if let existing = try? fm.destinationOfSymbolicLink(atPath: path) {
            if existing == target { continue }
            try? fm.removeItem(atPath: path)
        } else if fm.fileExists(atPath: path) {
            continue
        }
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        try? fm.createSymbolicLink(atPath: path, withDestinationPath: target)
    }
    return sdk
}
let renderSDK = provisionSDK("render", links: [
    ("include/skia", repoRoot + "/../core/third-party/skia"),
    ("lib/skia-graphite", repoRoot + "/../core/.skia-build/graphite"),
    ("include/skia-text", repoRoot + "/../core/render-cxx/skia"),
])
let skiaRoot = renderSDK + "/include/skia"
let skiaLibDir = renderSDK + "/lib/skia-graphite"

// Resolve host system-library flags through pkg-config at manifest-evaluation time.
func pkgConfig(_ args: [String]) -> [String] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["pkg-config"] + args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return [] }
    p.waitUntilExit()
    let out = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(decoding: out, as: UTF8.self)
        .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        .map(String.init)
}

// libdrm + gbm (the DRM/KMS renderer backend + render-runtime facade).
let drmGbmCcFlags = pkgConfig(["--cflags", "libdrm", "gbm"]).flatMap { ["-Xcc", $0] }
let drmGbmLinkFlags = pkgConfig(["--libs", "libdrm", "gbm"])

// Wayland substrate system headers (the NucleusCompositorXcbC / NucleusCompositorInputC façades
// #include <xcb/…>/<libinput.h>/… so their dirs must be on the Wayland runtime's
// clang importer path). wayland-server's own cflags propagate through swift-wayland's WaylandServerC.
let waylandRuntimeCcFlags = pkgConfig(["--cflags", "xcb-ewmh", "libinput", "libudev", "libseat", "xkbcommon"]).flatMap { ["-Xcc", $0] }
// Link closure for an executable/test that pulls in the Wayland runtime's xcb +
// input substrate (mirrors the compositor executable's own flags).
let waylandRuntimeLinkPkgs = ["xcb-ewmh", "xcb", "xcb-icccm", "xcb-composite", "xcb-xfixes", "xcb-res", "libinput", "libudev", "libseat", "xkbcommon"]
let waylandRuntimeLinkFlags = pkgConfig(["--libs"] + waylandRuntimeLinkPkgs)
    // Preserve nonstandard library search paths in the spawned test runner.
    + pkgConfig(["--libs-only-L"] + waylandRuntimeLinkPkgs)
        .compactMap { $0.hasPrefix("-L") ? String($0.dropFirst(2)) : nil }
        .flatMap { ["-Xlinker", "-rpath", "-Xlinker", $0] }

// Link flags for the GN/Ninja-built Skia archive set (in .skia-build/graphite) —
// the NucleusCompositorRendererLinux test links the full renderer closure end to end.
let skiaLinkFlags: [String] = [
    "-L", skiaLibDir,
    "-Xlinker", "--start-group",
    "-lskia", "-lskshaper", "-lskparagraph", "-lskunicode_core", "-lskunicode_icu",
    "-lsvg", "-lskcms", "-lskresources", "-lfreetype2", "-lharfbuzz", "-licu",
    "-lpng", "-ljpeg", "-ljpeg12", "-ljpeg16", "-lwebp", "-lwebp_sse41", "-lexpat",
    "-lzlib", "-lwuffs", "-ldng_sdk", "-lpiex",
    "-Xlinker", "--end-group",
    "-lvulkan", "-lfontconfig", "-lfreetype", "-lz", "-ldl", "-lpthread", "-lm",
]

let vulkanHeadersInclude: [String] = [
    "-Xcc", "-I", "-Xcc",
    skiaRoot + "/third_party/externals/vulkan-headers/include",
]

let package = Package(
    name: "compositor-core",
    // Products consumed by the sibling compositor executable package (compositor/).
    products: [
        .library(name: "NucleusCompositorRendererLinux", targets: ["NucleusCompositorRendererLinux"]),
        .library(name: "NucleusCompositorRenderRuntime", targets: ["NucleusCompositorRenderRuntime"]),
        .library(name: "NucleusCompositorWaylandRuntime", targets: ["NucleusCompositorWaylandRuntime"]),
        .library(name: "NucleusCompositorOverlayTypes", targets: ["NucleusCompositorOverlayTypes"]),
        .library(name: "NucleusCompositorOverlayScene", targets: ["NucleusCompositorOverlayScene"]),
        .library(name: "NucleusCompositorServer", targets: ["NucleusCompositorServer"]),
        .library(name: "NucleusCompositorWindowManager", targets: ["NucleusCompositorWindowManager"]),
        .library(name: "NucleusCompositorShell", targets: ["NucleusCompositorShell"]),
    ],
    dependencies: [
        // The Nucleus library package — portable core + app framework (the
        // NucleusUI design system this compositor's shell is built with). This is
        // the compositor's only Nucleus dependency: it links zero React.
        .package(name: "Nucleus", path: "../../core"),
        // The Vulkan bindings, extracted from Nucleus into their own package. Consumed
        // directly (a package cannot re-vend a dependency's product); the renderer and
        // the Graphite bridge import Vulkan / VulkanC.
        .package(name: "swift-vulkan", path: "../../swift-vulkan"),
        // The Wayland protocol bindings, extracted from Nucleus into their own package. The
        // Wayland runtime imports WaylandServerC (server-side) + links WaylandProtocolsC (the
        // shared marshalling); this package no longer generates a Wayland module of its own.
        .package(name: "swift-wayland", path: "../../swift-wayland"),
        .package(name: "swift-tracy", path: "../../swift-tracy"),
    ],
    targets: [
        // ── Shared value-type / policy leaves ────────────────────────────────────
        .target(name: "NucleusCompositorServerTypes", path: "Sources/NucleusCompositorServerTypes"),
        .target(name: "NucleusCompositorOverlayTypes", path: "Sources/NucleusCompositorOverlayTypes"),

        // ── OS-substrate C façades (the pkg-config that used to force into root) ──
        .systemLibrary(
            name: "NucleusCompositorSystemdC",
            path: "Sources/NucleusCompositorSystemdC",
            pkgConfig: "libsystemd"
        ),
        .systemLibrary(
            name: "NucleusCompositorDrmC",
            path: "Sources/NucleusCompositorDrmC",
            pkgConfig: "libdrm"
        ),
        .systemLibrary(
            name: "NucleusCompositorXcbC",
            path: "Sources/NucleusCompositorXcbC",
            pkgConfig: "xcb-ewmh"
        ),
        .systemLibrary(
            name: "NucleusCompositorInputC",
            path: "Sources/NucleusCompositorInputC"
        ),
        .target(
            name: "WaylandWireTestC",
            path: "Tests/WaylandWireTestC",
            publicHeadersPath: "include"
        ),

        // ── Window/seat policy + shell overlay (built with the NucleusUI design system) ──
        .target(
            name: "NucleusCompositorServer",
            dependencies: [
                .product(name: "NucleusTypes", package: "Nucleus"),
                .product(name: "NucleusLayers", package: "Nucleus"),
                "NucleusCompositorServerTypes",
            ],
            path: "Sources/NucleusCompositorServer"
        ),
        .target(
            name: "NucleusCompositorWindowManager",
            dependencies: [
                .product(name: "NucleusTypes", package: "Nucleus"),
                .product(name: "NucleusLayers", package: "Nucleus"),
                "NucleusCompositorServerTypes", "NucleusCompositorServer",
                .product(name: "Tracy", package: "swift-tracy"),
            ],
            path: "Sources/NucleusCompositorWindowManager",
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        .target(
            name: "NucleusCompositorWindowScene",
            dependencies: [
                .product(name: "NucleusTypes", package: "Nucleus"),
                .product(name: "NucleusLayers", package: "Nucleus"),
                "NucleusCompositorServerTypes",
                .product(name: "NucleusRenderHost", package: "Nucleus"),
                .product(name: "NucleusAppHostProtocols", package: "Nucleus"),
                .product(name: "NucleusAppHostBundle", package: "Nucleus"),
                .product(name: "NucleusRenderModel", package: "Nucleus"),
            ],
            path: "Sources/NucleusCompositorWindowScene"
        ),
        .target(
            name: "NucleusCompositorOverlay",
            dependencies: [
                .product(name: "NucleusUI", package: "Nucleus"),
                .product(name: "NucleusUIEmbedder", package: "Nucleus"),
                .product(name: "NucleusLayers", package: "Nucleus"),
                .product(name: "NucleusTypes", package: "Nucleus"),
                "NucleusCompositorOverlayTypes",
                .product(name: "NucleusAppHostProtocols", package: "Nucleus"),
                .product(name: "Tracy", package: "swift-tracy"),
            ],
            path: "Sources/NucleusCompositorOverlay",
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        // The desktop-application index — a cxx-free leaf carved out of the
        // NucleusCompositorShell directory (the rest of that dir is the NucleusCompositorShell module).
        .target(
            name: "NucleusCompositorShellSurface",
            path: "Sources/NucleusCompositorShell",
            exclude: [
                "AppearancePortal.swift", "BezelService.swift", "CursorTheme.swift",
                "CursorThemeHost.swift", "DBusService.swift", "IdlePolicy.swift",
                "KeybindService.swift", "LauncherService.swift", "NotificationService.swift",
                "ScreenshotService.swift", "ShellOverlayPublicationHost.swift",
                "ShellPolicyHost.swift", "ShellServiceHost.swift", "ShellServices.swift",
                "SystemdBus.swift", "XCursor.swift",
            ],
            sources: ["DesktopApplicationIndex.swift"]
        ),
        .target(
            name: "NucleusCompositorOverlayScene",
            dependencies: [
                .product(name: "NucleusLayers", package: "Nucleus"),
                .product(name: "NucleusTypes", package: "Nucleus"),
                "NucleusCompositorOverlayTypes",
                .product(name: "NucleusUI", package: "Nucleus"),
                .product(name: "NucleusUIEmbedder", package: "Nucleus"),
                "NucleusCompositorOverlay", "NucleusCompositorWindowManager", "NucleusCompositorServer", "NucleusCompositorServerTypes",
                .product(name: "NucleusRenderHost", package: "Nucleus"),
                .product(name: "NucleusAppHostProtocols", package: "Nucleus"),
                .product(name: "NucleusAppHostBundle", package: "Nucleus"),
                .product(name: "NucleusRenderModel", package: "Nucleus"),
                .product(name: "Tracy", package: "swift-tracy"),
            ],
            path: "Sources/NucleusCompositorOverlayScene",
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        .target(
            name: "NucleusCompositorShell",
            dependencies: [
                "NucleusCompositorShellSurface", "NucleusCompositorServer", "NucleusCompositorWindowManager", "NucleusCompositorServerTypes",
                .product(name: "NucleusLayers", package: "Nucleus"),
                .product(name: "NucleusTypes", package: "Nucleus"),
                "NucleusCompositorOverlayTypes",
                .product(name: "NucleusUI", package: "Nucleus"),
                .product(name: "NucleusUIEmbedder", package: "Nucleus"),
                "NucleusCompositorOverlay",
                .product(name: "NucleusRenderHost", package: "Nucleus"),
                .product(name: "NucleusAppHostProtocols", package: "Nucleus"),
                .product(name: "NucleusAppHostBundle", package: "Nucleus"),
                .product(name: "NucleusRenderModel", package: "Nucleus"),
                "NucleusCompositorOverlayScene",
                .product(name: "Tracy", package: "swift-tracy"),
                "NucleusCompositorSystemdC",
            ],
            path: "Sources/NucleusCompositorShell",
            exclude: ["DesktopApplicationIndex.swift"],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),

        // ── The Wayland substrate runtime ────────────────────────────────────────
        .target(
            name: "NucleusCompositorWaylandRuntime",
            dependencies: [
                .product(name: "WaylandServerC", package: "swift-wayland"),
                .product(name: "WaylandProtocolsC", package: "swift-wayland"),
                .product(name: "WaylandServer", package: "swift-wayland"),
                .product(name: "WaylandServerDispatch", package: "swift-wayland"),
                "NucleusCompositorXcbC", "NucleusCompositorInputC",
                "NucleusCompositorServer", "NucleusCompositorWindowManager", "NucleusCompositorServerTypes", "NucleusCompositorWindowScene",
                .product(name: "NucleusTypes", package: "Nucleus"),
                .product(name: "NucleusLayers", package: "Nucleus"),
                .product(name: "NucleusRenderModel", package: "Nucleus"),
                .product(name: "Tracy", package: "swift-tracy"),
                .product(name: "NucleusTextCxxBridge", package: "Nucleus"),
            ],
            path: "Sources/NucleusCompositorWaylandRuntime",
            exclude: ["README.md"],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags(waylandRuntimeCcFlags),
            ]
        ),

        // ── The DRM/KMS renderer backend + the render-runtime facade ─────────────
        .target(
            name: "NucleusCompositorRendererLinux",
            dependencies: [
                .product(name: "NucleusRenderer", package: "Nucleus"),
                .product(name: "NucleusRenderModel", package: "Nucleus"),
                .product(name: "VulkanC", package: "swift-vulkan"),
                .product(name: "Vulkan", package: "swift-vulkan"),
                "NucleusCompositorDrmC",
            ],
            path: "Sources/NucleusCompositorRendererLinux",
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags(vulkanHeadersInclude + drmGbmCcFlags),
            ],
            linkerSettings: [.unsafeFlags(drmGbmLinkFlags)]
        ),
        .target(
            name: "NucleusCompositorRenderRuntime",
            dependencies: [
                .product(name: "NucleusRenderer", package: "Nucleus"),
                "NucleusCompositorRendererLinux",
                .product(name: "NucleusRenderModel", package: "Nucleus"),
                .product(name: "NucleusRenderHost", package: "Nucleus"),
                .product(name: "NucleusLayers", package: "Nucleus"),
                .product(name: "VulkanC", package: "swift-vulkan"),
                "NucleusCompositorDrmC",
                .product(name: "NucleusSkiaGraphiteBridge", package: "Nucleus"),
                .product(name: "Tracy", package: "swift-tracy"),
            ],
            path: "Sources/NucleusCompositorRenderRuntime",
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags(vulkanHeadersInclude + drmGbmCcFlags),
            ]
        ),

        // ── Tests (relocated with the modules they cover). ───────────────────────
        .testTarget(
            name: "NucleusCompositorRendererLinuxTests",
            dependencies: [
                "NucleusCompositorRendererLinux",
                .product(name: "NucleusTypes", package: "Nucleus"),
                .product(name: "Vulkan", package: "swift-vulkan"),
            ],
            path: "Tests/NucleusCompositorRendererLinuxTests",
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags(vulkanHeadersInclude + drmGbmCcFlags),
            ],
            linkerSettings: [.unsafeFlags(drmGbmLinkFlags + skiaLinkFlags)]
        ),
        .testTarget(
            name: "NucleusCompositorRenderRuntimeTests",
            dependencies: [
                "NucleusCompositorRenderRuntime",
                "NucleusCompositorRendererLinux",
                .product(name: "NucleusRenderer", package: "Nucleus"),
            ],
            path: "Tests/NucleusCompositorRenderRuntimeTests",
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags(vulkanHeadersInclude + drmGbmCcFlags),
            ],
            linkerSettings: [.unsafeFlags(drmGbmLinkFlags + skiaLinkFlags)]
        ),
        .testTarget(
            name: "NucleusCompositorWaylandCTests",
            dependencies: [
                .product(name: "WaylandServerC", package: "swift-wayland"),
                .product(name: "WaylandProtocolsC", package: "swift-wayland"),
            ],
            path: "Tests/NucleusCompositorWaylandCTests",
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        .testTarget(
            name: "NucleusCompositorServerTests",
            dependencies: ["NucleusCompositorServer"],
            path: "Tests/NucleusCompositorServerTests"
        ),
        .testTarget(
            name: "NucleusCompositorWindowManagerTests",
            dependencies: ["NucleusCompositorServer", "NucleusCompositorWindowManager"],
            path: "Tests/NucleusCompositorWindowManagerTests",
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        // Wire-level Wayland protocol conformance, driving the real router over the
        // in-process WaylandTestClient harness. The
        // legacy `@main` parity fixtures in this directory are not built (each is its
        // own executable); `sources` scopes this target to the harness + the tests.
        .testTarget(
            name: "NucleusCompositorWaylandRuntimeTests",
            dependencies: [
                "NucleusCompositorWaylandRuntime", "NucleusCompositorServer",
                // Direct deps on the C façades so their systemLibrary pkgConfig cflags
                // (xcb/libinput include dirs) reach this target's @testable recompile.
                "NucleusCompositorXcbC", "NucleusCompositorInputC",
                .product(name: "WaylandServerC", package: "swift-wayland"),
                .product(name: "WaylandProtocolsC", package: "swift-wayland"),
                .product(name: "WaylandServer", package: "swift-wayland"),
                "WaylandWireTestC",
            ],
            path: "Tests/NucleusCompositorWaylandRuntimeTests",
            exclude: [
                "WaylandBufferFixture.swift", "WaylandCoreFixture.swift",
                "WaylandDataDeviceFixture.swift", "WaylandDmabufFixture.swift",
                "WaylandGammaFixture.swift", "WaylandHarnessFixture.swift",
                "WaylandIdleEffectsFixture.swift", "WaylandLayerShellFixture.swift",
                "WaylandPointerConstraintsFixture.swift", "WaylandPresentationFixture.swift",
                "WaylandRelativePointerFixture.swift", "WaylandRouterFixture.swift",
                "WaylandRuntimeSmoke.swift", "WaylandScreencopyFixture.swift",
                "WaylandSeatFixture.swift", "WaylandSessionLockFixture.swift",
                "WaylandShellAuxFixture.swift", "WaylandSubsurfaceFixture.swift",
                "WaylandSurfaceAuxFixture.swift", "WaylandSurfaceFixture.swift",
                "WaylandSyncobjFixture.swift", "WaylandXdgShellFixture.swift",
                "XwaylandAtomsFixture.swift", "XwaylandPropertiesFixture.swift",
                "XwaylandXSettingsFixture.swift",
            ],
            sources: [
                "WaylandWireTest.swift", "WaylandProtocolConformanceTests.swift",
                "CursorShapeNameTests.swift", "CursorShmRepackTests.swift",
                "CursorRequestSerialTests.swift", "CursorIntentTests.swift",
                "SurfaceCommitGeometryTests.swift", "SurfaceTransactionTests.swift",
                "SubsurfaceTopologyTests.swift",
                "SeatSerialLedgerTests.swift",
                "XdgConfigureLedgerTests.swift",
                "XdgPositionerTests.swift",
                "DmabufLayoutValidatorTests.swift",
                "DndActionNegotiationTests.swift",
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags(waylandRuntimeCcFlags),
            ],
            linkerSettings: [.unsafeFlags(skiaLinkFlags + waylandRuntimeLinkFlags)]
        ),
        // Shell-overlay runtime behavior (rewritten from the core repo's stale
        // orphaned fixture against the current overlay API; covers
        // NucleusCompositorOverlay). Links NucleusUI's text backend + Skia archives
        // + the SkiaGraphite resolver slot the backend registers into, same as the
        // core NucleusUITests runner.
        .testTarget(
            name: "NucleusCompositorOverlayTests",
            dependencies: [
                "NucleusCompositorOverlay",
                "NucleusCompositorOverlayTypes",
                .product(name: "NucleusUI", package: "Nucleus"),
                .product(name: "NucleusUIEmbedder", package: "Nucleus"),
                .product(name: "NucleusLayers", package: "Nucleus"),
                .product(name: "NucleusTextBackend", package: "Nucleus"),
                .product(name: "NucleusSkiaGraphiteBridge", package: "Nucleus"),
            ],
            path: "Tests/NucleusCompositorOverlayTests",
            swiftSettings: [.interoperabilityMode(.Cxx)],
            linkerSettings: [.unsafeFlags(skiaLinkFlags)]
        ),
        // Compositor-root self-hosting topology the scene feeder drives (relocated
        // from the core repo's test tree; covers NucleusCompositorWindowScene).
        .testTarget(
            name: "NucleusCompositorWindowSceneTests",
            dependencies: [
                "NucleusCompositorWindowScene",
                .product(name: "NucleusLayers", package: "Nucleus"),
            ],
            path: "Tests/NucleusCompositorWindowSceneTests"
        ),
    ]
)
