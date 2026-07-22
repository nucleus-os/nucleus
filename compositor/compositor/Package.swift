// swift-tools-version:6.4
//
// The Nucleus compositor application package.
// This is the app half of an app/library split. The library package (../) holds
// the reusable first-party modules and their broad test suites. This app package
// retains a dependency-clean render-session test target so `swift test` validates
// executable-package assembly and the DRM-seat ownership contract. C++
// interoperability remains scoped to the composition root and executable rather
// than being forced over the non-C++ test target. SystemPackage itself is valid in
// that C++-interop composition root; it imports only CSystem's C declarations.
//
// Targets whose sources were consolidated from a separate tree (the composition
// root, the text backend's two .cpp) now live as real files under Sources/, since
// a SwiftPM target's sources must sit inside the package root.

import PackageDescription
import Foundation

// The repo root is this package's parent. All absolute build flags resolve
// against it (SwiftPM runs clang/ld with the package's parent as the working
// directory, so relative paths would resolve one level too high).
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().path

// ── The Nucleus render native SDK (Skia) ───────────────────────────────────────
// Consumed from a stable cache path (core repo's docs/repo-decomposition.md). The
// compositor links only the `render` SDK (Skia + the text-backend source),
// provisioned by root `tools/nucleus bootstrap`; the
// link list here points at the monorepo core.
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

// libdrm + gbm (renderer surfaces flow through VCR's NucleusRenderer import).
let drmGbmCcFlags = pkgConfig(["--cflags", "libdrm", "gbm"]).flatMap { ["-Xcc", $0] }
let drmGbmLinkFlags = pkgConfig(["--libs", "libdrm", "gbm"])

// Wayland substrate system headers (the NucleusCompositorXcbC / NucleusCompositorInputC façades the
// substrate surfaces #include <xcb/…>/<libinput.h>/… so their dirs must be on
// VCR's clang importer path) + the link set.
let waylandRuntimeCcFlags = pkgConfig(["--cflags", "xcb-ewmh", "libinput", "libudev", "libseat", "xkbcommon"]).flatMap { ["-Xcc", $0] }
let waylandRuntimeLinkFlags = pkgConfig(["--libs", "xcb-ewmh", "xcb", "xcb-icccm", "xcb-composite", "xcb-xfixes", "xcb-res", "libinput", "libudev", "libseat", "xkbcommon"])

// Skia header search paths + feature defines to compile the text backend, and the
// link flags for the GN/Ninja-built Skia archive set (in .skia-build/graphite).
let skiaBridgeCxxFlags: [String] = [
    "-std=c++20", "-DNDEBUG", "-DSK_GRAPHITE", "-DSK_VULKAN",
    "-DSK_GAMMA_APPLY_TO_A8", "-DSK_ALLOW_STATIC_GLOBAL_INITIALIZERS=1",
    "-I", skiaRoot,
    "-I", skiaRoot + "/src",
    "-I", skiaRoot + "/include/third_party/vulkan",
    "-I", skiaRoot + "/src/gpu/vk/vulkanmemoryallocator",
    "-I", skiaRoot + "/third_party/externals/vulkanmemoryallocator/include",
    "-I", skiaRoot + "/third_party/externals/vulkan-headers/include",
]
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

