// swift-tools-version:6.4
//
// The pure portable Nucleus graph — the `Nucleus*` core + `NucleusUI`/`NucleusApp*`
// framework library targets. The Linux OS substrate + compositor (`NucleusCompositor*`)
// lives in the sibling `compositor/` package, which consumes this package plus the
// provisioned native SDK — so the core resolves no Wayland/DRM pkg-config and builds
// only the portable graph + Android host (`platform-android`).
// Targets point in-place at the existing scattered source dirs. Stood up bottom-up:
// the pure-Swift shared-type/
// protocol leaves first, then the C-façade (systemLibrary) targets, the cxx-interop
// render/RN modules. External C/C++ dependencies (Skia Graphite, ReactCommon/Hermes/
// folly) are produced by Collider recipes into staging dirs (.skia-build/, .rn-build/)
// and linked from the consuming target.

import PackageDescription
import Foundation

// ── SkiaGraphite façade build flags ───────────────────────────────────────────
// The Skia header search paths + feature defines to compile Graphite.cpp. Paths are
// absolute: SwiftPM
// runs clang with the package's PARENT as the working directory, so relative -I
// would resolve one level too high. The full static Skia archive set, this façade,
// and system libraries link into a Swift executable and run a
// real Skia op; the throwaway smoke that proved it has been removed.)
let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

// ── The Nucleus native render SDK ──────────────────────────────────────────────
// The native C++ stack is consumed through a versioned SDK at a stable cache path, NOT
// via repoRoot-relative reach into third-party/ + .skia-build/ — that decoupling is
// what lets a separate repo consume the identical stack with no source tree to reach
// into. This repo provisions the `render` SDK (Skia/Vulkan) it owns; the React Native
// stack was extracted to its own repo, which owns the RN SDK. The compositor consumes
// only the render SDK. Mirrors the provisioned Swift Android SDK model (~/.cache/nucleus/…).
//
// The render SDK — Skia Graphite archives + headers and the Skia text-backend source.
// Owned by this repo; consumed by the render/UI targets, platform-android, and the
// compositor.
let environment = ProcessInfo.processInfo.environment
let cacheRoot = environment["XDG_CACHE_HOME"]
    ?? (environment["HOME"].map { $0 + "/.cache" } ?? "/tmp")
let nativeSDKRoot = environment["NUCLEUS_NATIVE_SDK_ROOT"]
    ?? cacheRoot + "/nucleus/nucleus-native-sdk"
let renderSDK = nativeSDKRoot + "/render"

let skiaRoot = renderSDK + "/include/skia"          // the Skia source/header tree
let skiaLibDir = renderSDK + "/lib/skia-graphite"   // the GN/Ninja-built archive set
let skiaAndroidLibDir = renderSDK + "/lib/skia-graphite-android-arm64"

let skiaBridgeLinuxCxxFlags: [String] = [
    "-std=c++20", "-DNDEBUG", "-DSK_GRAPHITE", "-DSK_VULKAN",
    "-DSK_GAMMA_APPLY_TO_A8", "-DSK_ALLOW_STATIC_GLOBAL_INITIALIZERS=1",
    "-I", skiaRoot,
    "-I", skiaRoot + "/src",
    "-I", skiaRoot + "/include/third_party/vulkan",
    "-I", skiaRoot + "/src/gpu/vk/vulkanmemoryallocator",
    "-I", skiaRoot + "/third_party/externals/vulkanmemoryallocator/include",
    "-I", skiaRoot + "/third_party/externals/vulkan-headers/include",
]

// Skia façade compile flags for Android: the same native Vulkan Graphite backend
// (ContextFactory::MakeVulkan) as the host, with Android's platform font manager.
let skiaBridgeAndroidCxxFlags: [String] = [
    "-std=c++20", "-DNDEBUG", "-DSK_GRAPHITE", "-DSK_VULKAN",
    "-DSK_GAMMA_APPLY_TO_A8", "-DSK_ALLOW_STATIC_GLOBAL_INITIALIZERS=1",
    "-I", skiaRoot,
    "-I", skiaRoot + "/src",
    "-I", skiaRoot + "/include/third_party/vulkan",
    "-I", skiaRoot + "/src/gpu/vk/vulkanmemoryallocator",
    "-I", skiaRoot + "/third_party/externals/vulkanmemoryallocator/include",
    "-I", skiaRoot + "/third_party/externals/vulkan-headers/include",
]

// Link flags for the GN/Ninja-built Skia archive set, from the native SDK
// (lib/skia-graphite). The archives are mutually recursive → one --start-group; the
// externals are built from vendored source, then system libs
// (vulkan/fontconfig/freetype/z) and dl/pthread/m close it out. libc++ from the toolchain.
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

