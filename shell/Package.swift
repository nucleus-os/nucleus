// swift-tools-version:6.4
//
// The Nucleus shell — an out-of-process native Swift Wayland layer-shell
// client authored with NucleusUI and rendered by the shared render core.
//
// The shell consumes the monorepo core and render SDK (Skia Graphite). Where the compositor is
// a Wayland *server* over DRM/KMS, the shell is a Wayland *client* over the WSI swapchain:
// it binds wlr-layer-shell / foreign-toplevel / session-lock / screencopy on the client
// side, and presents the render core's output onto client-owned wl_surfaces via
// VK_KHR_wayland_surface.
//
// The event loop is the wl_display fd + a frame timer (poll-based, in Glibc), so — unlike
// the compositor — this package takes no swift-system dependency.

import PackageDescription
import Foundation

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

// ── The Nucleus render SDK ─────────────────────────────────────────────────────
// Same provisioning the compositor uses. Provisioned by the root
// `tools/nucleus bootstrap` stage graph;
// the link lists here point at monorepo-owned sources.
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

// Wayland *client* + xkb (the client keyboard map for input on shell surfaces).
let waylandClientLinkFlags = pkgConfig(["--libs", "wayland-client", "xkbcommon"])
let compositorWaylandRuntimePackages = [
    "xcb-ewmh", "xcb", "xcb-icccm", "xcb-composite", "xcb-xfixes",
    "xcb-res", "libinput", "libudev", "libseat", "xkbcommon",
]
let compositorWaylandRuntimeLinkFlags =
    pkgConfig(["--libs"] + compositorWaylandRuntimePackages)
    + pkgConfig(["--libs-only-L"] + compositorWaylandRuntimePackages)
        .compactMap { $0.hasPrefix("-L") ? String($0.dropFirst(2)) : nil }
        .flatMap { ["-Xlinker", "-rpath", "-Xlinker", $0] }
// The client xkb façade #includes <xkbcommon/xkbcommon.h>; its include dir must be
// on the importer path for every target that imports NucleusShellInputC.
let xkbClientCcFlags = pkgConfig(["--cflags", "xkbcommon"]).flatMap { ["-Xcc", $0] }

// Skia archive link set shared by shell products and tests.
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

// Enable the Wayland WSI Vulkan surface in VulkanC (the render backend needs
// VkWaylandSurfaceCreateInfoKHR / vkCreateWaylandSurfaceKHR). The core header includes
// <vulkan/vulkan_wayland.h> guarded on this define (see the core enablement change).
let vulkanWaylandFlag: [String] = ["-Xcc", "-DVK_USE_PLATFORM_WAYLAND_KHR"]
let vulkanHeadersInclude: [String] = [
    "-Xcc", "-I", "-Xcc", skiaRoot + "/third_party/externals/vulkan-headers/include",
]