let package = Package(
    name: "NucleusCompositorApp",
    products: [
        .executable(
            name: "NucleusCompositorThreadSanitizerHarness",
            targets: ["NucleusCompositorThreadSanitizerHarness"]),
    ],
    dependencies: [
        // The Nucleus library package — the portable render/UI core. The compositor links
        // zero React, so this is its only Nucleus dependency.
        .package(name: "Nucleus", path: "../../core"),
        .package(name: "swift-tracy", path: "../../swift-tracy"),
        // The Nucleus compositor library — the Linux OS substrate + compositor
        // policy/shell (Wayland/DRM/input, the DRM renderer backend, the window/seat
        // policy, the shell overlay). Consumes core via the @_spi(NucleusCompositor)
        .package(path: "../compositor-core"),
        .package(
            name: "NucleusLinuxPlatform",
            path: "../../platform-linux"),
    ],
    targets: [
        .target(
            name: "NucleusCompositorSignalC",
            path: "Sources/NucleusCompositorSignalC",
            publicHeadersPath: "include"
        ),

        // The DRM primary-node device session (DrmSession): the Swift-authoritative
        // owner of the DRM primary fd, the seat open/close injection point, and the
        // session generation the loop's page-flip poll token carries. Cleaved out of
        // the core NucleusCompositorRenderRuntime target because it references no renderer —
        // only Glibc + injected seat closures — so it belongs to the compositor's
        // session domain, not the portable render graph. Its source lives as a
        // real file under Sources/NucleusCompositorRenderSession.
        .target(
            name: "NucleusCompositorRenderSession",
            path: "Sources/NucleusCompositorRenderSession"
        ),
        .testTarget(
            name: "NucleusCompositorRenderSessionTests",
            dependencies: ["NucleusCompositorRenderSession"],
            path: "Tests/NucleusCompositorRenderSessionTests"
        ),

        // The async composition root: LinuxHostReactor-driven CompositorRuntime
        // and CompositorBringup. Imports the substrate + library graph as products;
        // cxx interop + the renderer/substrate system-header flags.
        .target(
            name: "NucleusCompositorRuntime",
            dependencies: [
                .product(name: "NucleusAppHostBundle", package: "Nucleus"),
                .product(name: "NucleusUI", package: "Nucleus"),
                .product(name: "NucleusTextBackend", package: "Nucleus"),
                .product(name: "NucleusRenderHost", package: "Nucleus"),
                .product(name: "NucleusRenderer", package: "Nucleus"),
                .product(name: "NucleusCompositorRendererLinux", package: "compositor-core"),
                .product(name: "NucleusCompositorRenderRuntime", package: "compositor-core"),
                "NucleusCompositorRenderSession",
                .product(name: "NucleusCompositorWaylandRuntime", package: "compositor-core"),
                .product(name: "NucleusCompositorOverlayTypes", package: "compositor-core"),
                .product(name: "NucleusCompositorOverlayScene", package: "compositor-core"),
                .product(name: "NucleusCompositorServer", package: "compositor-core"),
                .product(name: "NucleusCompositorWindowManager", package: "compositor-core"),
                .product(name: "NucleusCompositorShell", package: "compositor-core"),
                .product(
                    name: "NucleusLinuxDBus",
                    package: "NucleusLinuxPlatform"),
                .product(
                    name: "NucleusLinuxReactor",
                    package: "NucleusLinuxPlatform"),
                .product(
                    name: "NucleusLinuxSession",
                    package: "NucleusLinuxPlatform"),
                .product(name: "Tracy", package: "swift-tracy"),
                "NucleusCompositorSignalC",
            ],
            path: "Sources/NucleusCompositorRuntime",
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags([
                    "-enable-experimental-feature", "Lifetimes",
                    "-Xcc", "-I", "-Xcc",
                    skiaRoot + "/third_party/externals/vulkan-headers/include",
                ] + drmGbmCcFlags + waylandRuntimeCcFlags),
            ]
        ),

        .executableTarget(
            name: "NucleusCompositorThreadSanitizerHarness",
            dependencies: [
                "NucleusCompositorRuntime",
                "NucleusCompositorSignalC",
                .product(
                    name: "NucleusCompositorWaylandTestSupport",
                    package: "compositor-core"),
            ],
            path: "SanitizerHarnesses/NucleusCompositorThreadSanitizerHarness",
            swiftSettings: [.interoperabilityMode(.Cxx)],
            linkerSettings: [
                .unsafeFlags(
                    skiaLinkFlags + drmGbmLinkFlags + waylandRuntimeLinkFlags
                    + ["-lfontconfig", "-lfreetype", "-lz"]
                ),
            ]
        ),

        // The compositor executable. Awaits NucleusCompositorRuntime directly; the
        // final link assembles the whole Swift graph + the text backend + native set:
        // Skia, libdrm/gbm, wayland-server +
        // extension descriptors, xcb/input/seat/udev/xkb, vulkan, fontconfig/freetype/z.
        .executableTarget(
            name: "NucleusCompositor",
            dependencies: [
                "NucleusCompositorRuntime",
                .product(
                    name: "NucleusLinuxSession",
                    package: "NucleusLinuxPlatform"),
            ],
            path: "Sources/NucleusCompositor",
            swiftSettings: [.interoperabilityMode(.Cxx)],
            linkerSettings: [
                .unsafeFlags(
                    skiaLinkFlags + drmGbmLinkFlags + waylandRuntimeLinkFlags
                    + ["-lfontconfig", "-lfreetype", "-lz"]
                ),
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
    target.swiftSettings = (target.swiftSettings ?? []) + [
        .unsafeFlags(["-warnings-as-errors"]),
    ]
    target.cSettings = (target.cSettings ?? []) + [
        .unsafeFlags(["-Werror"]),
    ]
    target.cxxSettings = (target.cxxSettings ?? []) + [
        .unsafeFlags(["-Werror"]),
    ]
}