let skiaAndroidLinkFlags: [String] = [
    "-L", skiaAndroidLibDir,
    "-Xlinker", "--start-group",
    "-lskia", "-lskshaper", "-lskparagraph", "-lskunicode_core", "-lskunicode_icu",
    "-lsvg", "-lskcms", "-lskresources", "-lfreetype2", "-lharfbuzz", "-licu",
    "-lpng", "-ljpeg", "-ljpeg12", "-ljpeg16", "-lwebp", "-lwebp_sse41", "-lexpat",
    "-lzlib", "-lwuffs", "-ldng_sdk", "-lpiex",
    "-Xlinker", "--end-group",
    "-lvulkan", "-landroid", "-llog", "-lz", "-ldl", "-lm",
]

// Resolve pkg-config flags at manifest-eval time (libdrm/gbm live at dynamic host
// store paths that cannot be hardcoded). Runs in the dev shell, where pkg-config
// is on PATH. Used for NucleusCompositorDrmC's include + link flags on the renderer.
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
// libdrm/gbm and Wayland/xcb/input pkg-config resolution live in compositor-core;
// this package is a pure portable graph and resolves none of them.

let package = Package(
    name: "Nucleus",
    // Library products consumed by the sibling compositor app package
    // (compositor/Package.swift). The app owns the executable + composition root +
    // the swift-system dependency; this package stays free of C-interop-only
    // dependencies so `swift test` (which builds the whole package under a global
    // C++-interop flag) is unaffected.
    products: [
        .library(name: "CoreColliderRecipe", targets: ["CoreColliderRecipe"]),
        .library(name: "NucleusAppHostBundle", targets: ["NucleusAppHostBundle"]),
        .library(name: "NucleusRenderModel", targets: ["NucleusRenderModel"]),
        .library(name: "NucleusRenderer", targets: ["NucleusRenderer"]),
        .library(name: "NucleusTextCxxBridge", targets: ["NucleusTextCxxBridge"]),
        .library(name: "NucleusTextBackend", targets: ["NucleusTextBackend"]),
        // Core + app-framework products the compositor-core library package consumes.
        // The compositor's shell is itself a Nucleus app, so it consumes the
        // NucleusUI design system — that dependency direction (compositor → app
        // framework → core) is correct.
        .library(name: "NucleusTypes", targets: ["NucleusTypes"]),
        .library(name: "NucleusLayers", targets: ["NucleusLayers"]),
        .library(name: "NucleusAppHostProtocols", targets: ["NucleusAppHostProtocols"]),
        .library(name: "NucleusRenderHost", targets: ["NucleusRenderHost"]),
        .library(name: "NucleusUI", targets: ["NucleusUI"]),
        .library(name: "NucleusUIEmbedder", targets: ["NucleusUIEmbedder"]),
        .library(name: "NucleusApp", targets: ["NucleusApp"]),
        .library(
            name: "NucleusBenchmarkSupport",
            targets: ["NucleusBenchmarkSupport"]),
        .library(name: "NucleusSkiaGraphiteBridge", targets: ["NucleusSkiaGraphiteBridge"]),
        .executable(
            name: "NucleusHeadlessBenchmarks",
            targets: ["NucleusHeadlessBenchmarks"]),
        .executable(
            name: "NucleusCoreThreadSanitizerHarness",
            targets: ["NucleusCoreThreadSanitizerHarness"]),
    ],
    dependencies: [
        .package(path: "../collider"),
        // The Vulkan bindings (VulkanGen generator + generated typed API + the raw-C
        // façade with vendored Khronos headers) were extracted to their own package.
        // Targets that import Vulkan / VulkanC depend on it directly;
        // downstream packages (platform-android, compositor-core) do too.
        .package(name: "swift-vulkan", path: "../swift-vulkan"),
        // The Tracy profiler bindings, extracted from the core into their own package. The Cxx
        // tracing bridge + the Swift Trace API + the pinned Tracy client; consumed by NucleusUI
        // and re-exported down the graph. Inert unless a build passes -Xcc -DTRACY_ENABLE.
        .package(name: "swift-tracy", path: "../swift-tracy"),
    ],
    targets: [
        .target(
            name: "CoreColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "collider")]),
        // ── Shared-type leaves: public value structs + enums + constants, no deps. ─
        .target(
            name: "NucleusTypes",
            path: "swift/Sources/NucleusTypes",
            swiftSettings: [.strictMemorySafety()]
        ),

        // ── First edge: the host-protocol surface imports NucleusTypes ───────────
        .target(
            name: "NucleusAppHostProtocols",
            dependencies: ["NucleusTypes"],
            path: "swift/Sources/NucleusAppHostProtocols",
            swiftSettings: [.strictMemorySafety()]
        ),

        // ── Mid graph: tracing/types-only modules (no prebuilt C/C++ link yet). ──
        // The layers core. The tracing C-module-map is unused by
        // these sources (they import only NucleusTypes/NucleusAppHostProtocols), so no
        // tracing dep / cxx interop is needed here — only the public-names define.
        .target(
            name: "NucleusLayers",
            dependencies: ["NucleusTypes", "NucleusAppHostProtocols"],
            path: "swift/Sources/NucleusLayers",
            swiftSettings: [
                .define("NUCLEUS_LAYERS_PUBLIC_NAMES"),
                .strictMemorySafety(),
            ]
        ),
        // The first-party text-layout C++ bridge (header-only; impl in the
        // text-backend .so, linked at the executable). A SwiftPM-owned cmodule dir
        // with the real header symlinked in, like the systemd façade.
        .systemLibrary(
            name: "NucleusTextCxxBridge",
            path: "swiftpm/cmodules/NucleusTextCxxBridge"
        ),
        // The Skia text-layout backend, compiled ONCE here and linked downstream (no
        // per-consumer symlinks). skia_text_backend.cpp implements the C draw entry +
        // TextLayoutService; TextRegistry.cpp the paragraph registry + shared font infra.
        // It was previously downstream-provided (symlinked into the compositor/shell) only
        // because it #included RN-tree headers; those text-layout headers now live in the
        // core (render-cxx/skia/include/nucleus/text), so the core compiles it into one
        // product the compositor / shell / RN platform LINK. The public headers expose the
        // nucleus::text vocabulary to consumers (the RN Fabric text layout manager).
        .target(
            name: "NucleusTextBackendNative",
            path: "render-cxx/skia",
            sources: ["skia_text_backend.cpp", "TextRegistry.cpp"],
            publicHeadersPath: "include",
            cxxSettings: [.unsafeFlags(skiaBridgeLinuxCxxFlags)]
        ),
        // C++-interop adapter for NucleusUI's pure Swift TextLayoutBackend seam.
        // Composition roots install it during bring-up; NucleusUI never imports
        // this module or exposes its clang graph.
        .target(
            name: "NucleusTextBackend",
            dependencies: [
                "NucleusUI",
                "NucleusTextCxxBridge",
                "NucleusTextBackendNative",
                .product(name: "Tracy", package: "swift-tracy"),
            ],
            path: "swift/Sources/NucleusTextBackend",
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        // The NucleusUI UI framework. TextSystem owns only a pure Swift service
        // contract; native backends are installed by hosts.
        .target(
            name: "NucleusUI",
            dependencies: ["NucleusTypes", "NucleusLayers", "NucleusAppHostProtocols", .product(name: "Tracy", package: "swift-tracy")],
            path: "swift/Sources/NucleusUI",
            swiftSettings: [.strictMemorySafety()]
        ),
        // NucleusUIEmbedder — the API for code that *embeds* a NucleusUI scene into a
        // platform and feeds it a surface, input, and a frame clock: the compositor, the
        // shell runtime, the React Native runtime. Plain `public`; it reaches NucleusUI's
        // internals through `package` access rather than SPI, which is what makes the
        // boundary enforceable by the build graph instead of by an annotation any client
        // could simply write. Product code depends on NucleusUI and never on this.
        .target(
            name: "NucleusUIEmbedder",
            dependencies: ["NucleusUI", "NucleusLayers", "NucleusTypes"],
            path: "swift/Sources/NucleusUIEmbedder",
            swiftSettings: [.strictMemorySafety()]
        ),
        // NucleusApp — the SwiftUI-shaped App/Scene entry vocabulary and the single-import
        // front door (`@_exported import NucleusUI`). Depends on NucleusUI (re-exported)
        // and NucleusLayers (the host rendering context).
        .target(
            name: "NucleusApp",
            dependencies: ["NucleusUI", "NucleusLayers"],
            path: "swift/Sources/NucleusApp",
            swiftSettings: [.strictMemorySafety()]
        ),
        // The retained render model. Its @main smoke fixtures were migrated to the
        // NucleusRenderModelTests swift-testing target, so the directory now holds
        // only module sources and globs cleanly (no explicit source list).
        .target(
            name: "NucleusRenderModel",
            dependencies: ["NucleusAppHostProtocols"],
            path: "swift/Sources/NucleusRenderModel",
            swiftSettings: [.strictMemorySafety()]
        ),
        // Host-side bundle: ties the shared types + host protocols to the layers/render
        // model. A clean leaf (no cxx interop) once its deps are migrated.
        .target(
            name: "NucleusAppHostBundle",
            dependencies: ["NucleusTypes", "NucleusAppHostProtocols", "NucleusLayers", "NucleusRenderModel"],
            path: "swift/Sources/NucleusAppHostBundle",
            swiftSettings: [.strictMemorySafety()]
        ),
        // The generated Wayland C modules live in compositor-core with the Wayland substrate.
        // the Skia headers (from the native SDK), exposing the nucleus::skia C++ API
        // the renderer imports. Collider provisions the Skia archive set into
        // .skia-build/graphite outside ordinary SwiftPM target builds.
        .target(
            name: "NucleusSkiaGraphiteBridge",
            path: "swift/Sources/NucleusSkiaGraphite/cxx",
            sources: ["Graphite.cpp"],
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags(skiaBridgeLinuxCxxFlags, .when(platforms: [.linux])),
                .unsafeFlags(skiaBridgeAndroidCxxFlags, .when(platforms: [.android])),
            ],
            linkerSettings: [
                .unsafeFlags(skiaAndroidLinkFlags, .when(platforms: [.android])),
            ]
        ),
        // Collider also provisions the Android Vulkan Graphite archive set.
        // C++ interop and links the full GN-built Skia archive set, proving the
        // renderer's Skia link end to end (a real raster Skia op runs).
        .testTarget(
            name: "NucleusSkiaGraphiteTests",
            dependencies: ["NucleusSkiaGraphiteBridge"],
            path: "swift/Tests/NucleusSkiaGraphiteTests",
            swiftSettings: [.interoperabilityMode(.Cxx)],
            linkerSettings: [.unsafeFlags(skiaLinkFlags)]
        ),

        // ── NucleusRenderHost: the adapter layer lowering retained-model render
        // transactions into the host commit sink. Pure Swift (no C/C++ interop);
        // NucleusAppHostProtocols comes transitively through NucleusLayers.
        .target(
            name: "NucleusRenderHost",
            dependencies: ["NucleusTypes", "NucleusLayers", "NucleusRenderModel"],
            path: "swift/Sources/NucleusRenderHost",
            swiftSettings: [.strictMemorySafety()]
        ),
        // The layers→render producer feed.
        .testTarget(
            name: "NucleusRenderHostTests",
            dependencies: ["NucleusRenderHost", "NucleusTypes", "NucleusLayers", "NucleusRenderModel"],
            path: "swift/Tests/NucleusRenderHostTests"
        ),
        .testTarget(
            name: "NucleusRuntimeGraphTests",
            dependencies: [
                "NucleusAppHostBundle", "NucleusRenderHost",
                "NucleusRenderModel", "NucleusLayers", "NucleusUI",
                "NucleusAppHostProtocols",
            ],
            path: "swift/Tests/NucleusRuntimeGraphTests"
        ),
        // The compositor render runtime and its libdrm/gbm, xcb, and libinput/seat
        // C façades live in compositor-core with the DRM/KMS renderer backend.
        // (Linux host waiting now lives in the shared platform-linux reactor;
        // the compositor app package owns only its Swift composition root.)
        // ── NucleusRenderer: the platform-agnostic render core — Vulkan/Graphite
        // scanout, the presentation plan, the retained-tree store, client surface/
        // texture registration, and per-output frame recording behind the
        // `PresentationBackend` protocol. No DRM/KMS, no GBM: presentation is a
        // backend (NucleusCompositorRendererLinux on Linux, the platform-android presenter on
        // Android). Imports NucleusRenderModel + the VulkanC/
        // NucleusSkiaGraphiteBridge clang modules under C++ interop; the VK binding
        // comes from the committed Vulkan module (shared with the Android host;
        // no host-tool build, so the cross-compile needs no static host stdlib). This
        // is the module that cross-compiles for Android. The Skia archive link is a
        // concern of the final executable.
        .target(
            name: "NucleusRenderer",
            dependencies: [
                "NucleusTypes",
                "NucleusRenderModel",
                .product(name: "VulkanC", package: "swift-vulkan"),
                .product(name: "Vulkan", package: "swift-vulkan"),
                "NucleusSkiaGraphiteBridge",
                .product(name: "Tracy", package: "swift-tracy"),
            ],
            path: "swift/Sources/NucleusRenderer",
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags([
                    "-Xcc", "-I", "-Xcc",
                    skiaRoot + "/third_party/externals/vulkan-headers/include",
                ]),
            ]
        ),
        .testTarget(
            name: "NucleusRendererTests",
            dependencies: ["NucleusRenderer", "NucleusTypes"],
            path: "swift/Tests/NucleusRendererTests",
            swiftSettings: [.interoperabilityMode(.Cxx)],
            linkerSettings: [.unsafeFlags(skiaLinkFlags)]
        ),
        // The DRM/KMS presentation backend and its tests live in compositor-core.
        // ── Tests: the @main render fixtures, migrated into a swift-testing
        // target (`@testable import` reaches the same internals the old loose-
        // compile fixtures did). `swift test` runs them.
        .testTarget(
            name: "NucleusRenderModelTests",
            dependencies: ["NucleusRenderModel"],
            path: "swift/Tests/NucleusRenderModelTests"
        ),
        .target(
            name: "NucleusRetainedSceneTestSupport",
            dependencies: ["NucleusUI"],
            path: "swift/Tests/Support/RetainedScene"
        ),
        .target(
            name: "NucleusHostProjectionTestSupport",
            path: "swift/Tests/Support/HostProjection"
        ),
        .target(
            name: "NucleusRendererTestSupport",
            path: "swift/Tests/Support/Renderer"
        ),
        .target(
            name: "NucleusResourceTestSupport",
            path: "swift/Tests/Support/Resources"
        ),
        // (VulkanTests moved to the extracted swift-vulkan package.)
        // The Wayland C, compositor server, and window-manager test targets live in
        // compositor-core.
        // The NucleusUI behavioral suite (View/layout/control/publisher fixtures).
        // The embedder suite deliberately remains pure Swift and exercises the
        // recoverable no-backend path. The compositor-coupled fixtures that used to live alongside
        // these (ShellOverlayRuntimeTests, the sibling WindowSceneTests) were
        // relocated to compositor-core's test graph, where their compositor targets
        // live — this React/compositor-agnostic core package cannot depend on them.
        .testTarget(
            name: "NucleusUIEmbedderTests",
            dependencies: ["NucleusUIEmbedder", "NucleusUI", "NucleusLayers", "NucleusTypes"],
            path: "swift/Tests/NucleusUIEmbedderTests"
        ),
        .testTarget(
            name: "NucleusAppTests",
            dependencies: ["NucleusApp", "NucleusUI"],
            path: "swift/Tests/NucleusAppTests"
        ),
        .testTarget(
            name: "NucleusUITests",
            dependencies: [
                "NucleusUI",
                "NucleusUIEmbedder",
                "NucleusLayers",
                "NucleusTypes",
                "NucleusTextBackend",
                "NucleusSkiaGraphiteBridge",
                "NucleusRenderHost",
                "NucleusRenderModel",
                "NucleusRetainedSceneTestSupport",
                "NucleusHostProjectionTestSupport",
                "NucleusRendererTestSupport",
                "NucleusResourceTestSupport",
            ],
            path: "swift/Tests/NucleusUITests",
            swiftSettings: [.interoperabilityMode(.Cxx)],
            // The real-backend text tests import the C++ adapter explicitly;
            // its native implementation needs the Skia archives and Graphite
            // resolver at this runner's final link.
            linkerSettings: [.unsafeFlags(skiaLinkFlags)]
        ),
        .executableTarget(
            name: "NucleusHeadlessBenchmarks",
            dependencies: [
                "NucleusBenchmarkSupport",
                "NucleusTypes",
                "NucleusLayers",
                "NucleusUI",
                "NucleusRenderModel",
            ],
            path: "swift/Benchmarks/NucleusHeadlessBenchmarks"
        ),
        .target(
            name: "NucleusBenchmarkSupport",
            dependencies: ["NucleusBenchmarkMetricsC"],
            path: "swift/Benchmarks/NucleusBenchmarkSupport"
        ),
        .target(
            name: "NucleusBenchmarkMetricsC",
            path: "swift/Benchmarks/NucleusBenchmarkMetricsC",
            publicHeadersPath: "include"
        ),
        .testTarget(
            name: "NucleusBenchmarkSupportTests",
            dependencies: ["NucleusBenchmarkSupport"],
            path: "swift/Tests/NucleusBenchmarkSupportTests"
        ),
        .executableTarget(
            name: "NucleusCoreThreadSanitizerHarness",
            dependencies: [
                "NucleusAppHostProtocols",
                "NucleusRenderModel",
                "NucleusRenderer",
            ],
            path: "swift/SanitizerHarnesses/NucleusCoreThreadSanitizerHarness",
            swiftSettings: [.interoperabilityMode(.Cxx)],
            linkerSettings: [.unsafeFlags(skiaLinkFlags)]
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
