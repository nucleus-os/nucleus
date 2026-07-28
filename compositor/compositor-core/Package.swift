// swift-tools-version:6.4
//
// The Nucleus compositor library package — the Linux platform backend extracted
// from the portable core.
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

// ── The Nucleus render native SDK (Skia) ───────────────────────────────────────
// Collider publishes the SDK before invoking SwiftPM. Manifest evaluation is
// deliberately read-only and consumes the one workspace-wide location.
let environment = ProcessInfo.processInfo.environment
guard let nativeSDKRoot = environment["NUCLEUS_NATIVE_SDK_ROOT"],
      !nativeSDKRoot.isEmpty
else {
    fatalError(
        "NUCLEUS_NATIVE_SDK_ROOT is required; run through collider or "
            + "source tools/host-env.sh")
}
let renderSDK = nativeSDKRoot + "/render"
let skiaRoot = renderSDK + "/include/skia"

// Resolve host system-library flags through pkg-config at manifest-evaluation time.
func pkgConfig(_ args: [String]) -> [String] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["pkg-config"] + args
    let output = Pipe()
    let errors = Pipe()
    p.standardOutput = output
    p.standardError = errors
    do {
        try p.run()
    } catch {
        fatalError("could not launch pkg-config: \(error)")
    }
    p.waitUntilExit()
    let out = output.fileHandleForReading.readDataToEndOfFile()
    let errorOutput = String(
        decoding: errors.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self)
    guard p.terminationStatus == 0 else {
        fatalError(
            "pkg-config \(args.joined(separator: " ")) failed: "
                + errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
    }
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

let vulkanHeadersInclude: [String] = [
    "-Xcc", "-I", "-Xcc",
    skiaRoot + "/third_party/externals/vulkan-headers/include",
]

let package = Package(
    name: "compositor-core",
    // Products consumed by the sibling compositor executable package (compositor/).
    products: [
        .library(name: "CompositorColliderRecipe", targets: ["CompositorColliderRecipe"]),
        .library(
            name: "NucleusRenderServer",
            type: .dynamic,
            targets: ["NucleusRenderServer"]),
        .executable(
            name: "NucleusVulkanLaneProbe",
            targets: ["NucleusVulkanLaneProbe"]),
        .executable(
            name: "NucleusRenderServerThreadSanitizerHarness",
            targets: ["NucleusRenderServerThreadSanitizerHarness"]),
        .library(name: "NucleusCompositorRendererLinux", targets: ["NucleusCompositorRendererLinux"]),
        .library(name: "NucleusCompositorRenderRuntime", targets: ["NucleusCompositorRenderRuntime"]),
        .library(name: "NucleusCompositorWaylandRuntime", targets: ["NucleusCompositorWaylandRuntime"]),
        .library(
            name: "NucleusRenderServerTestSupport",
            targets: ["NucleusRenderServerTestSupport"]),
        .library(name: "NucleusCompositorWindowScene", targets: ["NucleusCompositorWindowScene"]),
        .library(name: "NucleusCompositorServerTypes", targets: ["NucleusCompositorServerTypes"]),
        .library(name: "NucleusCompositorServer", targets: ["NucleusCompositorServer"]),
        .library(name: "NucleusCompositorWindowManager", targets: ["NucleusCompositorWindowManager"]),
        .library(name: "NucleusCompositorPolicy", targets: ["NucleusCompositorPolicy"]),
    ],
    dependencies: [
        .package(path: "../../collider/engine"),
        // The Nucleus library package — portable core + app framework (the
        // NucleusUI design system this compositor's shell is built with). This is
        // the compositor's only Nucleus dependency: it links zero React.
        .package(name: "Nucleus", path: "../../core"),
        .package(name: "NucleusFoundation", path: "../../foundation"),
        // The Vulkan bindings, extracted from Nucleus into their own package. Consumed
        // directly (a package cannot re-vend a dependency's product); the renderer and
        // the Graphite bridge import Vulkan / VulkanC.
        .package(name: "swift-vulkan", path: "../../swift-vulkan"),
        // The Wayland protocol bindings, extracted from Nucleus into their own package. The
        // Wayland runtime imports WaylandServerC (server-side) + links WaylandProtocolsC (the
        // shared marshalling); this package no longer generates a Wayland module of its own.
        .package(name: "swift-wayland", path: "../../swift-wayland"),
        .package(
            name: "SwiftWaylandProtocolRuntime",
            path: "../../swift-wayland/protocol-runtime"),
        .package(name: "swift-tracy", path: "../../swift-tracy"),
        // The session configuration model. Shared with the shell and the control
        // CLI, and dependent on none of them.
        .package(name: "NucleusConfigModel", path: "../../config/model"),
        .package(
            name: "NucleusSessionProtocolPackage",
            path: "../../session/protocol"),
        .package(
            name: "NucleusIPCTransportPackage",
            path: "../../ipc/transport"),
        .package(
            name: "NucleusLinuxPlatform",
            path: "../../platform-linux"),
        .package(
            name: "NucleusLinuxDesktopPackage",
            path: "../../platform-linux/desktop"),
    ],
    targets: [
        .target(
            name: "CompositorColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),
        // ── Shared value-type / policy leaves ────────────────────────────────────
        .target(
            name: "NucleusCompositorServerTypes",
            path: "Sources/NucleusCompositorServerTypes",
            swiftSettings: [.strictMemorySafety()]
        ),
        // ── OS-substrate C façades (the pkg-config that used to force into root) ──
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
            name: "NucleusCompositorSignalC",
            path: "Sources/NucleusCompositorSignalC",
            publicHeadersPath: "include"
        ),
        .target(
            name: "NucleusCompositorRenderSession",
            path: "Sources/NucleusCompositorRenderSession"
        ),
        .target(
            name: "WaylandWireTestC",
            path: "Tests/WaylandWireTestC",
            publicHeadersPath: "include"
        ),

        // ── Window/seat policy ─────────────────────────────────────────────
        .target(
            name: "NucleusCompositorServer",
            dependencies: [
                .product(name: "NucleusFoundation", package: "NucleusFoundation"),
                .product(name: "Nucleus", package: "Nucleus"),
                "NucleusCompositorServerTypes",
            ],
            path: "Sources/NucleusCompositorServer",
            swiftSettings: [.strictMemorySafety()]
        ),
        .target(
            name: "NucleusCompositorWindowManager",
            dependencies: [
                .product(name: "NucleusFoundation", package: "NucleusFoundation"),
                .product(name: "Nucleus", package: "Nucleus"),
                "NucleusCompositorServerTypes", "NucleusCompositorServer",
                .product(name: "SwiftTracy", package: "swift-tracy"),
            ],
            path: "Sources/NucleusCompositorWindowManager",
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        .target(
            name: "NucleusCompositorWindowScene",
            dependencies: [
                .product(name: "NucleusFoundation", package: "NucleusFoundation"),
                .product(name: "Nucleus", package: "Nucleus"),
                "NucleusCompositorServerTypes",
            ],
            path: "Sources/NucleusCompositorWindowScene",
            swiftSettings: [.strictMemorySafety()]
        ),
        .target(
            name: "NucleusCompositorPolicy",
            dependencies: [
                "NucleusCompositorServer",
                "NucleusCompositorWindowManager",
                .product(name: "Nucleus", package: "Nucleus"),
                .product(name: "NucleusFoundation", package: "NucleusFoundation"),
                .product(name: "NucleusConfig", package: "NucleusConfigModel"),
                .product(
                    name: "NucleusLinux",
                    package: "NucleusLinuxPlatform"),
                .product(
                    name: "NucleusSessionProtocol",
                    package: "NucleusSessionProtocolPackage"),
            ],
            path: "Sources/NucleusCompositorPolicy",
            swiftSettings: [.interoperabilityMode(.Cxx), .strictMemorySafety()]
        ),

        // ── The Wayland substrate runtime ────────────────────────────────────────
        .target(
            name: "NucleusCompositorWaylandRuntime",
            dependencies: [
                .product(name: "NucleusFoundation", package: "NucleusFoundation"),
                .product(name: "WaylandServerC", package: "swift-wayland"),
                .product(name: "WaylandServer", package: "swift-wayland"),
                .product(name: "WaylandServerDispatch", package: "swift-wayland"),
                .product(
                    name: "SwiftWaylandProtocolRuntime",
                    package: "SwiftWaylandProtocolRuntime"),
                "NucleusCompositorXcbC", "NucleusCompositorInputC",
                "NucleusCompositorServer", "NucleusCompositorWindowManager", "NucleusCompositorServerTypes", "NucleusCompositorWindowScene",
                .product(name: "Nucleus", package: "Nucleus"),
                .product(
                    name: "NucleusLinux",
                    package: "NucleusLinuxPlatform"),
                .product(
                    name: "NucleusConfig",
                    package: "NucleusConfigModel"),
                .product(name: "SwiftTracy", package: "swift-tracy"),
            ],
            path: "Sources/NucleusCompositorWaylandRuntime",
            exclude: ["README.md"],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]),
                .unsafeFlags(waylandRuntimeCcFlags),
            ]
        ),
        .target(
            name: "NucleusRenderServerTestSupport",
            dependencies: [
                "NucleusCompositorWaylandRuntime",
                "NucleusCompositorServer",
                "NucleusCompositorWindowManager",
                "NucleusCompositorWindowScene",
                .product(name: "Nucleus", package: "Nucleus"),
            ],
            path: "Sources/NucleusRenderServerTestSupport",
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]),
            ]
        ),

        // ── The DRM/KMS renderer backend + the render-runtime facade ─────────────
        .target(
            name: "NucleusCompositorRendererLinux",
            dependencies: [
                .product(name: "NucleusFoundation", package: "NucleusFoundation"),
                .product(name: "Nucleus", package: "Nucleus"),
                .product(name: "VulkanC", package: "swift-vulkan"),
                .product(name: "SwiftVulkan", package: "swift-vulkan"),
                .product(name: "SwiftTracy", package: "swift-tracy"),
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
                .product(name: "Nucleus", package: "Nucleus"),
                "NucleusCompositorRendererLinux",
                .product(name: "VulkanC", package: "swift-vulkan"),
                "NucleusCompositorDrmC",
                .product(name: "SwiftTracy", package: "swift-tracy"),
                "NucleusCompositorServer",
            ],
            path: "Sources/NucleusCompositorRenderRuntime",
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags(vulkanHeadersInclude + drmGbmCcFlags),
            ]
        ),
        .target(
            name: "NucleusRenderServerRuntime",
            dependencies: [
                .product(
                    name: "NucleusFoundation",
                    package: "NucleusFoundation"),
                .product(name: "Nucleus", package: "Nucleus"),
                "NucleusCompositorServerTypes",
                "NucleusCompositorServer",
                "NucleusCompositorWindowManager",
                "NucleusCompositorWindowScene",
                "NucleusCompositorPolicy",
                "NucleusCompositorRendererLinux",
                "NucleusCompositorRenderRuntime",
                "NucleusCompositorRenderSession",
                "NucleusCompositorWaylandRuntime",
                "NucleusCompositorSignalC",
                .product(name: "NucleusConfig", package: "NucleusConfigModel"),
                .product(
                    name: "NucleusLinux",
                    package: "NucleusLinuxPlatform"),
                .product(
                    name: "NucleusSessionProtocol",
                    package: "NucleusSessionProtocolPackage"),
                .product(
                    name: "NucleusIPCTransport",
                    package: "NucleusIPCTransportPackage"),
                .product(name: "SwiftTracy", package: "swift-tracy"),
            ],
            path: "Sources/NucleusRenderServerRuntime",
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags([
                    "-enable-experimental-feature", "Lifetimes",
                    "-Xcc", "-I", "-Xcc",
                    skiaRoot + "/third_party/externals/vulkan-headers/include",
                ] + drmGbmCcFlags + waylandRuntimeCcFlags),
            ]),
        .target(
            name: "NucleusRenderServer",
            dependencies: [
                "NucleusRenderServerRuntime",
                .product(
                    name: "NucleusSessionProtocol",
                    package: "NucleusSessionProtocolPackage"),
            ],
            swiftSettings: [.interoperabilityMode(.Cxx)],
            linkerSettings: [
                .unsafeFlags(
                    drmGbmLinkFlags + waylandRuntimeLinkFlags
                        + ["-lfontconfig", "-lfreetype", "-lz"]),
            ]),
        .executableTarget(
            name: "NucleusRenderServerThreadSanitizerHarness",
            dependencies: [
                "NucleusRenderServerRuntime",
                "NucleusCompositorSignalC",
                "NucleusCompositorWaylandRuntime",
                "NucleusRenderServerTestSupport",
            ],
            path:
                "SanitizerHarnesses/NucleusRenderServerThreadSanitizerHarness",
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags(waylandRuntimeCcFlags),
            ],
            linkerSettings: [.unsafeFlags(waylandRuntimeLinkFlags)]),
        .executableTarget(
            name: "NucleusVulkanLaneProbe",
            dependencies: [
                .product(name: "Nucleus", package: "Nucleus"),
                .product(name: "SwiftVulkan", package: "swift-vulkan"),
                .product(name: "VulkanC", package: "swift-vulkan"),
                "NucleusCompositorDrmC",
            ],
            path: "Sources/NucleusVulkanLaneProbe",
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags(vulkanHeadersInclude + drmGbmCcFlags),
            ],
            linkerSettings: [.unsafeFlags(drmGbmLinkFlags)]
        ),

        // ── Tests (relocated with the modules they cover). ───────────────────────
        .testTarget(
            name: "NucleusCompositorRenderSessionTests",
            dependencies: ["NucleusCompositorRenderSession"],
            path: "Tests/NucleusCompositorRenderSessionTests"
        ),
        .testTarget(
            name: "NucleusRenderServerRuntimeTests",
            dependencies: [
                "NucleusRenderServerRuntime",
                .product(name: "NucleusConfig", package: "NucleusConfigModel"),
            ],
            path: "Tests/NucleusRenderServerRuntimeTests",
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags([
                    "-enable-experimental-feature", "Lifetimes",
                    "-Xcc", "-I", "-Xcc",
                    skiaRoot + "/third_party/externals/vulkan-headers/include",
                ] + drmGbmCcFlags + waylandRuntimeCcFlags),
            ],
            linkerSettings: [
                .unsafeFlags(
                    drmGbmLinkFlags + waylandRuntimeLinkFlags
                        + ["-lfontconfig", "-lfreetype", "-lz"]),
            ]
        ),
        .testTarget(
            name: "NucleusCompositorRendererLinuxTests",
            dependencies: [
                "NucleusCompositorRendererLinux",
                .product(name: "Nucleus", package: "Nucleus"),
                .product(
                    name:
                        "NucleusPresentationBackendContractTestSupport",
                    package: "Nucleus"),
                .product(name: "NucleusFoundation", package: "NucleusFoundation"),
                .product(name: "SwiftVulkan", package: "swift-vulkan"),
            ],
            path: "Tests/NucleusCompositorRendererLinuxTests",
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags(vulkanHeadersInclude + drmGbmCcFlags),
            ],
            linkerSettings: [.unsafeFlags(drmGbmLinkFlags)]
        ),
        .testTarget(
            name: "NucleusCompositorRenderRuntimeTests",
            dependencies: [
                "NucleusCompositorRenderRuntime",
                "NucleusCompositorRendererLinux",
                "NucleusCompositorServer",
                .product(name: "Nucleus", package: "Nucleus"),
            ],
            path: "Tests/NucleusCompositorRenderRuntimeTests",
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags(vulkanHeadersInclude + drmGbmCcFlags),
            ],
            linkerSettings: [.unsafeFlags(drmGbmLinkFlags)]
        ),
        .testTarget(
            name: "NucleusCompositorWaylandCTests",
            dependencies: [
                .product(name: "WaylandServerC", package: "swift-wayland"),
                .product(
                    name: "SwiftWaylandProtocolRuntime",
                    package: "SwiftWaylandProtocolRuntime"),
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
                "NucleusCompositorWindowManager", "NucleusCompositorWindowScene",
                .product(name: "NucleusConfig", package: "NucleusConfigModel"),
                .product(name: "Nucleus", package: "Nucleus"),
                // Direct deps on the C façades so their systemLibrary pkgConfig cflags
                // (xcb/libinput include dirs) reach this target's @testable recompile.
                "NucleusCompositorXcbC", "NucleusCompositorInputC",
                .product(name: "WaylandServerC", package: "swift-wayland"),
                .product(name: "WaylandServer", package: "swift-wayland"),
                .product(
                    name: "SwiftWaylandProtocolRuntime",
                    package: "SwiftWaylandProtocolRuntime"),
                "WaylandWireTestC",
            ],
            path: "Tests/NucleusCompositorWaylandRuntimeTests",
            exclude: [
                "WaylandBufferFixture.swift", "WaylandCoreFixture.swift",
                "WaylandDataDeviceFixture.swift", "WaylandDmabufFixture.swift",
                "WaylandGammaFixture.swift",
                "WaylandIdleEffectsFixture.swift", "WaylandLayerShellFixture.swift",
                "WaylandPointerConstraintsFixture.swift", "WaylandPresentationFixture.swift",
                "WaylandRelativePointerFixture.swift", "WaylandRouterFixture.swift",
                "WaylandScreencopyFixture.swift",
                "WaylandSeatFixture.swift", "WaylandSessionLockFixture.swift",
                "WaylandShellAuxFixture.swift", "WaylandSubsurfaceFixture.swift",
                "WaylandSurfaceAuxFixture.swift", "WaylandSurfaceFixture.swift",
                "WaylandSyncobjFixture.swift", "WaylandXdgShellFixture.swift",
                "XwaylandAtomsFixture.swift", "XwaylandPropertiesFixture.swift",
                "XwaylandXSettingsFixture.swift",
            ],
            sources: [
                "WaylandTestGraph.swift", "WaylandWireTest.swift",
                "WaylandTestGlobalCatalog.swift",
                "WaylandProtocolConformanceTests.swift",
                "GammaControlTests.swift",
                "CursorShapeNameTests.swift", "CursorShmRepackTests.swift",
                "CursorRequestSerialTests.swift", "CursorIntentTests.swift",
                "SurfaceCommitGeometryTests.swift", "SurfaceTransactionTests.swift",
                "SubsurfaceTopologyTests.swift",
                "SeatSerialLedgerTests.swift",
                "SeatSessionOwnershipTests.swift",
                "XdgActivationTokenTests.swift",
                "XdgConfigureLedgerTests.swift",
                "XdgPositionerTests.swift",
                "DmabufLayoutValidatorTests.swift",
                "CompositorRenderServiceTests.swift",
                "SceneTransitionTests.swift",
                "DndActionNegotiationTests.swift",
                "XwaylandProcessSecurityTests.swift",
                "InputDeviceSettingsTests.swift",
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]),
                .unsafeFlags(waylandRuntimeCcFlags),
            ],
            linkerSettings: [.unsafeFlags(waylandRuntimeLinkFlags)]
        ),
        .testTarget(
            name: "NucleusCompositorPolicyTests",
            dependencies: [
                "NucleusCompositorPolicy",
                .product(name: "NucleusConfig", package: "NucleusConfigModel"),
                .product(name: "Nucleus", package: "Nucleus"),
            ],
            path: "Tests/NucleusCompositorPolicyTests",
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        // Compositor-root self-hosting topology the scene feeder drives (relocated
        // from the core repo's test tree; covers NucleusCompositorWindowScene).
        .testTarget(
            name: "NucleusCompositorWindowSceneTests",
            dependencies: [
                "NucleusCompositorWindowScene",
                .product(name: "Nucleus", package: "Nucleus"),
            ],
            path: "Tests/NucleusCompositorWindowSceneTests"
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
        .strictMemorySafety(),
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