let package = Package(
    name: "NucleusShell",
    dependencies: [
        // The shared monorepo render/UI core.
        .package(name: "Nucleus", path: "../core"),
        // The Vulkan bindings, extracted from Nucleus into their own package. The shell's
        // render backend imports Vulkan / VulkanC directly and injects
        // -DVK_USE_PLATFORM_WAYLAND_KHR at its import site (honoured because VulkanC
        // is a systemLibrary) to pull the vendored vulkan_wayland.h.
        .package(name: "swift-vulkan", path: "../swift-vulkan"),
        // The Wayland protocol bindings, extracted from Nucleus into their own package. The Swift
        // Wayland client imports WaylandClientC (client-side) + links WaylandProtocolsC (the shared
        // marshalling); this package no longer generates a Wayland module of its own.
        .package(name: "swift-wayland", path: "../swift-wayland"),
        .package(name: "swift-tracy", path: "../swift-tracy"),
        .package(
            name: "NucleusLinuxPlatform",
            path: "../platform-linux"),
        // Production server runtime used by the deterministic data-control
        // client/server conformance fixture.
        .package(name: "compositor-core", path: "../compositor/compositor-core"),
    ],
    targets: [
        .target(
            name: "NucleusShellSignalC",
            path: "Sources/NucleusShellSignalC",
            publicHeadersPath: "include"
        ),
        .target(
            name: "NucleusShellLoop",
            path: "Sources/NucleusShellLoop"
        ),
        .testTarget(
            name: "NucleusShellLoopTests",
            dependencies: ["NucleusShellLoop", "NucleusShellSignalC"],
            path: "Tests/NucleusShellLoopTests"
        ),
        // ── The Swift Wayland client: connection, registry, and the layer-shell /
        //    foreign-toplevel / session-lock / screencopy client drivers.
        // The client-side xkb façade: a Wayland client compiles the keymap the
        // compositor hands it over `wl_keyboard.keymap`, rather than building one
        // from rules the way the compositor's own input stack does.
        .systemLibrary(
            name: "NucleusShellInputC",
            path: "Sources/NucleusShellInputC",
            pkgConfig: "xkbcommon"
        ),
        .target(
            name: "NucleusShellWayland",
            dependencies: [
                "NucleusShellInputC",
                .product(name: "WaylandClientC", package: "swift-wayland"),
                .product(name: "WaylandClientDispatch", package: "swift-wayland"),
                .product(name: "WaylandClient", package: "swift-wayland"),
                .product(name: "WaylandProtocolsC", package: "swift-wayland"),
                .product(name: "NucleusTypes", package: "Nucleus"),
            ],
            path: "Sources/NucleusShellWayland",
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                // NucleusShellInputC #includes <xkbcommon/xkbcommon.h>, so its
                // include dir has to be on the clang importer path here.
                .unsafeFlags(xkbClientCcFlags),
            ]
        ),
        // The privileged Wayland clipboard client. Kept separate from the
        // generic Wayland target because it implements NucleusUI's pasteboard
        // service and owns asynchronous transfer pipes.
        .target(
            name: "NucleusShellPasteboard",
            dependencies: [
                "NucleusShellWayland",
                "NucleusShellLoop",
                .product(name: "WaylandClientC", package: "swift-wayland"),
                .product(name: "WaylandClientDispatch", package: "swift-wayland"),
                .product(name: "WaylandProtocolsC", package: "swift-wayland"),
                .product(name: "NucleusUI", package: "Nucleus"),
            ],
            path: "Sources/NucleusShellPasteboard",
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        .testTarget(
            name: "NucleusShellPasteboardTests",
            dependencies: [
                "NucleusShellPasteboard",
                "NucleusShellLoop",
                .product(name: "NucleusUI", package: "Nucleus"),
                .product(
                    name: "NucleusCompositorWaylandRuntime",
                    package: "compositor-core"),
                .product(
                    name: "NucleusCompositorWaylandTestSupport",
                    package: "compositor-core"),
                .product(
                    name: "NucleusCompositorWindowScene",
                    package: "compositor-core"),
                .product(name: "NucleusLayers", package: "Nucleus"),
            ],
            path: "Tests/NucleusShellPasteboardTests",
            swiftSettings: [.interoperabilityMode(.Cxx)],
            linkerSettings: [.unsafeFlags(
                waylandClientLinkFlags + compositorWaylandRuntimeLinkFlags)]
        ),

        // ── The client render backend: a VK_KHR_wayland_surface Vulkan swapchain that
        //    presents the render core's output onto each client wl_surface. Models the
        //    Android WSI presenter (AndroidVulkanPresenter) on wl_display/wl_surface.
        .target(
            name: "NucleusShellRender",
            dependencies: [
                "NucleusShellLoop",
                .product(name: "WaylandClientC", package: "swift-wayland"),
                .product(name: "NucleusRenderer", package: "Nucleus"),
                .product(name: "NucleusRenderModel", package: "Nucleus"),
                .product(name: "Vulkan", package: "swift-vulkan"),
                .product(name: "VulkanC", package: "swift-vulkan"),
                .product(name: "NucleusSkiaGraphiteBridge", package: "Nucleus"),
                .product(name: "Tracy", package: "swift-tracy"),
            ],
            path: "Sources/NucleusShellRender",
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags(vulkanHeadersInclude + vulkanWaylandFlag),
            ]
        ),

        // ── The native shell product: views, controllers, and product composition
        //    for the Swift Noctalia port. This is the first out-of-package client
        //    authoring against NucleusUI's public API, so its dependency list is the
        //    boundary being proven — it must stay NucleusUI-only. If product code
        //    needs a renderer-private capability, that capability belongs in
        //    NucleusUI instead.
        .target(
            name: "NucleusShellProduct",
            dependencies: [
                .product(name: "NucleusUI", package: "Nucleus"),
            ],
            path: "Sources/NucleusShellProduct",
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .strictMemorySafety(),
            ]
        ),

        // ── The input adapter: the single place the shell's Wayland input
        //    vocabulary and NucleusUI's event vocabulary meet. Its own target so
        //    the translation is testable without linking Vulkan or the render
        //    backend — neither of which a keycode mapping needs.
        // ── Authentication. The wire format and the client live here; the PAM
        //    modules themselves are only ever loaded by the helper executable.
        .systemLibrary(
            name: "NucleusShellPamC",
            // PAM's distro pkg-config file names an optional `audit.pc` that is
            // absent on valid non-audit hosts. The module map supplies headers
            // and the helper links `-lpam` explicitly below.
            path: "Sources/NucleusShellPamC"
        ),
        // ── System services. Each one maps a bus peer onto a plain value type;
        //    no service knows what a view is, and no product view knows what a
        //    bus is. The runtime composes them.
        .target(
            name: "NucleusShellServices",
            dependencies: [
                .product(
                    name: "NucleusLinuxDBus",
                    package: "NucleusLinuxPlatform"),
                .product(name: "NucleusUI", package: "Nucleus"),
            ],
            path: "Sources/NucleusShellServices",
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .strictMemorySafety(),
            ]
        ),
        .testTarget(
            name: "NucleusShellServicesTests",
            dependencies: ["NucleusShellServices"],
            path: "Tests/NucleusShellServicesTests",
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),

        // The wire format alone, with no dependencies, so the helper links
        // almost nothing: a smaller image spawns faster and gives a crashing PAM
        // module less to reach.
        .target(
            name: "NucleusShellAuthWire",
            path: "Sources/NucleusShellAuthWire"
        ),
        .target(
            name: "NucleusShellAuth",
            dependencies: [
                "NucleusShellAuthWire",
                "NucleusShellProduct",
                .product(name: "NucleusUI", package: "Nucleus"),
            ],
            path: "Sources/NucleusShellAuth",
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        // A separate process so a crashing or exiting PAM module costs a child,
        // not the locker — a dead locker leaves the session blank and locked.
        .executableTarget(
            name: "NucleusShellPamHelper",
            dependencies: ["NucleusShellAuthWire", "NucleusShellPamC"],
            path: "Sources/NucleusShellPamHelper",
            swiftSettings: [.interoperabilityMode(.Cxx)],
            linkerSettings: [.unsafeFlags(["-lpam"])]
        ),

        .target(
            name: "NucleusShellInput",
            dependencies: [
                "NucleusShellWayland",
                .product(name: "WaylandClientC", package: "swift-wayland"),
                .product(name: "WaylandClientDispatch", package: "swift-wayland"),
                .product(name: "NucleusUI", package: "Nucleus"),
            ],
            path: "Sources/NucleusShellInput",
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .strictMemorySafety(),
            ]
        ),

        .testTarget(
            name: "NucleusShellInputTests",
            dependencies: [
                "NucleusShellInput",
                "NucleusShellAuthWire",
                // The helper binary itself, so the round-trip test has one to run.
                "NucleusShellPamHelper",
                .product(name: "NucleusUI", package: "Nucleus"),
                .product(name: "NucleusUIEmbedder", package: "Nucleus"),
                .product(name: "NucleusLayers", package: "Nucleus"),
                .product(name: "NucleusTextBackend", package: "Nucleus"),
                .product(
                    name: "NucleusCompositorWaylandRuntime",
                    package: "compositor-core"),
                .product(
                    name: "NucleusCompositorWaylandTestSupport",
                    package: "compositor-core"),
                .product(
                    name: "NucleusCompositorWindowScene",
                    package: "compositor-core"),
            ],
            path: "Tests/NucleusShellInputTests",
            swiftSettings: [.interoperabilityMode(.Cxx)],
            linkerSettings: [.unsafeFlags(
                skiaLinkFlags
                    + waylandClientLinkFlags
                    + compositorWaylandRuntimeLinkFlags)]
        ),

        .target(
            name: "NucleusShellRuntime",
            dependencies: [
                "NucleusShellWayland", "NucleusShellRender", "NucleusShellSignalC",
                "NucleusShellLoop", "NucleusShellPasteboard",
                "NucleusShellProduct", "NucleusShellInput", "NucleusShellAuth",
                "NucleusShellServices",
                .product(
                    name: "NucleusLinuxAccessibility",
                    package: "NucleusLinuxPlatform"),
                .product(
                    name: "NucleusLinuxEnvironment",
                    package: "NucleusLinuxPlatform"),
                .product(
                    name: "NucleusLinuxDBus",
                    package: "NucleusLinuxPlatform"),
                .product(
                    name: "NucleusLinuxReactor",
                    package: "NucleusLinuxPlatform"),
                .product(
                    name: "NucleusLinuxSession",
                    package: "NucleusLinuxPlatform"),
                .product(name: "WaylandClient", package: "swift-wayland"),
                .product(name: "NucleusRenderer", package: "Nucleus"),
                .product(name: "NucleusRenderModel", package: "Nucleus"),
                .product(name: "NucleusRenderHost", package: "Nucleus"),
                .product(name: "NucleusLayers", package: "Nucleus"),
                .product(name: "NucleusUI", package: "Nucleus"),
                .product(name: "NucleusTextBackend", package: "Nucleus"),
                .product(name: "NucleusUIEmbedder", package: "Nucleus"),
                .product(name: "NucleusAppHostBundle", package: "Nucleus"),
                .product(name: "NucleusAppHostProtocols", package: "Nucleus"),
                .product(name: "Tracy", package: "swift-tracy"),
            ],
            path: "Sources/NucleusShellRuntime",
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags(vulkanHeadersInclude + vulkanWaylandFlag),
            ]
        ),

        .executableTarget(
            name: "NucleusShellThreadSanitizerHarness",
            dependencies: [
                "NucleusShellRuntime",
                "NucleusShellSignalC",
            ],
            path: "SanitizerHarnesses/NucleusShellThreadSanitizerHarness",
            swiftSettings: [.interoperabilityMode(.Cxx)],
            linkerSettings: [
                .unsafeFlags(
                    skiaLinkFlags + waylandClientLinkFlags
                    + ["-lfontconfig", "-lfreetype", "-lz"]),
            ]
        ),

        // The product target itself depends only on NucleusUI. Its *tests* also
        // link the text backend and Skia, because NucleusUI's TextSystem
        // resolves fonts through TextLayoutService at run time — a link
        // requirement of the framework, not a product dependency.
        .testTarget(
            name: "NucleusShellProductTests",
            dependencies: [
                "NucleusShellProduct",
                .product(name: "NucleusUI", package: "Nucleus"),
                .product(name: "NucleusUIEmbedder", package: "Nucleus"),
                .product(name: "NucleusTypes", package: "Nucleus"),
                .product(name: "NucleusTextBackend", package: "Nucleus"),
            ],
            path: "Tests/NucleusShellProductTests",
            swiftSettings: [.interoperabilityMode(.Cxx)],
            linkerSettings: [.unsafeFlags(skiaLinkFlags)]
        ),

        // ── The shell executable. Hands control to NucleusShellRuntime; the final link
        //    assembles the Swift graph + text backend + Skia, Wayland, and Vulkan.
        .executableTarget(
            name: "NucleusShell",
            dependencies: [
                "NucleusShellRuntime",
                .product(
                    name: "NucleusLinuxSession",
                    package: "NucleusLinuxPlatform"),
                // The Skia text backend, compiled once in the core and linked here (no
                // symlink target) — same product the compositor links.
                .product(name: "NucleusTextBackend", package: "Nucleus"),
            ],
            path: "Sources/NucleusShell",
            swiftSettings: [.interoperabilityMode(.Cxx)],
            linkerSettings: [
                .unsafeFlags(
                    skiaLinkFlags + waylandClientLinkFlags
                    + ["-lfontconfig", "-lfreetype", "-lz"]),
            ]
        ),
    ]
)


for target in package.targets {
    switch target.type {
    case .regular, .executable, .test:
        break
    default:
        continue
    }
    var swiftSettings = (target.swiftSettings ?? []) + [
        .unsafeFlags(["-warnings-as-errors"]),
        .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
    ]
    if let feature = Context.environment["NUCLEUS_SWIFT_DIAGNOSTIC_FEATURE"] {
        swiftSettings.append(.unsafeFlags(["-enable-upcoming-feature", feature]))
    }
    target.swiftSettings = swiftSettings
    target.cSettings = (target.cSettings ?? []) + [
        .unsafeFlags(["-Werror"]),
    ]
    target.cxxSettings = (target.cxxSettings ?? []) + [
        .unsafeFlags(["-Werror"]),
    ]
}
