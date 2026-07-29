// swift-tools-version: 6.4
//
// Canonical first-party Swift package. Generated once during the package
// consolidation; this manifest is the maintained source of truth.

import Foundation
import PackageDescription

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let environment = ProcessInfo.processInfo.environment
guard let nativeSDKRoot = environment["NUCLEUS_NATIVE_SDK_ROOT"],
    let generatedModuleMaps = environment["NUCLEUS_SWIFTPM_GENERATED_MODULE_MAPS_PATH"],
    let swiftToolchain = environment["SWIFT_TOOLCHAIN"],
    let homeDirectory = environment["HOME"]
else {
    fatalError("source tools/host-env.sh before invoking SwiftPM")
}

func pkgConfig(_ arguments: [String]) -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["pkg-config"] + arguments
    let output = Pipe()
    process.standardOutput = output
    try! process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        fatalError("pkg-config failed: \(arguments)")
    }
    return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        .map(String.init)
}

let icuLibraryDirectory =
    pkgConfig(["--variable=libdir", "icu-uc"]).first
    ?? "/usr/lib"

let isAndroidTarget = environment["NUCLEUS_TARGET_PLATFORM"] == "android"

let hostProducts: [Product] = [
    .library(name: "NucleusAndroidGraphicsContract", targets: ["NucleusAndroidGraphicsContract"]),
    .library(name: "NucleusAndroidIPC", targets: ["NucleusAndroidIPC"]),
    .library(
        name: "NucleusAndroidGfxstreamTransport", targets: ["NucleusAndroidGfxstreamTransport"]),
    .library(
        name: "NucleusAndroidGfxstreamAdapters", targets: ["NucleusAndroidGfxstreamAdaptersCxx"]),
    .library(
        name: "NucleusAndroidGfxstreamGuestTransport",
        targets: ["NucleusAndroidGfxstreamGuestTransportCxx"]),
    .library(name: "NucleusAndroidGfxstreamHost", targets: ["NucleusAndroidGfxstreamHostC"]),
    .library(name: "NucleusAndroidGraphicsPlatform", targets: ["NucleusAndroidGraphicsPlatform"]),
    .library(name: "NucleusAndroidGpuBrokerCore", targets: ["NucleusAndroidGpuBrokerCore"]),
    .library(name: "NucleusAndroidContainerContract", targets: ["NucleusAndroidContainerContract"]),
    .library(name: "NucleusAndroidDisplayHostCore", targets: ["NucleusAndroidDisplayHostCore"]),
    .library(name: "NucleusAndroidSurfaceProbeCore", targets: ["NucleusAndroidSurfaceProbeCore"]),
    .executable(name: "nucleus-android-gpu-broker", targets: ["NucleusAndroidGpuBroker"]),
    .executable(
        name: "nucleus-android-gfxstream-host-probe", targets: ["NucleusAndroidGfxstreamHostProbe"]),
    .executable(
        name: "nucleus-android-gfxstream-workload", targets: ["NucleusAndroidGfxstreamWorkload"]),
    .executable(
        name: "nucleus-android-gfxstream-broker", targets: ["NucleusAndroidGfxstreamBroker"]),
    .executable(name: "nucleus-android-display-host", targets: ["NucleusAndroidDisplayHost"]),
    .executable(
        name: "nucleus-android-shared-ring-stress", targets: ["NucleusAndroidSharedRingStress"]),
    .executable(name: "nucleus-android-surface-probe", targets: ["NucleusAndroidSurfaceProbe"]),
    .executable(
        name: "nucleus-android-presentation-qualifier",
        targets: ["NucleusAndroidPresentationQualifier"]
    ),
    .executable(
        name: "NucleusAndroidThreadSanitizerHarness",
        targets: ["NucleusAndroidThreadSanitizerHarness"]),
    .library(name: "NucleusRenderServer", type: .dynamic, targets: ["NucleusRenderServer"]),
    .executable(name: "NucleusVulkanLaneProbe", targets: ["NucleusVulkanLaneProbe"]),
    .executable(
        name: "NucleusRenderServerThreadSanitizerHarness",
        targets: ["NucleusRenderServerThreadSanitizerHarness"]),
    .library(name: "NucleusCompositorRendererLinux", targets: ["NucleusCompositorRendererLinux"]),
    .library(name: "NucleusCompositorRenderRuntime", targets: ["NucleusCompositorRenderRuntime"]),
    .library(name: "NucleusCompositorWaylandRuntime", targets: ["NucleusCompositorWaylandRuntime"]),
    .library(name: "NucleusRenderServerTestSupport", targets: ["NucleusRenderServerTestSupport"]),
    .library(name: "NucleusCompositorWindowScene", targets: ["NucleusCompositorWindowScene"]),
    .library(name: "NucleusCompositorServerTypes", targets: ["NucleusCompositorServerTypes"]),
    .library(name: "NucleusCompositorServer", targets: ["NucleusCompositorServer"]),
    .library(name: "NucleusCompositorWindowManager", targets: ["NucleusCompositorWindowManager"]),
    .library(name: "NucleusCompositorPolicy", targets: ["NucleusCompositorPolicy"]),
    .library(
        name: "NucleusConfigIO", type: .dynamic,
        targets: ["NucleusConfigIO", "NucleusConfigSyntax"]),
    .executable(name: "NucleusConfigService", targets: ["NucleusConfigServiceExecutable"]),
    .library(name: "NucleusConfig", type: .dynamic, targets: ["NucleusConfig"]),
    .library(
        name: "Nucleus", type: .dynamic,
        targets: [
            "Nucleus", "NucleusApp", "NucleusAppHostBundle", "NucleusLayers", "NucleusRenderHost",
            "NucleusRenderModel", "NucleusRenderer", "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend",
            "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
        ]),
    .library(name: "NucleusAndroidHostLifecycle", targets: ["NucleusAndroidHostLifecycle"]),
    .library(name: "NucleusTextCxxBridge", targets: ["NucleusTextCxxBridge"]),
    .library(name: "NucleusBenchmarkSupport", targets: ["NucleusBenchmarkSupport"]),
    .library(
        name: "NucleusPresentationBackendContractTestSupport", type: .dynamic,
        targets: ["NucleusPresentationBackendContractTestSupport"]),
    .executable(name: "NucleusHeadlessBenchmarks", targets: ["NucleusHeadlessBenchmarks"]),
    .executable(
        name: "NucleusCoreThreadSanitizerHarness", targets: ["NucleusCoreThreadSanitizerHarness"]),
    .library(name: "NucleusDesktop", targets: ["NucleusDesktop"]),
    .library(name: "NucleusFoundation", type: .dynamic, targets: ["NucleusFoundation"]),
    .executable(name: "nucleus", targets: ["NucleusControlCLI"]),
    .library(name: "NucleusControlClient", type: .dynamic, targets: ["NucleusControlClient"]),
    .library(name: "NucleusControlProtocol", type: .dynamic, targets: ["NucleusControlProtocol"]),
    .executable(name: "NucleusControlService", targets: ["NucleusControlServiceExecutable"]),
    .library(
        name: "NucleusIPCTransport", type: .dynamic,
        targets: ["NucleusIPCTransport", "NucleusIPCTransportC"]),
    .library(
        name: "NucleusLinux", type: .dynamic,
        targets: [
            "NucleusLinuxPrimitives", "NucleusLinuxPrimitivesC", "NucleusLinuxReactor",
            "NucleusLinuxReactorC", "NucleusLinuxDBus", "NucleusLinuxSessionC",
            "NucleusThemeAssetIO",
        ]),
    .executable(
        name: "NucleusLinuxThreadSanitizerHarness", targets: ["NucleusLinuxThreadSanitizerHarness"]),
    .library(
        name: "NucleusLinuxDesktop", type: .dynamic,
        targets: ["NucleusLinuxAccessibility", "NucleusLinuxEnvironment"]),
    .executable(name: "NucleusLinuxBenchmarks", targets: ["NucleusLinuxBenchmarks"]),
    .executable(name: "NucleusSessionSupervisor", targets: ["NucleusSessionSupervisor"]),
    .library(name: "NucleusReactRuntime", targets: ["NucleusReactRuntime"]),
    .executable(
        name: "NucleusReactThreadSanitizerHarness", targets: ["NucleusReactThreadSanitizerHarness"]),
    .executable(name: "NucleusReactBenchmarks", targets: ["NucleusReactBenchmarks"]),
    .library(name: "NucleusReactRuntimeCxx", targets: ["NucleusReactRuntimeCxx"]),
    .library(name: "NucleusReactRuntimeHostCxx", targets: ["NucleusReactRuntimeHostCxx"]),
    .library(name: "NucleusSessionProtocol", type: .dynamic, targets: ["NucleusSessionProtocol"]),
    .library(name: "NucleusShellAuthWire", targets: ["NucleusShellAuthWire"]),
    .library(name: "NucleusShellKit", type: .dynamic, targets: ["NucleusShellRuntime"]),
    .library(name: "SwiftTracy", type: .dynamic, targets: ["Tracy"]),
    .library(name: "SwiftVulkan", type: .dynamic, targets: ["Vulkan"]),
    .library(name: "VulkanC", targets: ["VulkanC"]),
    .library(name: "WaylandProtocolModel", targets: ["WaylandProtocolModel"]),
    .library(name: "SwiftWaylandGenerator", targets: ["SwiftWaylandGenerator"]),
    .library(name: "WaylandServerC", targets: ["WaylandServerC"]),
    .library(name: "WaylandClientC", targets: ["WaylandClientC"]),
    .library(name: "WaylandServer", targets: ["WaylandServer"]),
    .library(name: "WaylandServerDispatch", targets: ["WaylandServerDispatch"]),
    .library(name: "WaylandClientDispatch", targets: ["WaylandClientDispatch"]),
    .library(name: "WaylandClient", targets: ["WaylandClient"]),
    .executable(name: "SwiftWaylandGen", targets: ["SwiftWaylandGen"]),
    .library(
        name: "SwiftWaylandProtocolRuntime", type: .dynamic,
        targets: ["SwiftWaylandProtocolRuntime", "WaylandProtocolTypes", "WaylandProtocolsC"]),
    .library(
        name: "NucleusWindowClient", type: .dynamic,
        targets: [
            "NucleusWindowClientContracts", "NucleusWindowClientRuntime",
            "NucleusWindowClientWayland",
            "NucleusWindowClientPasteboard", "NucleusWindowClientRender",
            "NucleusWindowClientInput",
            "NucleusWindowClientHost",
        ]),
]
let androidProducts: [Product] = [
    .library(name: "nucleus-android", type: .dynamic, targets: ["NucleusAndroidJNI"])
]
let hostDependencies: [Package.Dependency] = [
    .package(name: "swift-argument-parser", path: "third-party/swift-argument-parser"),
    .package(name: "swift-syntax", path: "third-party/swift-syntax"),
    .package(name: "swift-system", path: "third-party/swift-system"),
]
let androidDependencies: [Package.Dependency] = [
    .package(name: "swift-java", path: "third-party/swift-java")
]
let hostTargets: [Target] = [
    .target(
        name: "NucleusAndroidProcessLifecycleC",
        path: "android-runtime/Sources/NucleusAndroidProcessLifecycleC",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusAndroidComposerProtocolC",
        path: "android-runtime/aosp/device/nucleus/nucleus_x86_64/native/composer-protocol",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusAndroidSharedRingC",
        path: "android-runtime/aosp/device/nucleus/nucleus_x86_64/native/shared-ring",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusAndroidGfxstreamWorkerProtocolC",
        path: "android-runtime/Sources/NucleusAndroidGfxstreamWorkerProtocolC",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusAndroidGfxstreamGuestTransportCxx",
        dependencies: ["NucleusIPCTransport", "NucleusIPCTransportC", "NucleusAndroidSharedRingC"],
        path: "android-runtime/aosp/device/nucleus/nucleus_x86_64/native/gfxstream-guest",
        cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [
            .unsafeFlags([
                "-I\(repoRoot)/third-party/mesa/src/gfxstream/guest/iostream/include"
            ])
        ],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusAndroidGfxstreamAdaptersCxx",
        dependencies: ["NucleusAndroidGfxstreamGuestTransportCxx", "NucleusAndroidSharedRingC"],
        path: "android-runtime/Sources/NucleusAndroidGfxstreamAdaptersCxx",
        cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [
            .unsafeFlags([
                "-I\(repoRoot)/third-party/mesa/src/gfxstream/guest/iostream/include",
                "-I\(repoRoot)/third-party/gfxstream/host/include",
            ])
        ],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ], linkerSettings: [.linkedLibrary("dl")]),
    .target(
        name: "NucleusAndroidGfxstreamAdaptersTestSupport",
        dependencies: ["NucleusAndroidGfxstreamAdaptersCxx", "NucleusAndroidSharedRingC"],
        path: "android-runtime/Sources/NucleusAndroidGfxstreamAdaptersTestSupport",
        cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [
            .unsafeFlags([
                "-I\(repoRoot)/third-party/mesa/src/gfxstream/guest/iostream/include",
                "-I\(repoRoot)/third-party/gfxstream/host/include",
            ])
        ],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusAndroidGfxstreamHostC",
        dependencies: ["NucleusAndroidGfxstreamAdaptersCxx", "NucleusAndroidSharedRingC"],
        path: "android-runtime/Sources/NucleusAndroidGfxstreamHostC",
        cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [
            .unsafeFlags([
                "-I\(repoRoot)/third-party/gfxstream/host/common/include",
                "-I\(repoRoot)/third-party/gfxstream/host/features/include",
                "-I\(repoRoot)/third-party/gfxstream/host/include",
                "-I\(repoRoot)/third-party/gfxstream/host/iostream/include",
                "-I\(repoRoot)/third-party/gfxstream/host/library/include",
            ])
        ],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ],
        linkerSettings: [
            .unsafeFlags([
                repoRoot + "/android-runtime/.gfxstream-build/host/host/libgfxstream_backend.a",
                "-Xlinker",
                "-rpath", "-Xlinker", swiftToolchain + "/lib",
            ]), .linkedLibrary("dl"), .linkedLibrary("rt"),
        ]),
    .target(
        name: "NucleusAndroidDrmC", path: "android-runtime/Sources/NucleusAndroidDrmC",
        cSettings: [.unsafeFlags(["-I/usr/include/libdrm"]), .unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ], linkerSettings: [.unsafeFlags(["-ldrm", "-lgbm", "-lvulkan"])]),
    .target(
        name: "NucleusAndroidGraphicsContract",
        path: "android-runtime/Sources/NucleusAndroidGraphicsContract",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusAndroidIPC",
        dependencies: [
            "NucleusAndroidGraphicsContract", "NucleusIPCTransport", "NucleusIPCTransportC",
        ], path: "android-runtime/Sources/NucleusAndroidIPC",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusAndroidGfxstreamTransport", dependencies: ["NucleusAndroidSharedRingC"],
        path: "android-runtime/Sources/NucleusAndroidGfxstreamTransport",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusAndroidGraphicsPlatform",
        dependencies: ["NucleusAndroidGraphicsContract", "NucleusAndroidDrmC"],
        path: "android-runtime/Sources/NucleusAndroidGraphicsPlatform",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusAndroidGpuBrokerCore",
        dependencies: [
            "NucleusAndroidGraphicsContract", "NucleusAndroidGraphicsPlatform", "NucleusAndroidIPC",
        ], path: "android-runtime/Sources/NucleusAndroidGpuBrokerCore",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusAndroidContainerContract",
        path: "android-runtime/Sources/NucleusAndroidContainerContract",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .executableTarget(
        name: "NucleusAndroidGpuBroker",
        dependencies: [
            "NucleusAndroidGraphicsContract", "NucleusAndroidGraphicsPlatform",
            "NucleusAndroidGpuBrokerCore", "NucleusAndroidIPC", "NucleusAndroidProcessLifecycleC",
            "NucleusIPCTransport", "NucleusIPCTransportC", "NucleusAndroidGfxstreamWorkerProtocolC",
            "NucleusLinuxPrimitives", "NucleusLinuxPrimitivesC", "NucleusLinuxReactor",
            "NucleusLinuxReactorC", "NucleusLinuxDBus", "NucleusLinuxSessionC",
            "NucleusThemeAssetIO",
        ], path: "android-runtime/Sources/NucleusAndroidGpuBroker",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .executableTarget(
        name: "NucleusAndroidGfxstreamHostProbe",
        dependencies: ["NucleusAndroidDrmC", "NucleusAndroidGfxstreamHostC"],
        path: "android-runtime/Sources/NucleusAndroidGfxstreamHostProbe",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .executableTarget(
        name: "NucleusAndroidGfxstreamWorkload",
        dependencies: [
            "NucleusAndroidDrmC", "NucleusAndroidGfxstreamAdaptersCxx",
            "NucleusAndroidGfxstreamHostC",
            "NucleusAndroidProcessLifecycleC", "NucleusIPCTransport", "NucleusIPCTransportC",
            "NucleusAndroidSharedRingC", "NucleusAndroidGfxstreamWorkerProtocolC",
        ], path: "android-runtime/Sources/NucleusAndroidGfxstreamWorkload",
        cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [
            .define(
                "NUCLEUS_ANDROID_GFXSTREAM_GUEST_ICD=\"\(repoRoot)/android-runtime/.gfxstream-build/guest/src/gfxstream/guest/vulkan/libvulkan_gfxstream.so\""
            ),
            .unsafeFlags([
                "-I\(repoRoot)/third-party/mesa/src/gfxstream/guest/vulkan_enc"
            ]),
        ],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ], linkerSettings: [.linkedLibrary("dl"), .linkedLibrary("pthread")]),
    .executableTarget(
        name: "NucleusAndroidGfxstreamBroker",
        dependencies: [
            "NucleusAndroidDrmC", "NucleusAndroidGfxstreamGuestTransportCxx",
            "NucleusAndroidGfxstreamHostC", "NucleusAndroidProcessLifecycleC",
            "NucleusIPCTransport",
            "NucleusIPCTransportC", "NucleusAndroidSharedRingC",
        ], path: "android-runtime/Sources/NucleusAndroidGfxstreamBroker",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ],
        linkerSettings: [
            .linkedLibrary("pthread"), .unsafeFlags(["-Xlinker", "--export-dynamic"]),
        ]),
    .executableTarget(
        name: "NucleusAndroidDisplayHost", dependencies: ["NucleusAndroidDisplayHostCore"],
        path: "android-runtime/Sources/NucleusAndroidDisplayHost",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusAndroidDisplayHostCore",
        dependencies: [
            "NucleusAndroidComposerProtocolC", "NucleusAndroidDrmC",
            "NucleusAndroidGraphicsContract",
            "NucleusAndroidGraphicsPlatform", "NucleusAndroidProcessLifecycleC",
            "NucleusIPCTransport",
            "NucleusIPCTransportC", "NucleusLinuxPrimitives", "NucleusLinuxPrimitivesC",
            "NucleusLinuxReactor", "NucleusLinuxReactorC", "NucleusLinuxDBus",
            "NucleusLinuxSessionC",
            "NucleusThemeAssetIO", "WaylandClient", "WaylandClientC", "WaylandClientDispatch",
            "SwiftWaylandProtocolRuntime", "WaylandProtocolTypes", "WaylandProtocolsC",
        ], path: "android-runtime/Sources/NucleusAndroidDisplayHostCore",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx),
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]),
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .executableTarget(
        name: "NucleusAndroidSharedRingStress", dependencies: ["NucleusAndroidSharedRingC"],
        path: "android-runtime/Sources/NucleusAndroidSharedRingStress",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .executableTarget(
        name: "NucleusAndroidSurfaceProbe", dependencies: ["NucleusAndroidSurfaceProbeCore"],
        path: "android-runtime/Sources/NucleusAndroidSurfaceProbe",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusAndroidPresentationQualification",
        dependencies: ["NucleusAndroidSurfaceProbeCore"],
        path: "android-runtime/Sources/NucleusAndroidPresentationQualification",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .executableTarget(
        name: "NucleusAndroidPresentationQualifier",
        dependencies: ["NucleusAndroidPresentationQualification"],
        path: "android-runtime/Sources/NucleusAndroidPresentationQualifier",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusAndroidSurfaceProbeCore",
        dependencies: [
            "NucleusAndroidGraphicsContract", "NucleusAndroidIPC", "NucleusAndroidDrmC",
            "NucleusLinuxPrimitives", "NucleusLinuxPrimitivesC", "NucleusLinuxReactor",
            "NucleusLinuxReactorC", "NucleusLinuxDBus", "NucleusLinuxSessionC",
            "NucleusThemeAssetIO",
            "WaylandClient", "WaylandClientC", "WaylandClientDispatch",
            "SwiftWaylandProtocolRuntime",
            "WaylandProtocolTypes", "WaylandProtocolsC",
        ], path: "android-runtime/Sources/NucleusAndroidSurfaceProbeCore",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx),
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]),
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusAndroidGraphicsContractTests",
        dependencies: ["NucleusAndroidGraphicsContract"],
        path: "android-runtime/Tests/NucleusAndroidGraphicsContractTests",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusAndroidContainerContractTests",
        dependencies: ["NucleusAndroidContainerContract"],
        path: "android-runtime/Tests/NucleusAndroidContainerContractTests",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusAndroidIPCTests",
        dependencies: ["NucleusAndroidGraphicsContract", "NucleusAndroidIPC"],
        path: "android-runtime/Tests/NucleusAndroidIPCTests",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusAndroidGfxstreamTransportTests",
        dependencies: ["NucleusAndroidGfxstreamTransport"],
        path: "android-runtime/Tests/NucleusAndroidGfxstreamTransportTests",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusAndroidGfxstreamAdaptersTests",
        dependencies: ["NucleusAndroidGfxstreamAdaptersTestSupport"],
        path: "android-runtime/Tests/NucleusAndroidGfxstreamAdaptersTests",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusAndroidGraphicsPlatformTests",
        dependencies: [
            "NucleusAndroidDrmC", "NucleusAndroidDrmCTestSupport", "NucleusAndroidGraphicsContract",
            "NucleusAndroidGraphicsPlatform",
        ], path: "android-runtime/Tests/NucleusAndroidGraphicsPlatformTests",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusAndroidDrmCTestSupport", dependencies: ["NucleusAndroidDrmC"],
        path: "android-runtime/Tests/Support/NucleusAndroidDrmCTestSupport",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .executableTarget(
        name: "NucleusAndroidThreadSanitizerHarness",
        dependencies: [
            "NucleusAndroidDrmC", "NucleusAndroidDrmCTestSupport",
            "NucleusAndroidGfxstreamTransport",
        ], path: "android-runtime/SanitizerHarnesses/NucleusAndroidThreadSanitizerHarness",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusAndroidGpuBrokerCoreTests",
        dependencies: [
            "NucleusAndroidGraphicsContract", "NucleusAndroidGraphicsPlatform",
            "NucleusAndroidGpuBrokerCore", "NucleusAndroidIPC",
        ], path: "android-runtime/Tests/NucleusAndroidGpuBrokerCoreTests",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusAndroidSurfaceProbeCoreTests",
        dependencies: ["NucleusAndroidGraphicsContract", "NucleusAndroidSurfaceProbeCore"],
        path: "android-runtime/Tests/NucleusAndroidSurfaceProbeCoreTests",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusAndroidDisplayHostCoreTests",
        dependencies: [
            "NucleusAndroidDisplayHostCore", "NucleusIPCTransport", "NucleusIPCTransportC",
            "NucleusLinuxPrimitives", "NucleusLinuxPrimitivesC", "NucleusLinuxReactor",
            "NucleusLinuxReactorC", "NucleusLinuxDBus", "NucleusLinuxSessionC",
            "NucleusThemeAssetIO",
        ], path: "android-runtime/Tests/NucleusAndroidDisplayHostCoreTests",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusCompositorServerTypes",
        path: "compositor/compositor-core/Sources/NucleusCompositorServerTypes",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .systemLibrary(
        name: "NucleusCompositorDrmC",
        path: "compositor/compositor-core/Sources/NucleusCompositorDrmC",
        pkgConfig: "libdrm"),
    .systemLibrary(
        name: "NucleusCompositorXcbC",
        path: "compositor/compositor-core/Sources/NucleusCompositorXcbC",
        pkgConfig: "xcb-ewmh"),
    .systemLibrary(
        name: "NucleusCompositorInputC",
        path: "compositor/compositor-core/Sources/NucleusCompositorInputC"),
    .target(
        name: "NucleusCompositorSignalC",
        path: "compositor/compositor-core/Sources/NucleusCompositorSignalC",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusCompositorRenderSession",
        path: "compositor/compositor-core/Sources/NucleusCompositorRenderSession",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "WaylandWireTestC", path: "compositor/compositor-core/Tests/WaylandWireTestC",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusCompositorServer",
        dependencies: [
            "NucleusFoundation", "Nucleus", "NucleusApp", "NucleusAppHostBundle", "NucleusLayers",
            "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend", "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
            "NucleusCompositorServerTypes",
        ], path: "compositor/compositor-core/Sources/NucleusCompositorServer",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusCompositorWindowManager",
        dependencies: [
            "NucleusFoundation", "Nucleus", "NucleusApp", "NucleusAppHostBundle", "NucleusLayers",
            "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend", "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
            "NucleusCompositorServerTypes", "NucleusCompositorServer", "Tracy",
        ], path: "compositor/compositor-core/Sources/NucleusCompositorWindowManager",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusCompositorWindowScene",
        dependencies: [
            "NucleusFoundation", "Nucleus", "NucleusApp", "NucleusAppHostBundle", "NucleusLayers",
            "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend", "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
            "NucleusCompositorServerTypes",
        ], path: "compositor/compositor-core/Sources/NucleusCompositorWindowScene",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusCompositorPolicy",
        dependencies: [
            "NucleusCompositorServer", "NucleusCompositorWindowManager", "Nucleus", "NucleusApp",
            "NucleusAppHostBundle", "NucleusLayers", "NucleusRenderHost", "NucleusRenderModel",
            "NucleusRenderer", "NucleusSkiaGraphiteBridge", "NucleusTextBackend",
            "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder", "NucleusFoundation",
            "NucleusConfig", "NucleusLinuxPrimitives", "NucleusLinuxPrimitivesC",
            "NucleusLinuxReactor",
            "NucleusLinuxReactorC", "NucleusLinuxDBus", "NucleusLinuxSessionC",
            "NucleusThemeAssetIO",
            "NucleusSessionProtocol",
        ], path: "compositor/compositor-core/Sources/NucleusCompositorPolicy",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusCompositorWaylandRuntime",
        dependencies: [
            "NucleusFoundation", "WaylandServerC", "WaylandServer", "WaylandServerDispatch",
            "SwiftWaylandProtocolRuntime", "WaylandProtocolTypes", "WaylandProtocolsC",
            "NucleusCompositorXcbC", "NucleusCompositorInputC", "NucleusCompositorServer",
            "NucleusCompositorWindowManager", "NucleusCompositorServerTypes",
            "NucleusCompositorWindowScene", "Nucleus", "NucleusApp", "NucleusAppHostBundle",
            "NucleusLayers", "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge", "NucleusTextBackend", "NucleusTextRenderingBridge",
            "NucleusUI",
            "NucleusUIEmbedder", "NucleusLinuxPrimitives", "NucleusLinuxPrimitivesC",
            "NucleusLinuxReactor", "NucleusLinuxReactorC", "NucleusLinuxDBus",
            "NucleusLinuxSessionC",
            "NucleusThemeAssetIO", "NucleusConfig", "Tracy",
        ], path: "compositor/compositor-core/Sources/NucleusCompositorWaylandRuntime",
        exclude: ["README.md"], cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx),
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]),
            .unsafeFlags([]), .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusRenderServerTestSupport",
        dependencies: [
            "NucleusCompositorWaylandRuntime", "NucleusCompositorServer",
            "NucleusCompositorWindowManager", "NucleusCompositorWindowScene", "Nucleus",
            "NucleusApp",
            "NucleusAppHostBundle", "NucleusLayers", "NucleusRenderHost", "NucleusRenderModel",
            "NucleusRenderer", "NucleusSkiaGraphiteBridge", "NucleusTextBackend",
            "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
        ], path: "compositor/compositor-core/Sources/NucleusRenderServerTestSupport",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx),
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]),
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusCompositorRendererLinux",
        dependencies: [
            "NucleusFoundation", "Nucleus", "NucleusApp", "NucleusAppHostBundle", "NucleusLayers",
            "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend", "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
            "VulkanC", "Vulkan", "Tracy", "NucleusCompositorDrmC",
        ], path: "compositor/compositor-core/Sources/NucleusCompositorRendererLinux",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx),
            .unsafeFlags([
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/render/include/skia/third_party/externals/vulkan-headers/include",
                "-Xcc",
                "-I/usr/include/libdrm",
            ]), .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ], linkerSettings: [.unsafeFlags(["-ldrm", "-lgbm"])]),
    .target(
        name: "NucleusCompositorRenderRuntime",
        dependencies: [
            "Nucleus", "NucleusApp", "NucleusAppHostBundle", "NucleusLayers", "NucleusRenderHost",
            "NucleusRenderModel", "NucleusRenderer", "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend",
            "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
            "NucleusCompositorRendererLinux", "VulkanC", "NucleusCompositorDrmC", "Tracy",
            "NucleusCompositorServer",
        ], path: "compositor/compositor-core/Sources/NucleusCompositorRenderRuntime",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx),
            .unsafeFlags([
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/render/include/skia/third_party/externals/vulkan-headers/include",
                "-Xcc",
                "-I/usr/include/libdrm",
            ]), .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusRenderServerRuntime",
        dependencies: [
            "NucleusFoundation", "Nucleus", "NucleusApp", "NucleusAppHostBundle", "NucleusLayers",
            "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend", "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
            "NucleusCompositorServerTypes", "NucleusCompositorServer",
            "NucleusCompositorWindowManager",
            "NucleusCompositorWindowScene", "NucleusCompositorPolicy",
            "NucleusCompositorRendererLinux",
            "NucleusCompositorRenderRuntime", "NucleusCompositorRenderSession",
            "NucleusCompositorWaylandRuntime", "NucleusCompositorSignalC", "NucleusConfig",
            "NucleusLinuxPrimitives", "NucleusLinuxPrimitivesC", "NucleusLinuxReactor",
            "NucleusLinuxReactorC", "NucleusLinuxDBus", "NucleusLinuxSessionC",
            "NucleusThemeAssetIO",
            "NucleusSessionProtocol", "NucleusIPCTransport", "NucleusIPCTransportC", "Tracy",
        ], path: "compositor/compositor-core/Sources/NucleusRenderServerRuntime",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx),
            .unsafeFlags([
                "-enable-experimental-feature", "Lifetimes", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/render/include/skia/third_party/externals/vulkan-headers/include",
                "-Xcc",
                "-I/usr/include/libdrm",
            ]), .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusRenderServer",
        dependencies: ["NucleusRenderServerRuntime", "NucleusSessionProtocol"],
        path: "compositor/compositor-core/Sources/NucleusRenderServer",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ],
        linkerSettings: [
            .unsafeFlags([
                "-ldrm", "-lgbm", "-lxcb-ewmh", "-lxcb-icccm", "-lxcb-composite", "-lxcb-xfixes",
                "-lxcb-res", "-lxcb", "-linput", "-ludev", "-lseat", "-lxkbcommon", "-lfontconfig",
                "-lfreetype", "-lz",
            ])
        ]),
    .executableTarget(
        name: "NucleusRenderServerThreadSanitizerHarness",
        dependencies: [
            "NucleusRenderServerRuntime", "NucleusCompositorSignalC",
            "NucleusCompositorWaylandRuntime",
            "NucleusRenderServerTestSupport",
        ],
        path:
            "compositor/compositor-core/SanitizerHarnesses/NucleusRenderServerThreadSanitizerHarness",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .unsafeFlags([]), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ],
        linkerSettings: [
            .unsafeFlags([
                "-lxcb-ewmh", "-lxcb-icccm", "-lxcb-composite", "-lxcb-xfixes", "-lxcb-res",
                "-lxcb",
                "-linput", "-ludev", "-lseat", "-lxkbcommon",
            ])
        ]),
    .executableTarget(
        name: "NucleusVulkanLaneProbe",
        dependencies: [
            "Nucleus", "NucleusApp", "NucleusAppHostBundle", "NucleusLayers", "NucleusRenderHost",
            "NucleusRenderModel", "NucleusRenderer", "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend",
            "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder", "Vulkan", "VulkanC",
            "NucleusCompositorDrmC",
        ], path: "compositor/compositor-core/Sources/NucleusVulkanLaneProbe",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx),
            .unsafeFlags([
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/render/include/skia/third_party/externals/vulkan-headers/include",
                "-Xcc",
                "-I/usr/include/libdrm",
            ]), .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ], linkerSettings: [.unsafeFlags(["-ldrm", "-lgbm"])]),
    .testTarget(
        name: "NucleusCompositorRenderSessionTests",
        dependencies: ["NucleusCompositorRenderSession"],
        path: "compositor/compositor-core/Tests/NucleusCompositorRenderSessionTests",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusRenderServerRuntimeTests",
        dependencies: ["NucleusRenderServerRuntime", "NucleusConfig"],
        path: "compositor/compositor-core/Tests/NucleusRenderServerRuntimeTests",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx),
            .unsafeFlags([
                "-enable-experimental-feature", "Lifetimes", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/render/include/skia/third_party/externals/vulkan-headers/include",
                "-Xcc",
                "-I/usr/include/libdrm",
            ]), .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ],
        linkerSettings: [
            .unsafeFlags([
                "-ldrm", "-lgbm", "-lxcb-ewmh", "-lxcb-icccm", "-lxcb-composite", "-lxcb-xfixes",
                "-lxcb-res", "-lxcb", "-linput", "-ludev", "-lseat", "-lxkbcommon", "-lfontconfig",
                "-lfreetype", "-lz",
            ])
        ]),
    .testTarget(
        name: "NucleusCompositorRendererLinuxTests",
        dependencies: [
            "NucleusCompositorRendererLinux", "Nucleus", "NucleusApp", "NucleusAppHostBundle",
            "NucleusLayers", "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge", "NucleusTextBackend", "NucleusTextRenderingBridge",
            "NucleusUI",
            "NucleusUIEmbedder", "NucleusPresentationBackendContractTestSupport",
            "NucleusFoundation",
            "Vulkan",
        ], path: "compositor/compositor-core/Tests/NucleusCompositorRendererLinuxTests",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx),
            .unsafeFlags([
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/render/include/skia/third_party/externals/vulkan-headers/include",
                "-Xcc",
                "-I/usr/include/libdrm",
            ]), .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ], linkerSettings: [.unsafeFlags(["-ldrm", "-lgbm"])]),
    .testTarget(
        name: "NucleusCompositorRenderRuntimeTests",
        dependencies: [
            "NucleusCompositorRenderRuntime", "NucleusCompositorRendererLinux",
            "NucleusCompositorServer",
            "Nucleus", "NucleusApp", "NucleusAppHostBundle", "NucleusLayers", "NucleusRenderHost",
            "NucleusRenderModel", "NucleusRenderer", "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend",
            "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
        ], path: "compositor/compositor-core/Tests/NucleusCompositorRenderRuntimeTests",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx),
            .unsafeFlags([
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/render/include/skia/third_party/externals/vulkan-headers/include",
                "-Xcc",
                "-I/usr/include/libdrm",
            ]), .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ], linkerSettings: [.unsafeFlags(["-ldrm", "-lgbm"])]),
    .testTarget(
        name: "NucleusCompositorWaylandCTests",
        dependencies: [
            "WaylandServerC", "SwiftWaylandProtocolRuntime", "WaylandProtocolTypes",
            "WaylandProtocolsC",
        ], path: "compositor/compositor-core/Tests/NucleusCompositorWaylandCTests",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusCompositorServerTests", dependencies: ["NucleusCompositorServer"],
        path: "compositor/compositor-core/Tests/NucleusCompositorServerTests",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusCompositorWindowManagerTests",
        dependencies: ["NucleusCompositorServer", "NucleusCompositorWindowManager"],
        path: "compositor/compositor-core/Tests/NucleusCompositorWindowManagerTests",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusCompositorWaylandRuntimeTests",
        dependencies: [
            "NucleusCompositorWaylandRuntime", "NucleusCompositorServer",
            "NucleusCompositorWindowManager", "NucleusCompositorWindowScene", "NucleusConfig",
            "Nucleus",
            "NucleusApp", "NucleusAppHostBundle", "NucleusLayers", "NucleusRenderHost",
            "NucleusRenderModel", "NucleusRenderer", "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend",
            "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder", "NucleusCompositorXcbC",
            "NucleusCompositorInputC", "WaylandServerC", "WaylandServer",
            "SwiftWaylandProtocolRuntime",
            "WaylandProtocolTypes", "WaylandProtocolsC", "WaylandWireTestC",
        ], path: "compositor/compositor-core/Tests/NucleusCompositorWaylandRuntimeTests",
        exclude: [
            "WaylandBufferFixture.swift", "WaylandCoreFixture.swift",
            "WaylandDataDeviceFixture.swift",
            "WaylandDmabufFixture.swift", "WaylandGammaFixture.swift",
            "WaylandIdleEffectsFixture.swift",
            "WaylandLayerShellFixture.swift", "WaylandPointerConstraintsFixture.swift",
            "WaylandPresentationFixture.swift", "WaylandRelativePointerFixture.swift",
            "WaylandRouterFixture.swift", "WaylandScreencopyFixture.swift",
            "WaylandSeatFixture.swift",
            "WaylandSessionLockFixture.swift", "WaylandShellAuxFixture.swift",
            "WaylandSubsurfaceFixture.swift", "WaylandSurfaceAuxFixture.swift",
            "WaylandSurfaceFixture.swift", "WaylandSyncobjFixture.swift",
            "WaylandXdgShellFixture.swift",
            "XwaylandAtomsFixture.swift", "XwaylandPropertiesFixture.swift",
            "XwaylandXSettingsFixture.swift",
        ], cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx),
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]),
            .unsafeFlags([]), .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ],
        linkerSettings: [
            .unsafeFlags([
                "-lxcb-ewmh", "-lxcb-icccm", "-lxcb-composite", "-lxcb-xfixes", "-lxcb-res",
                "-lxcb",
                "-linput", "-ludev", "-lseat", "-lxkbcommon",
            ])
        ]),
    .testTarget(
        name: "NucleusCompositorPolicyTests",
        dependencies: [
            "NucleusCompositorPolicy", "NucleusConfig", "Nucleus", "NucleusApp",
            "NucleusAppHostBundle",
            "NucleusLayers", "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge", "NucleusTextBackend", "NucleusTextRenderingBridge",
            "NucleusUI",
            "NucleusUIEmbedder",
        ], path: "compositor/compositor-core/Tests/NucleusCompositorPolicyTests",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusCompositorWindowSceneTests",
        dependencies: [
            "NucleusCompositorWindowScene", "Nucleus", "NucleusApp", "NucleusAppHostBundle",
            "NucleusLayers", "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge", "NucleusTextBackend", "NucleusTextRenderingBridge",
            "NucleusUI",
            "NucleusUIEmbedder",
        ], path: "compositor/compositor-core/Tests/NucleusCompositorWindowSceneTests",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .executableTarget(
        name: "NucleusCompositor",
        dependencies: ["NucleusRenderServer", "NucleusFoundation", "NucleusSessionProtocol"],
        path: "compositor/compositor/Sources/NucleusCompositor",
        cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ], linkerSettings: [.unsafeFlags(["-Xlinker", "--as-needed"])]),
    .target(
        name: "NucleusConfigSyntax", path: "config/Sources/NucleusConfigSyntax",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusConfigSyntaxTests", dependencies: ["NucleusConfigSyntax"],
        path: "config/Tests/NucleusConfigSyntaxTests", cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusConfigIO", dependencies: ["NucleusConfigSyntax", "NucleusConfig"],
        path: "config/Sources/NucleusConfigIO", cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusConfigTests",
        dependencies: ["NucleusConfigIO", "NucleusConfigSyntax", "NucleusConfig"],
        path: "config/Tests/NucleusConfigTests", cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusConfigService",
        dependencies: [
            "NucleusConfig", "NucleusConfigIO", "NucleusConfigSyntax", "NucleusLinuxPrimitives",
            "NucleusLinuxPrimitivesC", "NucleusLinuxReactor", "NucleusLinuxReactorC",
            "NucleusLinuxDBus",
            "NucleusLinuxSessionC", "NucleusThemeAssetIO", "NucleusSessionProtocol",
        ], path: "config/config-service-core/Sources/NucleusConfigService",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusConfigServiceTests", dependencies: ["NucleusConfigService"],
        path: "config/config-service-core/Tests/NucleusConfigServiceTests",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .executableTarget(
        name: "NucleusConfigServiceExecutable", dependencies: ["NucleusConfigService"],
        path: "config/config-service/Sources/NucleusConfigServiceExecutable",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusConfig", path: "config/model/Sources/NucleusConfig",
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusConfigModelTests", dependencies: ["NucleusConfig"],
        path: "config/model/Tests/NucleusConfigModelTests",
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "Nucleus", dependencies: ["NucleusApp", "NucleusUI", "NucleusFoundation"],
        path: "core/swift/Sources/Nucleus", cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ],
        linkerSettings: [
            .unsafeFlags(
                [
                    "-L", nativeSDKRoot + "/render/lib/skia-graphite", "-Xlinker", "--start-group",
                    "-lskia",
                    "-lskshaper", "-lskparagraph", "-lskunicode_core", "-lskunicode_icu", "-lsvg",
                    "-lskcms",
                    "-lskresources", "-lfreetype2", "-lharfbuzz", "-licu", "-lpng", "-ljpeg",
                    "-ljpeg12",
                    "-ljpeg16", "-lwebp", "-lwebp_sse41", "-lexpat", "-lzlib", "-lwuffs",
                    "-ldng_sdk",
                    "-lpiex", "-Xlinker", "--end-group", "-lvulkan", "-lfontconfig", "-lfreetype",
                    "-lz",
                    "-ldl", "-lpthread", "-lm", "-Xlinker", "--exclude-libs=ALL", "-Xlinker",
                    "--no-undefined", "-Xlinker", "-z", "-Xlinker", "relro", "-Xlinker", "-z",
                    "-Xlinker",
                    "now",
                ], .when(platforms: [.linux]))
        ]),
    .target(
        name: "NucleusAndroidHostLifecycle", path: "core/swift/Sources/NucleusAndroidHostLifecycle",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusLayers", dependencies: ["NucleusFoundation"],
        path: "core/swift/Sources/NucleusLayers", cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .define("NUCLEUS_LAYERS_PUBLIC_NAMES"), .strictMemorySafety(), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .systemLibrary(
        name: "NucleusTextCxxBridge", path: "core/swiftpm/cmodules/NucleusTextCxxBridge"),
    .target(
        name: "NucleusTextBackendNative", path: "core/render-cxx/skia",
        cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [
            .unsafeFlags(
                [
                    "-std=c++20", "-DNDEBUG", "-DSK_GRAPHITE", "-DSK_VULKAN",
                    "-DSK_GAMMA_APPLY_TO_A8",
                    "-DSK_ALLOW_STATIC_GLOBAL_INITIALIZERS=1", "-I",
                    nativeSDKRoot + "/render/include/skia",
                    "-I", nativeSDKRoot + "/render/include/skia/src", "-I",
                    nativeSDKRoot + "/render/include/skia/include/third_party/vulkan", "-I",
                    nativeSDKRoot + "/render/include/skia/src/gpu/vk/vulkanmemoryallocator", "-I",
                    nativeSDKRoot
                        + "/render/include/skia/third_party/externals/vulkanmemoryallocator/include",
                    "-I",
                    nativeSDKRoot
                        + "/render/include/skia/third_party/externals/vulkan-headers/include",
                ], .when(platforms: [.linux])),
            .unsafeFlags(
                [
                    "-std=c++20", "-DNDEBUG", "-DSK_GRAPHITE", "-DSK_VULKAN",
                    "-DSK_GAMMA_APPLY_TO_A8",
                    "-DSK_ALLOW_STATIC_GLOBAL_INITIALIZERS=1", "-I",
                    nativeSDKRoot + "/render/include/skia",
                    "-I", nativeSDKRoot + "/render/include/skia/src", "-I",
                    nativeSDKRoot + "/render/include/skia/include/third_party/vulkan", "-I",
                    nativeSDKRoot + "/render/include/skia/src/gpu/vk/vulkanmemoryallocator", "-I",
                    nativeSDKRoot
                        + "/render/include/skia/third_party/externals/vulkanmemoryallocator/include",
                    "-I",
                    nativeSDKRoot
                        + "/render/include/skia/third_party/externals/vulkan-headers/include",
                ], .when(platforms: [.android])), .unsafeFlags(["-Werror"]),
        ],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusTextBackend",
        dependencies: [
            "NucleusUI", "NucleusTextCxxBridge", "NucleusTextBackendNative",
            "NucleusTextRenderingBridge",
            "Tracy",
        ], path: "core/swift/Sources/NucleusTextBackend", cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusUI",
        dependencies: ["NucleusLayers", "NucleusSecureMemoryC", "NucleusFoundation", "Tracy"],
        path: "core/swift/Sources/NucleusUI", cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusSecureMemoryC", path: "core/swift/Sources/NucleusSecureMemoryC",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusUIEmbedder",
        dependencies: ["NucleusUI", "NucleusLayers", "NucleusFoundation"],
        path: "core/swift/Sources/NucleusUIEmbedder", cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusApp", dependencies: ["NucleusUI", "NucleusLayers", "NucleusFoundation"],
        path: "core/swift/Sources/NucleusApp", cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusRenderModel", dependencies: ["NucleusFoundation"],
        path: "core/swift/Sources/NucleusRenderModel", cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusAppHostBundle",
        dependencies: ["NucleusLayers", "NucleusRenderModel", "NucleusFoundation"],
        path: "core/swift/Sources/NucleusAppHostBundle", cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusSkiaGraphiteBridge", path: "core/swift/Sources/NucleusSkiaGraphite/cxx",
        cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [
            .unsafeFlags(
                [
                    "-std=c++20", "-DNDEBUG", "-DSK_GRAPHITE", "-DSK_VULKAN",
                    "-DSK_GAMMA_APPLY_TO_A8",
                    "-DSK_ALLOW_STATIC_GLOBAL_INITIALIZERS=1", "-I",
                    nativeSDKRoot + "/render/include/skia",
                    "-I", nativeSDKRoot + "/render/include/skia/src", "-I",
                    nativeSDKRoot + "/render/include/skia/include/third_party/vulkan", "-I",
                    nativeSDKRoot + "/render/include/skia/src/gpu/vk/vulkanmemoryallocator", "-I",
                    nativeSDKRoot
                        + "/render/include/skia/third_party/externals/vulkanmemoryallocator/include",
                    "-I",
                    nativeSDKRoot
                        + "/render/include/skia/third_party/externals/vulkan-headers/include",
                ], .when(platforms: [.linux])),
            .unsafeFlags(
                [
                    "-std=c++20", "-DNDEBUG", "-DSK_GRAPHITE", "-DSK_VULKAN",
                    "-DSK_GAMMA_APPLY_TO_A8",
                    "-DSK_ALLOW_STATIC_GLOBAL_INITIALIZERS=1", "-I",
                    nativeSDKRoot + "/render/include/skia",
                    "-I", nativeSDKRoot + "/render/include/skia/src", "-I",
                    nativeSDKRoot + "/render/include/skia/include/third_party/vulkan", "-I",
                    nativeSDKRoot + "/render/include/skia/src/gpu/vk/vulkanmemoryallocator", "-I",
                    nativeSDKRoot
                        + "/render/include/skia/third_party/externals/vulkanmemoryallocator/include",
                    "-I",
                    nativeSDKRoot
                        + "/render/include/skia/third_party/externals/vulkan-headers/include",
                ], .when(platforms: [.android])), .unsafeFlags(["-Werror"]),
        ],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ],
        linkerSettings: [
            .unsafeFlags(
                [
                    "-L", nativeSDKRoot + "/render/lib/skia-graphite-android-arm64", "-Xlinker",
                    "--start-group", "-lskia", "-lskshaper", "-lskparagraph", "-lskunicode_core",
                    "-lskunicode_icu", "-lsvg", "-lskcms", "-lskresources", "-lfreetype2",
                    "-lharfbuzz",
                    "-licu", "-lpng", "-ljpeg", "-ljpeg12", "-ljpeg16", "-lwebp", "-lwebp_sse41",
                    "-lexpat",
                    "-lzlib", "-lwuffs", "-ldng_sdk", "-lpiex", "-Xlinker", "--end-group",
                    "-lvulkan",
                    "-landroid", "-llog", "-lz", "-ldl", "-lm",
                ], .when(platforms: [.android]))
        ]),
    .target(
        name: "NucleusTextRenderingBridge",
        dependencies: ["NucleusTextBackendNative", "NucleusSkiaGraphiteBridge"],
        path: "core/swift/Sources/NucleusTextRenderingBridge",
        cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [
            .unsafeFlags(
                [
                    "-std=c++20", "-DNDEBUG", "-DSK_GRAPHITE", "-DSK_VULKAN",
                    "-DSK_GAMMA_APPLY_TO_A8",
                    "-DSK_ALLOW_STATIC_GLOBAL_INITIALIZERS=1", "-I",
                    nativeSDKRoot + "/render/include/skia",
                    "-I", nativeSDKRoot + "/render/include/skia/src", "-I",
                    nativeSDKRoot + "/render/include/skia/include/third_party/vulkan", "-I",
                    nativeSDKRoot + "/render/include/skia/src/gpu/vk/vulkanmemoryallocator", "-I",
                    nativeSDKRoot
                        + "/render/include/skia/third_party/externals/vulkanmemoryallocator/include",
                    "-I",
                    nativeSDKRoot
                        + "/render/include/skia/third_party/externals/vulkan-headers/include",
                ], .when(platforms: [.linux])),
            .unsafeFlags(
                [
                    "-std=c++20", "-DNDEBUG", "-DSK_GRAPHITE", "-DSK_VULKAN",
                    "-DSK_GAMMA_APPLY_TO_A8",
                    "-DSK_ALLOW_STATIC_GLOBAL_INITIALIZERS=1", "-I",
                    nativeSDKRoot + "/render/include/skia",
                    "-I", nativeSDKRoot + "/render/include/skia/src", "-I",
                    nativeSDKRoot + "/render/include/skia/include/third_party/vulkan", "-I",
                    nativeSDKRoot + "/render/include/skia/src/gpu/vk/vulkanmemoryallocator", "-I",
                    nativeSDKRoot
                        + "/render/include/skia/third_party/externals/vulkanmemoryallocator/include",
                    "-I",
                    nativeSDKRoot
                        + "/render/include/skia/third_party/externals/vulkan-headers/include",
                ], .when(platforms: [.android])), .unsafeFlags(["-Werror"]),
        ],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusSkiaGraphiteTests", dependencies: ["NucleusSkiaGraphiteBridge"],
        path: "core/swift/Tests/NucleusSkiaGraphiteTests", cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ],
        linkerSettings: [
            .unsafeFlags([
                "-L", nativeSDKRoot + "/render/lib/skia-graphite", "-Xlinker", "--start-group",
                "-lskia",
                "-lskshaper", "-lskparagraph", "-lskunicode_core", "-lskunicode_icu", "-lsvg",
                "-lskcms",
                "-lskresources", "-lfreetype2", "-lharfbuzz", "-licu", "-lpng", "-ljpeg",
                "-ljpeg12",
                "-ljpeg16", "-lwebp", "-lwebp_sse41", "-lexpat", "-lzlib", "-lwuffs", "-ldng_sdk",
                "-lpiex",
                "-Xlinker", "--end-group", "-lvulkan", "-lfontconfig", "-lfreetype", "-lz", "-ldl",
                "-lpthread", "-lm",
            ])
        ]),
    .target(
        name: "NucleusBlockingSynchronizationC",
        path: "core/swift/Sources/NucleusBlockingSynchronizationC",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusRenderHost",
        dependencies: ["NucleusLayers", "NucleusRenderModel", "NucleusFoundation"],
        path: "core/swift/Sources/NucleusRenderHost", cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusRenderHostTests",
        dependencies: [
            "NucleusRenderHost", "NucleusLayers", "NucleusRenderModel", "NucleusFoundation",
        ], path: "core/swift/Tests/NucleusRenderHostTests", cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusRuntimeGraphTests",
        dependencies: [
            "NucleusAppHostBundle", "NucleusRenderHost", "NucleusRenderModel", "NucleusLayers",
            "NucleusUI", "NucleusFoundation",
        ], path: "core/swift/Tests/NucleusRuntimeGraphTests",
        cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusAndroidHostLifecycleTests", dependencies: ["NucleusAndroidHostLifecycle"],
        path: "core/swift/Tests/NucleusAndroidHostLifecycleTests",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusRenderer",
        dependencies: [
            "NucleusRenderModel", "NucleusBlockingSynchronizationC", "NucleusFoundation", "VulkanC",
            "Vulkan", "NucleusSkiaGraphiteBridge", "Tracy",
        ], path: "core/swift/Sources/NucleusRenderer", cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx),
            .unsafeFlags([
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/render/include/skia/third_party/externals/vulkan-headers/include",
            ]), .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusRendererTests", dependencies: ["NucleusRenderer", "NucleusFoundation"],
        path: "core/swift/Tests/NucleusRendererTests", cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ],
        linkerSettings: [
            .unsafeFlags([
                "-L", nativeSDKRoot + "/render/lib/skia-graphite", "-Xlinker", "--start-group",
                "-lskia",
                "-lskshaper", "-lskparagraph", "-lskunicode_core", "-lskunicode_icu", "-lsvg",
                "-lskcms",
                "-lskresources", "-lfreetype2", "-lharfbuzz", "-licu", "-lpng", "-ljpeg",
                "-ljpeg12",
                "-ljpeg16", "-lwebp", "-lwebp_sse41", "-lexpat", "-lzlib", "-lwuffs", "-ldng_sdk",
                "-lpiex",
                "-Xlinker", "--end-group", "-lvulkan", "-lfontconfig", "-lfreetype", "-lz", "-ldl",
                "-lpthread", "-lm",
            ])
        ]),
    .testTarget(
        name: "NucleusDiagnosticsTests", dependencies: ["NucleusFoundation"],
        path: "core/swift/Tests/NucleusDiagnosticsTests", cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusRenderModelTests", dependencies: ["NucleusRenderModel", "NucleusFoundation"],
        path: "core/swift/Tests/NucleusRenderModelTests", cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusRetainedSceneTestSupport", dependencies: ["NucleusUI"],
        path: "core/swift/Tests/Support/RetainedScene", cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusHostProjectionTestSupport", path: "core/swift/Tests/Support/HostProjection",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusRendererTestSupport", path: "core/swift/Tests/Support/Renderer",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusPresentationBackendContractTestSupport",
        path: "core/swift/Tests/Support/PresentationBackendContract",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusResourceTestSupport", path: "core/swift/Tests/Support/Resources",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusTextRenderingTestSupport",
        dependencies: ["NucleusSkiaGraphiteBridge", "NucleusTextRenderingBridge"],
        path: "core/swift/Tests/Support/TextRendering", cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusUmbrellaTests", dependencies: ["Nucleus"],
        path: "core/swift/Tests/NucleusUmbrellaTests", cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusUIEmbedderTests",
        dependencies: ["NucleusUIEmbedder", "NucleusUI", "NucleusLayers", "NucleusFoundation"],
        path: "core/swift/Tests/NucleusUIEmbedderTests", cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusAppTests", dependencies: ["NucleusApp", "NucleusUI"],
        path: "core/swift/Tests/NucleusAppTests", cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusUITests",
        dependencies: [
            "NucleusUI", "NucleusUIEmbedder", "NucleusLayers", "NucleusTextBackend",
            "NucleusSkiaGraphiteBridge", "NucleusRenderHost", "NucleusRenderModel",
            "NucleusRetainedSceneTestSupport", "NucleusHostProjectionTestSupport",
            "NucleusRendererTestSupport", "NucleusResourceTestSupport",
            "NucleusTextRenderingTestSupport",
            "NucleusFoundation",
        ], path: "core/swift/Tests/NucleusUITests", cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ],
        linkerSettings: [
            .unsafeFlags([
                "-L", nativeSDKRoot + "/render/lib/skia-graphite", "-Xlinker", "--start-group",
                "-lskia",
                "-lskshaper", "-lskparagraph", "-lskunicode_core", "-lskunicode_icu", "-lsvg",
                "-lskcms",
                "-lskresources", "-lfreetype2", "-lharfbuzz", "-licu", "-lpng", "-ljpeg",
                "-ljpeg12",
                "-ljpeg16", "-lwebp", "-lwebp_sse41", "-lexpat", "-lzlib", "-lwuffs", "-ldng_sdk",
                "-lpiex",
                "-Xlinker", "--end-group", "-lvulkan", "-lfontconfig", "-lfreetype", "-lz", "-ldl",
                "-lpthread", "-lm",
            ])
        ]),
    .executableTarget(
        name: "NucleusHeadlessBenchmarks",
        dependencies: [
            "NucleusBenchmarkSupport", "NucleusLayers", "NucleusUI", "NucleusRenderModel",
            "NucleusFoundation",
        ], path: "core/swift/Benchmarks/NucleusHeadlessBenchmarks",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusBenchmarkSupport", dependencies: ["NucleusBenchmarkMetricsC"],
        path: "core/swift/Benchmarks/NucleusBenchmarkSupport",
        cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusBenchmarkMetricsC", path: "core/swift/Benchmarks/NucleusBenchmarkMetricsC",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusBenchmarkSupportTests", dependencies: ["NucleusBenchmarkSupport"],
        path: "core/swift/Tests/NucleusBenchmarkSupportTests",
        cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .executableTarget(
        name: "NucleusCoreThreadSanitizerHarness",
        dependencies: ["NucleusRenderModel", "NucleusRenderer", "NucleusFoundation"],
        path: "core/swift/SanitizerHarnesses/NucleusCoreThreadSanitizerHarness",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ],
        linkerSettings: [
            .unsafeFlags([
                "-L", nativeSDKRoot + "/render/lib/skia-graphite", "-Xlinker", "--start-group",
                "-lskia",
                "-lskshaper", "-lskparagraph", "-lskunicode_core", "-lskunicode_icu", "-lsvg",
                "-lskcms",
                "-lskresources", "-lfreetype2", "-lharfbuzz", "-licu", "-lpng", "-ljpeg",
                "-ljpeg12",
                "-ljpeg16", "-lwebp", "-lwebp_sse41", "-lexpat", "-lzlib", "-lwuffs", "-ldng_sdk",
                "-lpiex",
                "-Xlinker", "--end-group", "-lvulkan", "-lfontconfig", "-lfreetype", "-lz", "-ldl",
                "-lpthread", "-lm",
            ])
        ]),
    .target(
        name: "NucleusDesktop",
        dependencies: [
            "Nucleus", "NucleusApp", "NucleusAppHostBundle", "NucleusLayers", "NucleusRenderHost",
            "NucleusRenderModel", "NucleusRenderer", "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend",
            "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
            "NucleusWindowClientContracts", "NucleusWindowClientRuntime",
            "NucleusWindowClientWayland",
            "NucleusWindowClientPasteboard", "NucleusWindowClientRender",
            "NucleusWindowClientInput",
            "NucleusWindowClientHost",
        ], path: "desktop/Sources/NucleusDesktop",
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusDesktopTests", dependencies: ["NucleusDesktop"],
        path: "desktop/Tests/NucleusDesktopTests",
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusTypes", path: "foundation/Sources/NucleusTypes",
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusDiagnostics", path: "foundation/Sources/NucleusDiagnostics",
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusAppHostProtocols", dependencies: ["NucleusTypes"],
        path: "foundation/Sources/NucleusAppHostProtocols",
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusFoundation",
        dependencies: ["NucleusTypes", "NucleusDiagnostics", "NucleusAppHostProtocols"],
        path: "foundation/Sources/NucleusFoundation",
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusWindowClientPasteboardIntegrationTests",
        dependencies: [
            "NucleusWindowClientContracts", "NucleusWindowClientRuntime",
            "NucleusWindowClientWayland",
            "NucleusWindowClientPasteboard", "NucleusWindowClientRender",
            "NucleusWindowClientInput",
            "NucleusWindowClientHost", "Nucleus", "NucleusApp", "NucleusAppHostBundle",
            "NucleusLayers",
            "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend", "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
            "NucleusCompositorWaylandRuntime", "NucleusRenderServerTestSupport",
            "NucleusCompositorWindowScene",
        ],
        path:
            "integration-tests/window-client-conformance/Tests/NucleusWindowClientPasteboardIntegrationTests",
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ],
        linkerSettings: [
            .unsafeFlags([
                "-lwayland-client", "-lm", "-lxcb-ewmh", "-lxcb-icccm", "-lxcb-composite",
                "-lxcb-xfixes",
                "-lxcb-res", "-lxcb", "-linput", "-ludev", "-lseat", "-lxkbcommon",
            ])
        ]),
    .testTarget(
        name: "NucleusWindowClientInputIntegrationTests",
        dependencies: [
            "NucleusWindowClientContracts", "NucleusWindowClientRuntime",
            "NucleusWindowClientWayland",
            "NucleusWindowClientPasteboard", "NucleusWindowClientRender",
            "NucleusWindowClientInput",
            "NucleusWindowClientHost", "Nucleus", "NucleusApp", "NucleusAppHostBundle",
            "NucleusLayers",
            "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend", "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
            "NucleusCompositorWaylandRuntime", "NucleusRenderServerTestSupport",
            "NucleusCompositorWindowScene",
        ],
        path:
            "integration-tests/window-client-conformance/Tests/NucleusWindowClientInputIntegrationTests",
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ],
        linkerSettings: [
            .unsafeFlags([
                "-lwayland-client", "-lm", "-lxcb-ewmh", "-lxcb-icccm", "-lxcb-composite",
                "-lxcb-xfixes",
                "-lxcb-res", "-lxcb", "-linput", "-ludev", "-lseat", "-lxkbcommon",
            ])
        ]),
    .executableTarget(
        name: "NucleusControlCLI",
        dependencies: [
            "NucleusControlClient", "NucleusControlProtocol", "NucleusConfig",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ], path: "ipc/Sources/NucleusControlCLI", cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusControlClient",
        dependencies: ["NucleusIPCTransport", "NucleusIPCTransportC", "NucleusControlProtocol"],
        path: "ipc/control-client/Sources/NucleusControlClient",
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusControlClientTests", dependencies: ["NucleusControlClient"],
        path: "ipc/control-client/Tests/NucleusControlClientTests",
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusControlProtocol", dependencies: ["NucleusFoundation", "NucleusConfig"],
        path: "ipc/control-protocol/Sources/NucleusControlProtocol",
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusControlProtocolTests", dependencies: ["NucleusControlProtocol"],
        path: "ipc/control-protocol/Tests/NucleusControlProtocolTests",
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusControlService",
        dependencies: [
            "NucleusIPCTransport", "NucleusIPCTransportC", "NucleusControlProtocol",
            "NucleusLinuxPrimitives", "NucleusLinuxPrimitivesC", "NucleusLinuxReactor",
            "NucleusLinuxReactorC", "NucleusLinuxDBus", "NucleusLinuxSessionC",
            "NucleusThemeAssetIO",
            "NucleusSessionProtocol",
        ], path: "ipc/control-service-core/Sources/NucleusControlService",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusControlServiceTests", dependencies: ["NucleusControlService"],
        path: "ipc/control-service-core/Tests/NucleusControlServiceTests",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .executableTarget(
        name: "NucleusControlServiceExecutable", dependencies: ["NucleusControlService"],
        path: "ipc/control-service/Sources/NucleusControlServiceExecutable",
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(name: "NucleusIPCTransportC", path: "ipc/transport/Sources/NucleusIPCTransportC"),
    .target(
        name: "NucleusIPCTransport", dependencies: ["NucleusIPCTransportC"],
        path: "ipc/transport/Sources/NucleusIPCTransport",
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusIPCTransportTests", dependencies: ["NucleusIPCTransport"],
        path: "ipc/transport/Tests/NucleusIPCTransportTests",
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusLinuxPrimitives", dependencies: ["NucleusLinuxPrimitivesC"],
        path: "platform-linux/Sources/NucleusLinuxPrimitives",
        cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusLinuxPrimitivesC", path: "platform-linux/Sources/NucleusLinuxPrimitivesC",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusLinuxReactor",
        dependencies: [
            "NucleusLinuxPrimitives", "NucleusLinuxReactorC",
            .product(name: "SystemPackage", package: "swift-system"),
        ], path: "platform-linux/Sources/NucleusLinuxReactor",
        cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusLinuxReactorC", path: "platform-linux/Sources/NucleusLinuxReactorC",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .systemLibrary(
        name: "NucleusLinuxDBusC", path: "platform-linux/Sources/NucleusLinuxDBusC",
        pkgConfig: "libsystemd"),
    .target(
        name: "NucleusLinuxDBus", dependencies: ["NucleusLinuxDBusC", "NucleusLinuxReactor"],
        path: "platform-linux/Sources/NucleusLinuxDBus", cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusLinuxSessionC", path: "platform-linux/Sources/NucleusLinuxSessionC",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusThemeAssetIO", path: "platform-linux/Sources/NucleusThemeAssetIO",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .executableTarget(
        name: "NucleusLinuxThreadSanitizerHarness",
        dependencies: ["NucleusLinuxReactor", "NucleusLinuxReactorC"],
        path: "platform-linux/SanitizerHarnesses/NucleusLinuxThreadSanitizerHarness",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusLinuxPrimitivesTests",
        dependencies: ["NucleusLinuxPrimitives", "NucleusLinuxPrimitivesC"],
        path: "platform-linux/Tests/NucleusLinuxPrimitivesTests",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusLinuxReactorTests", dependencies: ["NucleusLinuxReactor"],
        path: "platform-linux/Tests/NucleusLinuxReactorTests",
        cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusLinuxDBusTests", dependencies: ["NucleusLinuxDBus"],
        path: "platform-linux/Tests/NucleusLinuxDBusTests", cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusThemeAssetIOTests", dependencies: ["NucleusThemeAssetIO"],
        path: "platform-linux/Tests/NucleusThemeAssetIOTests",
        cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusLinuxAccessibility",
        dependencies: [
            "Nucleus", "NucleusApp", "NucleusAppHostBundle", "NucleusLayers", "NucleusRenderHost",
            "NucleusRenderModel", "NucleusRenderer", "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend",
            "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
            "NucleusLinuxPrimitives",
            "NucleusLinuxPrimitivesC", "NucleusLinuxReactor", "NucleusLinuxReactorC",
            "NucleusLinuxDBus",
            "NucleusLinuxSessionC", "NucleusThemeAssetIO",
        ], path: "platform-linux/desktop/Sources/NucleusLinuxAccessibility",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusLinuxEnvironment",
        dependencies: [
            "Nucleus", "NucleusApp", "NucleusAppHostBundle", "NucleusLayers", "NucleusRenderHost",
            "NucleusRenderModel", "NucleusRenderer", "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend",
            "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
            "NucleusLinuxPrimitives",
            "NucleusLinuxPrimitivesC", "NucleusLinuxReactor", "NucleusLinuxReactorC",
            "NucleusLinuxDBus",
            "NucleusLinuxSessionC", "NucleusThemeAssetIO",
        ], path: "platform-linux/desktop/Sources/NucleusLinuxEnvironment",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .executableTarget(
        name: "NucleusLinuxBenchmarks",
        dependencies: [
            "NucleusLinuxAccessibility", "Nucleus", "NucleusApp", "NucleusAppHostBundle",
            "NucleusLayers",
            "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend", "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
            "NucleusBenchmarkSupport", "NucleusLinuxPrimitives", "NucleusLinuxPrimitivesC",
            "NucleusLinuxReactor", "NucleusLinuxReactorC", "NucleusLinuxDBus",
            "NucleusLinuxSessionC",
            "NucleusThemeAssetIO",
        ], path: "platform-linux/desktop/Benchmarks/NucleusLinuxBenchmarks",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx),
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]),
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusLinuxAccessibilityTests",
        dependencies: [
            "NucleusLinuxAccessibility", "Nucleus", "NucleusApp", "NucleusAppHostBundle",
            "NucleusLayers",
            "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend", "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
        ], path: "platform-linux/desktop/Tests/NucleusLinuxAccessibilityTests",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ], linkerSettings: [.unsafeFlags(["-Xlinker", "--no-as-needed"])]),
    .testTarget(
        name: "NucleusLinuxEnvironmentTests",
        dependencies: [
            "NucleusLinuxEnvironment", "Nucleus", "NucleusApp", "NucleusAppHostBundle",
            "NucleusLayers",
            "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend", "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
        ], path: "platform-linux/desktop/Tests/NucleusLinuxEnvironmentTests",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ], linkerSettings: [.unsafeFlags(["-Xlinker", "--no-as-needed"])]),
    .executableTarget(
        name: "NucleusSessionSupervisor",
        dependencies: [
            "NucleusFoundation", "NucleusLinuxPrimitives", "NucleusLinuxPrimitivesC",
            "NucleusLinuxReactor", "NucleusLinuxReactorC", "NucleusLinuxDBus",
            "NucleusLinuxSessionC",
            "NucleusThemeAssetIO", "NucleusSessionProtocol", "NucleusIPCTransport",
            "NucleusIPCTransportC",
        ], path: "platform-linux/session/Sources/NucleusSessionSupervisor",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .executableTarget(
        name: "NucleusSessionFixture",
        dependencies: [
            "NucleusControlClient", "NucleusControlProtocol", "NucleusSessionProtocol",
            "NucleusIPCTransport", "NucleusIPCTransportC",
        ], path: "platform-linux/session/Tests/Fixtures/NucleusSessionFixture",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusLinuxSessionTests",
        dependencies: [
            "NucleusSessionSupervisor", "NucleusSessionFixture", "NucleusConfigServiceExecutable",
            "NucleusControlServiceExecutable", "NucleusControlClient", "NucleusControlProtocol",
            "NucleusIPCTransport", "NucleusIPCTransportC", "NucleusControlCLI",
            "NucleusSessionProtocol",
        ], path: "platform-linux/session/Tests/NucleusLinuxSessionTests",
        cSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .systemLibrary(
        name: "NucleusReactRuntimeCxxBridge",
        path: "react-native/swiftpm/cmodules/NucleusReactRuntimeCxxBridge"),
    .target(
        name: "NucleusReactNativeCxxBridge",
        path: "react-native/swift/Sources/NucleusReactNativeCxxBridge",
        cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [
            .unsafeFlags([
                "-std=c++20", "-I", nativeSDKRoot + "/rn/include/hermes/API", "-I",
                nativeSDKRoot + "/rn/include/hermes/API/jsi", "-I",
                nativeSDKRoot + "/rn/include/hermes/public", "-I",
                nativeSDKRoot + "/rn/include/hermes/include", "-I",
                nativeSDKRoot + "/rn/include/folly",
                "-I", nativeSDKRoot + "/rn/include/boost", "-I",
                nativeSDKRoot + "/rn/include/glog-gen",
                "-I", nativeSDKRoot + "/rn/include/glog/src", "-I",
                nativeSDKRoot + "/rn/include/rn-gen",
                "-I", nativeSDKRoot + "/rn/include/fmt/include", "-I",
                nativeSDKRoot + "/rn/include/fast_float/include", "-DFOLLY_NO_CONFIG=1",
                "-DFOLLY_MOBILE=0",
                "-DFOLLY_USE_LIBCPP=1", "-DFOLLY_CFG_NO_COROUTINES=1",
                "-DFOLLY_HAVE_CLOCK_GETTIME=1",
                "-DFOLLY_HAVE_PTHREAD=1",
            ]), .unsafeFlags(["-Werror"]),
        ],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusReactNativeCxxTests", dependencies: ["NucleusReactNativeCxxBridge"],
        path: "react-native/swift/Tests/NucleusReactNativeCxxTests",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ],
        linkerSettings: [
            .unsafeFlags([
                "-Xlinker", "--start-group",
                nativeSDKRoot + "/rn/lib/rn/hermes/libhermes_lean_combined.a",
                nativeSDKRoot + "/rn/lib/rn/reactnative/libfolly_runtime.a",
                nativeSDKRoot + "/rn/lib/rn/glog/libglog.a",
                nativeSDKRoot + "/rn/lib/rn/fmt/libfmt.a",
                nativeSDKRoot + "/rn/lib/rn/double-conversion/src/libdouble-conversion.a",
                "-Xlinker",
                "--end-group", "-licui18n", "-licuuc", "-licudata", "-Xlinker", "-rpath",
                "-Xlinker",
                icuLibraryDirectory, "-lpthread", "-ldl", "-lm",
            ])
        ]),
    .systemLibrary(
        name: "NucleusReactFabricSmokeC",
        path: "react-native/swiftpm/cmodules/NucleusReactFabricSmokeC"
    ),
    .testTarget(
        name: "NucleusReactRuntimeFabricTests",
        dependencies: [
            "NucleusReactFabricSmokeC", "NucleusReactRuntimeHostCxx", "NucleusReactRuntimeCxx",
            "Nucleus",
            "NucleusApp", "NucleusAppHostBundle", "NucleusLayers", "NucleusRenderHost",
            "NucleusRenderModel", "NucleusRenderer", "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend",
            "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
        ], path: "react-native/swift/Tests/NucleusReactRuntimeFabricTests",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx),
            .unsafeFlags([
                "-Xcc",
                "-fmodule-map-file=\(repoRoot)/react-native/swiftpm/cmodules/NucleusReactRuntimeCxxBridge/module.modulemap",
                "-Xcc", "-I", "-Xcc",
                repoRoot + "/react-native/swiftpm/cmodules/NucleusReactRuntimeCxxBridge", "-Xcc",
                "-I",
                "-Xcc", repoRoot + "/react-native/swift/Sources/NucleusReactRuntime/cxx/include",
                "-Xcc",
                "-I", "-Xcc", repoRoot + "/react-native/../core/render-cxx/skia/include", "-Xcc",
                "-I",
                "-Xcc",
                nativeSDKRoot + "/rn/include/react-native/packages/react-native/ReactCommon/jsi",
                "-Xcc", "-I", "-Xcc", nativeSDKRoot + "/rn/include/rn-codegen", "-Xcc", "-I",
                "-Xcc",
                nativeSDKRoot + "/rn/include/rn-codegen/FBReactNativeSpec", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/react-native/packages/react-native/ReactCommon",
                "-Xcc", "-I",
                "-Xcc", nativeSDKRoot + "/rn/include/react-native/packages/react-native/React",
                "-Xcc",
                "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/callinvoker",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/jsiexecutor",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/react-native/packages/react-native/ReactCommon/yoga",
                "-Xcc",
                "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/runtimeexecutor",
                "-Xcc",
                "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/nativemodule/core",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/react-native/packages/react-native",
                "-Xcc", "-I", "-Xcc", nativeSDKRoot + "/rn/include/hermes/API", "-Xcc", "-I",
                "-Xcc",
                nativeSDKRoot + "/rn/include/hermes/API/jsi", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/hermes/public", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/renderer/components/view/platform/cxx",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/renderer/components/scrollview/platform/cxx",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/renderer/graphics/platform/cxx",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/renderer/imagemanager",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/renderer/imagemanager/platform/cxx",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/utils/platform/cxx",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/renderer/components/text/platform/cxx",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/renderer/textlayoutmanager/platform/cxx",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/reactperflogger",
                "-Xcc",
                "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/react-native/packages/react-native/ReactCxxPlatform",
                "-Xcc",
                "-I", "-Xcc", nativeSDKRoot + "/rn/include/folly", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/boost", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/glog-gen", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/glog/src", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/rn-gen", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/fmt/include", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/fast_float/include", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/render/include/skia", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/render/include/skia/src", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/render/include/skia/third_party/externals/vulkan-headers/include",
                "-Xcc",
                "-I", "-Xcc",
                nativeSDKRoot + "/render/include/skia/src/gpu/vk/vulkanmemoryallocator",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/render/include/skia/third_party/externals/vulkanmemoryallocator/include",
                "-Xcc", "-DJS_RUNTIME_HERMES=1", "-Xcc", "-DHERMES_V1_ENABLED=1", "-Xcc",
                "-DREACT_NATIVE_DEBUG=1", "-Xcc", "-DFOLLY_NO_CONFIG=1", "-Xcc", "-DFOLLY_MOBILE=0",
                "-Xcc",
                "-DFOLLY_CFG_NO_COROUTINES=1", "-Xcc", "-DFMT_USE_CONSTEVAL=0", "-Xcc",
                "-DSK_GRAPHITE",
                "-Xcc", "-DSK_VULKAN", "-Xcc", "-std=c++20",
            ]), .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ],
        linkerSettings: [
            .unsafeFlags([
                "-Xlinker", "--start-group",
                nativeSDKRoot + "/rn/lib/rn/hermes/libhermes_lean_combined.a",
                nativeSDKRoot + "/rn/lib/rn/reactnative/libreact_native.a",
                nativeSDKRoot + "/rn/lib/rn/reactnative/libreact_cxx_platform.a",
                nativeSDKRoot + "/rn/lib/rn/reactnative/libyogacore.a",
                nativeSDKRoot + "/rn/lib/rn/reactnative/libfolly_runtime.a",
                nativeSDKRoot + "/rn/lib/rn/glog/libglog.a",
                nativeSDKRoot + "/rn/lib/rn/fmt/libfmt.a",
                nativeSDKRoot + "/rn/lib/rn/double-conversion/src/libdouble-conversion.a",
                "-Xlinker",
                "--end-group", "-latomic", "-licui18n", "-licuuc", "-licudata", "-Xlinker",
                "-rpath",
                "-Xlinker", icuLibraryDirectory, "-lpthread", "-ldl", "-lm", "-L",
                nativeSDKRoot + "/render/lib/skia-graphite", "-Xlinker", "--start-group", "-lskia",
                "-lskshaper", "-lskparagraph", "-lskunicode_core", "-lskunicode_icu", "-lsvg",
                "-lskcms",
                "-lskresources", "-lfreetype2", "-lharfbuzz", "-licu", "-lpng", "-ljpeg",
                "-ljpeg12",
                "-ljpeg16", "-lwebp", "-lwebp_sse41", "-lexpat", "-lzlib", "-lwuffs", "-ldng_sdk",
                "-lpiex",
                "-Xlinker", "--end-group", "-lvulkan", "-lfontconfig", "-lfreetype", "-lz", "-ldl",
                "-lpthread", "-lm",
            ])
        ]),
    .executableTarget(
        name: "NucleusReactThreadSanitizerHarness",
        dependencies: [
            "NucleusReactFabricSmokeC", "NucleusReactRuntimeHostCxx", "NucleusReactRuntimeCxx",
            "Nucleus",
            "NucleusApp", "NucleusAppHostBundle", "NucleusLayers", "NucleusRenderHost",
            "NucleusRenderModel", "NucleusRenderer", "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend",
            "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
        ], path: "react-native/swift/SanitizerHarnesses/NucleusReactThreadSanitizerHarness",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ],
        linkerSettings: [
            .unsafeFlags([
                "-Xlinker", "--start-group",
                nativeSDKRoot + "/rn/lib/rn/hermes/libhermes_lean_combined.a",
                nativeSDKRoot + "/rn/lib/rn/reactnative/libreact_native.a",
                nativeSDKRoot + "/rn/lib/rn/reactnative/libreact_cxx_platform.a",
                nativeSDKRoot + "/rn/lib/rn/reactnative/libyogacore.a",
                nativeSDKRoot + "/rn/lib/rn/reactnative/libfolly_runtime.a",
                nativeSDKRoot + "/rn/lib/rn/glog/libglog.a",
                nativeSDKRoot + "/rn/lib/rn/fmt/libfmt.a",
                nativeSDKRoot + "/rn/lib/rn/double-conversion/src/libdouble-conversion.a",
                "-Xlinker",
                "--end-group", "-latomic", "-licui18n", "-licuuc", "-licudata", "-Xlinker",
                "-rpath",
                "-Xlinker", icuLibraryDirectory, "-lpthread", "-ldl", "-lm", "-L",
                nativeSDKRoot + "/render/lib/skia-graphite", "-Xlinker", "--start-group", "-lskia",
                "-lskshaper", "-lskparagraph", "-lskunicode_core", "-lskunicode_icu", "-lsvg",
                "-lskcms",
                "-lskresources", "-lfreetype2", "-lharfbuzz", "-licu", "-lpng", "-ljpeg",
                "-ljpeg12",
                "-ljpeg16", "-lwebp", "-lwebp_sse41", "-lexpat", "-lzlib", "-lwuffs", "-ldng_sdk",
                "-lpiex",
                "-Xlinker", "--end-group", "-lvulkan", "-lfontconfig", "-lfreetype", "-lz", "-ldl",
                "-lpthread", "-lm",
            ])
        ]),
    .executableTarget(
        name: "NucleusReactBenchmarks",
        dependencies: [
            "NucleusReactFabricSmokeC", "NucleusReactRuntimeHostCxx", "NucleusReactRuntimeCxx",
            "NucleusBenchmarkSupport", "Nucleus", "NucleusApp", "NucleusAppHostBundle",
            "NucleusLayers",
            "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend", "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
        ], path: "react-native/swift/Benchmarks/NucleusReactBenchmarks",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx),
            .unsafeFlags([
                "-Xcc",
                "-fmodule-map-file=\(repoRoot)/react-native/swiftpm/cmodules/NucleusReactRuntimeCxxBridge/module.modulemap",
                "-Xcc", "-I", "-Xcc",
                repoRoot + "/react-native/swiftpm/cmodules/NucleusReactRuntimeCxxBridge", "-Xcc",
                "-I",
                "-Xcc", repoRoot + "/react-native/swift/Sources/NucleusReactRuntime/cxx/include",
                "-Xcc",
                "-I", "-Xcc", repoRoot + "/react-native/../core/render-cxx/skia/include", "-Xcc",
                "-I",
                "-Xcc",
                nativeSDKRoot + "/rn/include/react-native/packages/react-native/ReactCommon/jsi",
                "-Xcc", "-I", "-Xcc", nativeSDKRoot + "/rn/include/rn-codegen", "-Xcc", "-I",
                "-Xcc",
                nativeSDKRoot + "/rn/include/rn-codegen/FBReactNativeSpec", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/react-native/packages/react-native/ReactCommon",
                "-Xcc", "-I",
                "-Xcc", nativeSDKRoot + "/rn/include/react-native/packages/react-native/React",
                "-Xcc",
                "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/callinvoker",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/jsiexecutor",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/react-native/packages/react-native/ReactCommon/yoga",
                "-Xcc",
                "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/runtimeexecutor",
                "-Xcc",
                "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/nativemodule/core",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/react-native/packages/react-native",
                "-Xcc", "-I", "-Xcc", nativeSDKRoot + "/rn/include/hermes/API", "-Xcc", "-I",
                "-Xcc",
                nativeSDKRoot + "/rn/include/hermes/API/jsi", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/hermes/public", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/renderer/components/view/platform/cxx",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/renderer/components/scrollview/platform/cxx",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/renderer/graphics/platform/cxx",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/renderer/imagemanager",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/renderer/imagemanager/platform/cxx",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/utils/platform/cxx",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/renderer/components/text/platform/cxx",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/renderer/textlayoutmanager/platform/cxx",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/reactperflogger",
                "-Xcc",
                "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/react-native/packages/react-native/ReactCxxPlatform",
                "-Xcc",
                "-I", "-Xcc", nativeSDKRoot + "/rn/include/folly", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/boost", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/glog-gen", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/glog/src", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/rn-gen", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/fmt/include", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/fast_float/include", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/render/include/skia", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/render/include/skia/src", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/render/include/skia/third_party/externals/vulkan-headers/include",
                "-Xcc",
                "-I", "-Xcc",
                nativeSDKRoot + "/render/include/skia/src/gpu/vk/vulkanmemoryallocator",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/render/include/skia/third_party/externals/vulkanmemoryallocator/include",
                "-Xcc", "-DJS_RUNTIME_HERMES=1", "-Xcc", "-DHERMES_V1_ENABLED=1", "-Xcc",
                "-DREACT_NATIVE_DEBUG=1", "-Xcc", "-DFOLLY_NO_CONFIG=1", "-Xcc", "-DFOLLY_MOBILE=0",
                "-Xcc",
                "-DFOLLY_CFG_NO_COROUTINES=1", "-Xcc", "-DFMT_USE_CONSTEVAL=0", "-Xcc",
                "-DSK_GRAPHITE",
                "-Xcc", "-DSK_VULKAN", "-Xcc", "-std=c++20",
            ]), .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ],
        linkerSettings: [
            .unsafeFlags([
                "-Xlinker", "--start-group",
                nativeSDKRoot + "/rn/lib/rn/hermes/libhermes_lean_combined.a",
                nativeSDKRoot + "/rn/lib/rn/reactnative/libreact_native.a",
                nativeSDKRoot + "/rn/lib/rn/reactnative/libreact_cxx_platform.a",
                nativeSDKRoot + "/rn/lib/rn/reactnative/libyogacore.a",
                nativeSDKRoot + "/rn/lib/rn/reactnative/libfolly_runtime.a",
                nativeSDKRoot + "/rn/lib/rn/glog/libglog.a",
                nativeSDKRoot + "/rn/lib/rn/fmt/libfmt.a",
                nativeSDKRoot + "/rn/lib/rn/double-conversion/src/libdouble-conversion.a",
                "-Xlinker",
                "--end-group", "-latomic", "-licui18n", "-licuuc", "-licudata", "-Xlinker",
                "-rpath",
                "-Xlinker", icuLibraryDirectory, "-lpthread", "-ldl", "-lm", "-L",
                nativeSDKRoot + "/render/lib/skia-graphite", "-Xlinker", "--start-group", "-lskia",
                "-lskshaper", "-lskparagraph", "-lskunicode_core", "-lskunicode_icu", "-lsvg",
                "-lskcms",
                "-lskresources", "-lfreetype2", "-lharfbuzz", "-licu", "-lpng", "-ljpeg",
                "-ljpeg12",
                "-ljpeg16", "-lwebp", "-lwebp_sse41", "-lexpat", "-lzlib", "-lwuffs", "-ldng_sdk",
                "-lpiex",
                "-Xlinker", "--end-group", "-lvulkan", "-lfontconfig", "-lfreetype", "-lz", "-ldl",
                "-lpthread", "-lm",
            ])
        ]),
    .target(
        name: "NucleusReactRuntimeCxx",
        dependencies: [
            "Nucleus", "NucleusApp", "NucleusAppHostBundle", "NucleusLayers", "NucleusRenderHost",
            "NucleusRenderModel", "NucleusRenderer", "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend",
            "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder", "Tracy",
            "NucleusFoundation",
            "NucleusReactFabricSmokeC",
        ], path: "react-native/swift/Sources/NucleusReactRuntimeCxx",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx),
            .unsafeFlags([
                "-Xcc",
                "-fmodule-map-file=\(repoRoot)/react-native/swiftpm/cmodules/NucleusReactRuntimeCxxBridge/module.modulemap",
                "-Xcc", "-I", "-Xcc",
                repoRoot + "/react-native/swiftpm/cmodules/NucleusReactRuntimeCxxBridge", "-Xcc",
                "-I",
                "-Xcc", repoRoot + "/react-native/swift/Sources/NucleusReactRuntime/cxx/include",
                "-Xcc",
                "-I", "-Xcc", repoRoot + "/react-native/../core/render-cxx/skia/include", "-Xcc",
                "-I",
                "-Xcc",
                nativeSDKRoot + "/rn/include/react-native/packages/react-native/ReactCommon/jsi",
                "-Xcc", "-I", "-Xcc", nativeSDKRoot + "/rn/include/rn-codegen", "-Xcc", "-I",
                "-Xcc",
                nativeSDKRoot + "/rn/include/rn-codegen/FBReactNativeSpec", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/react-native/packages/react-native/ReactCommon",
                "-Xcc", "-I",
                "-Xcc", nativeSDKRoot + "/rn/include/react-native/packages/react-native/React",
                "-Xcc",
                "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/callinvoker",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/jsiexecutor",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/react-native/packages/react-native/ReactCommon/yoga",
                "-Xcc",
                "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/runtimeexecutor",
                "-Xcc",
                "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/nativemodule/core",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/react-native/packages/react-native",
                "-Xcc", "-I", "-Xcc", nativeSDKRoot + "/rn/include/hermes/API", "-Xcc", "-I",
                "-Xcc",
                nativeSDKRoot + "/rn/include/hermes/API/jsi", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/hermes/public", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/renderer/components/view/platform/cxx",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/renderer/components/scrollview/platform/cxx",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/renderer/graphics/platform/cxx",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/renderer/imagemanager",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/renderer/imagemanager/platform/cxx",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/utils/platform/cxx",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/renderer/components/text/platform/cxx",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/renderer/textlayoutmanager/platform/cxx",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/reactperflogger",
                "-Xcc",
                "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/react-native/packages/react-native/ReactCxxPlatform",
                "-Xcc",
                "-I", "-Xcc", nativeSDKRoot + "/rn/include/folly", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/boost", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/glog-gen", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/glog/src", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/rn-gen", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/fmt/include", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/fast_float/include", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/render/include/skia", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/render/include/skia/src", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/render/include/skia/third_party/externals/vulkan-headers/include",
                "-Xcc",
                "-I", "-Xcc",
                nativeSDKRoot + "/render/include/skia/src/gpu/vk/vulkanmemoryallocator",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/render/include/skia/third_party/externals/vulkanmemoryallocator/include",
                "-Xcc", "-DJS_RUNTIME_HERMES=1", "-Xcc", "-DHERMES_V1_ENABLED=1", "-Xcc",
                "-DREACT_NATIVE_DEBUG=1", "-Xcc", "-DFOLLY_NO_CONFIG=1", "-Xcc", "-DFOLLY_MOBILE=0",
                "-Xcc",
                "-DFOLLY_CFG_NO_COROUTINES=1", "-Xcc", "-DFMT_USE_CONSTEVAL=0", "-Xcc",
                "-DSK_GRAPHITE",
                "-Xcc", "-DSK_VULKAN", "-Xcc", "-std=c++20",
            ]), .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusReactRuntimeHostCxx",
        dependencies: ["NucleusReactRuntimeCxx"],
        path: "react-native/swift/Sources/NucleusReactRuntime/cxx",
        publicHeadersPath: "empty-public",
        cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [
            .unsafeFlags([
                "-std=c++20", "-fexceptions", "-frtti", "-I",
                repoRoot + "/react-native/swiftpm/cmodules/NucleusReactRuntimeCxxBridge", "-I",
                repoRoot + "/react-native/swift/Sources/NucleusReactRuntime/cxx/include", "-I",
                repoRoot + "/react-native/../core/render-cxx/skia/include", "-I",
                nativeSDKRoot + "/rn/include/react-native/packages/react-native/ReactCommon/jsi",
                "-I",
                nativeSDKRoot + "/rn/include/rn-codegen", "-I",
                nativeSDKRoot + "/rn/include/rn-codegen/FBReactNativeSpec", "-I",
                nativeSDKRoot + "/rn/include/react-native/packages/react-native/ReactCommon", "-I",
                nativeSDKRoot + "/rn/include/react-native/packages/react-native/React", "-I",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/callinvoker",
                "-I",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/jsiexecutor",
                "-I",
                nativeSDKRoot + "/rn/include/react-native/packages/react-native/ReactCommon/yoga",
                "-I",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/runtimeexecutor",
                "-I",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/nativemodule/core",
                "-I", nativeSDKRoot + "/rn/include/react-native/packages/react-native", "-I",
                nativeSDKRoot + "/rn/include/hermes/API", "-I",
                nativeSDKRoot + "/rn/include/hermes/API/jsi", "-I",
                nativeSDKRoot + "/rn/include/hermes/public", "-I",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/renderer/components/view/platform/cxx",
                "-I",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/renderer/components/scrollview/platform/cxx",
                "-I",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/renderer/graphics/platform/cxx",
                "-I",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/renderer/imagemanager",
                "-I",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/renderer/imagemanager/platform/cxx",
                "-I",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/utils/platform/cxx",
                "-I",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/renderer/components/text/platform/cxx",
                "-I",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/renderer/textlayoutmanager/platform/cxx",
                "-I",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/reactperflogger",
                "-I",
                nativeSDKRoot + "/rn/include/react-native/packages/react-native/ReactCxxPlatform",
                "-I",
                nativeSDKRoot + "/rn/include/folly", "-I", nativeSDKRoot + "/rn/include/boost",
                "-I",
                nativeSDKRoot + "/rn/include/glog-gen", "-I",
                nativeSDKRoot + "/rn/include/glog/src", "-I",
                nativeSDKRoot + "/rn/include/rn-gen", "-I",
                nativeSDKRoot + "/rn/include/fmt/include", "-I",
                nativeSDKRoot + "/rn/include/fast_float/include", "-I",
                nativeSDKRoot + "/render/include/skia", "-I",
                nativeSDKRoot + "/render/include/skia/src",
                "-I",
                nativeSDKRoot + "/render/include/skia/third_party/externals/vulkan-headers/include",
                "-I", nativeSDKRoot + "/render/include/skia/src/gpu/vk/vulkanmemoryallocator", "-I",
                nativeSDKRoot
                    + "/render/include/skia/third_party/externals/vulkanmemoryallocator/include",
                "-I", repoRoot + "/react-native/swiftpm/shims/NucleusReactRuntimeSwift", "-I",
                generatedModuleMaps, "-DJS_RUNTIME_HERMES=1", "-DHERMES_V1_ENABLED=1",
                "-DREACT_NATIVE_DEBUG=1", "-DFOLLY_NO_CONFIG=1", "-DFOLLY_MOBILE=0",
                "-DFOLLY_CFG_NO_COROUTINES=1", "-DFMT_USE_CONSTEVAL=0", "-DSK_GRAPHITE",
                "-DSK_VULKAN",
            ]), .unsafeFlags(["-Werror"]),
        ],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusReactRuntime",
        dependencies: [
            "NucleusReactRuntimeCxx", "Nucleus", "NucleusApp", "NucleusAppHostBundle",
            "NucleusLayers",
            "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend", "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
            "NucleusFoundation", "Tracy",
        ], path: "react-native/swift/Sources/NucleusReactRuntime", exclude: ["cxx"],
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx),
            .unsafeFlags([
                "-Xcc",
                "-fmodule-map-file=\(repoRoot)/react-native/swiftpm/cmodules/NucleusReactRuntimeCxxBridge/module.modulemap",
                "-Xcc", "-I", "-Xcc",
                repoRoot + "/react-native/swiftpm/cmodules/NucleusReactRuntimeCxxBridge", "-Xcc",
                "-I",
                "-Xcc", repoRoot + "/react-native/swift/Sources/NucleusReactRuntime/cxx/include",
                "-Xcc",
                "-I", "-Xcc", repoRoot + "/react-native/../core/render-cxx/skia/include", "-Xcc",
                "-I",
                "-Xcc",
                nativeSDKRoot + "/rn/include/react-native/packages/react-native/ReactCommon/jsi",
                "-Xcc", "-I", "-Xcc", nativeSDKRoot + "/rn/include/rn-codegen", "-Xcc", "-I",
                "-Xcc",
                nativeSDKRoot + "/rn/include/rn-codegen/FBReactNativeSpec", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/react-native/packages/react-native/ReactCommon",
                "-Xcc", "-I",
                "-Xcc", nativeSDKRoot + "/rn/include/react-native/packages/react-native/React",
                "-Xcc",
                "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/callinvoker",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/jsiexecutor",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/react-native/packages/react-native/ReactCommon/yoga",
                "-Xcc",
                "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/runtimeexecutor",
                "-Xcc",
                "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/nativemodule/core",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/react-native/packages/react-native",
                "-Xcc", "-I", "-Xcc", nativeSDKRoot + "/rn/include/hermes/API", "-Xcc", "-I",
                "-Xcc",
                nativeSDKRoot + "/rn/include/hermes/API/jsi", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/hermes/public", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/renderer/components/view/platform/cxx",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/renderer/components/scrollview/platform/cxx",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/renderer/graphics/platform/cxx",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/renderer/imagemanager",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/renderer/imagemanager/platform/cxx",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/utils/platform/cxx",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/renderer/components/text/platform/cxx",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/react/renderer/textlayoutmanager/platform/cxx",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/rn/include/react-native/packages/react-native/ReactCommon/reactperflogger",
                "-Xcc",
                "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/react-native/packages/react-native/ReactCxxPlatform",
                "-Xcc",
                "-I", "-Xcc", nativeSDKRoot + "/rn/include/folly", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/boost", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/glog-gen", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/glog/src", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/rn-gen", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/fmt/include", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/rn/include/fast_float/include", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/render/include/skia", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/render/include/skia/src", "-Xcc", "-I", "-Xcc",
                nativeSDKRoot + "/render/include/skia/third_party/externals/vulkan-headers/include",
                "-Xcc",
                "-I", "-Xcc",
                nativeSDKRoot + "/render/include/skia/src/gpu/vk/vulkanmemoryallocator",
                "-Xcc", "-I", "-Xcc",
                nativeSDKRoot
                    + "/render/include/skia/third_party/externals/vulkanmemoryallocator/include",
                "-Xcc", "-DJS_RUNTIME_HERMES=1", "-Xcc", "-DHERMES_V1_ENABLED=1", "-Xcc",
                "-DREACT_NATIVE_DEBUG=1", "-Xcc", "-DFOLLY_NO_CONFIG=1", "-Xcc", "-DFOLLY_MOBILE=0",
                "-Xcc",
                "-DFOLLY_CFG_NO_COROUTINES=1", "-Xcc", "-DFMT_USE_CONSTEVAL=0", "-Xcc",
                "-DSK_GRAPHITE",
                "-Xcc", "-DSK_VULKAN", "-Xcc", "-std=c++20",
            ]), .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusSessionProtocol",
        dependencies: ["NucleusConfig", "NucleusIPCTransport", "NucleusIPCTransportC"],
        path: "session/protocol/Sources/NucleusSessionProtocol",
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusSessionProtocolTests",
        dependencies: ["NucleusSessionProtocol", "NucleusIPCTransport", "NucleusIPCTransportC"],
        path: "session/protocol/Tests/NucleusSessionProtocolTests",
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .systemLibrary(name: "NucleusShellPamC", path: "shell/Sources/NucleusShellPamC"),
    .executableTarget(
        name: "NucleusShellPamHelper", dependencies: ["NucleusShellAuthWire", "NucleusShellPamC"],
        path: "shell/Sources/NucleusShellPamHelper", cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ], linkerSettings: [.unsafeFlags(["-lpam"])]),
    .executableTarget(
        name: "NucleusShellThreadSanitizerHarness", dependencies: ["NucleusShellRuntime"],
        path: "shell/SanitizerHarnesses/NucleusShellThreadSanitizerHarness",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .executableTarget(
        name: "NucleusShell", dependencies: ["NucleusShellRuntime"],
        path: "shell/Sources/NucleusShell",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusShellAuthWire", path: "shell/auth-wire/Sources/NucleusShellAuthWire",
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusShellAuthWireTests", dependencies: ["NucleusShellAuthWire"],
        path: "shell/auth-wire/Tests/NucleusShellInputTests",
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusShellSignalC", path: "shell/shell-kit/Sources/NucleusShellSignalC",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusShellProcessC", path: "shell/shell-kit/Sources/NucleusShellProcessC",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusShellProduct",
        dependencies: [
            "Nucleus", "NucleusApp", "NucleusAppHostBundle", "NucleusLayers", "NucleusRenderHost",
            "NucleusRenderModel", "NucleusRenderer", "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend",
            "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
        ], path: "shell/shell-kit/Sources/NucleusShellProduct",
        cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx),
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]),
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusShellServices",
        dependencies: [
            "NucleusFoundation", "NucleusLinuxPrimitives", "NucleusLinuxPrimitivesC",
            "NucleusLinuxReactor", "NucleusLinuxReactorC", "NucleusLinuxDBus",
            "NucleusLinuxSessionC",
            "NucleusThemeAssetIO", "Nucleus", "NucleusApp", "NucleusAppHostBundle", "NucleusLayers",
            "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend", "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
            "NucleusConfig", "NucleusSessionProtocol",
        ], path: "shell/shell-kit/Sources/NucleusShellServices",
        cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusShellAuth",
        dependencies: [
            "NucleusShellAuthWire", "NucleusShellProcessC", "NucleusShellProduct", "Nucleus",
            "NucleusApp", "NucleusAppHostBundle", "NucleusLayers", "NucleusRenderHost",
            "NucleusRenderModel", "NucleusRenderer", "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend",
            "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
        ], path: "shell/shell-kit/Sources/NucleusShellAuth", cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusShellRuntime",
        dependencies: [
            "NucleusFoundation", "NucleusWindowClientContracts", "NucleusWindowClientRuntime",
            "NucleusWindowClientWayland", "NucleusWindowClientPasteboard",
            "NucleusWindowClientRender",
            "NucleusWindowClientInput", "NucleusWindowClientHost", "NucleusShellSignalC",
            "NucleusShellProduct", "NucleusShellAuth", "NucleusShellServices",
            "NucleusLinuxPrimitives",
            "NucleusLinuxPrimitivesC", "NucleusLinuxReactor", "NucleusLinuxReactorC",
            "NucleusLinuxDBus",
            "NucleusLinuxSessionC", "NucleusThemeAssetIO", "NucleusLinuxAccessibility",
            "NucleusLinuxEnvironment", "NucleusSessionProtocol", "NucleusConfig", "Nucleus",
            "NucleusApp",
            "NucleusAppHostBundle", "NucleusLayers", "NucleusRenderHost", "NucleusRenderModel",
            "NucleusRenderer", "NucleusSkiaGraphiteBridge", "NucleusTextBackend",
            "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder", "Tracy",
        ], path: "shell/shell-kit/Sources/NucleusShellRuntime",
        cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .executableTarget(
        name: "NucleusShellPamAttemptFixture",
        path: "shell/shell-kit/Tests/Fixtures/NucleusShellPamAttemptFixture",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusWindowClientRuntimeTests",
        dependencies: [
            "NucleusWindowClientContracts", "NucleusWindowClientRuntime",
            "NucleusWindowClientWayland",
            "NucleusWindowClientPasteboard", "NucleusWindowClientRender",
            "NucleusWindowClientInput",
            "NucleusWindowClientHost", "NucleusShellSignalC",
        ], path: "shell/shell-kit/Tests/NucleusShellLoopTests",
        cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusShellServicesTests",
        dependencies: ["NucleusShellServices", "NucleusConfig", "NucleusSessionProtocol"],
        path: "shell/shell-kit/Tests/NucleusShellServicesTests",
        cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusShellAuthTests",
        dependencies: [
            "NucleusShellAuth", "NucleusShellAuthWire", "NucleusShellProcessC",
            "NucleusShellPamAttemptFixture", "Nucleus", "NucleusApp", "NucleusAppHostBundle",
            "NucleusLayers", "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge", "NucleusTextBackend", "NucleusTextRenderingBridge",
            "NucleusUI",
            "NucleusUIEmbedder",
        ], path: "shell/shell-kit/Tests/NucleusShellAuthTests",
        cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusShellProductTests",
        dependencies: [
            "NucleusShellProduct", "Nucleus", "NucleusApp", "NucleusAppHostBundle", "NucleusLayers",
            "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend", "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
            "NucleusFoundation",
        ], path: "shell/shell-kit/Tests/NucleusShellProductTests",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "TracyBridge", path: "swift-tracy/Sources/TracyBridge",
        cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [
            .headerSearchPath("../../third-party/tracy/public"), .unsafeFlags(["-std=c++20"]),
            .unsafeFlags(["-Werror"]),
        ],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ],
        linkerSettings: [
            .linkedLibrary("pthread", .when(platforms: [.linux])), .linkedLibrary("dl"),
        ]),
    .target(
        name: "Tracy", dependencies: ["TracyBridge"], path: "swift-tracy/Sources/Tracy",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "TracyTests", dependencies: ["Tracy"], path: "swift-tracy/Tests/TracyTests",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .systemLibrary(name: "VulkanC", path: "swift-vulkan/Sources/VulkanC"),
    .target(
        name: "Vulkan", dependencies: ["VulkanC"], path: "swift-vulkan/Sources/Vulkan",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .executableTarget(
        name: "VulkanGen", path: "swift-vulkan/Tools/VulkanGen",
        cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "VulkanTests", dependencies: ["Vulkan"], path: "swift-vulkan/Tests/VulkanTests",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "WaylandProtocolModel", path: "swift-wayland/Sources/WaylandProtocolModel",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "SwiftWaylandGenerator",
        dependencies: [
            "WaylandProtocolModel", .product(name: "SwiftBasicFormat", package: "swift-syntax"),
            .product(name: "SwiftSyntax", package: "swift-syntax"),
            .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
        ], path: "swift-wayland/Sources/SwiftWaylandGenerator",
        cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .executableTarget(
        name: "SwiftWaylandGen", dependencies: ["SwiftWaylandGenerator"],
        path: "swift-wayland/Sources/SwiftWaylandGen", cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .systemLibrary(
        name: "WaylandServerC", path: "swift-wayland/Sources/WaylandServerC",
        pkgConfig: "wayland-server"),
    .systemLibrary(
        name: "WaylandClientC", path: "swift-wayland/Sources/WaylandClientC",
        pkgConfig: "wayland-client"),
    .target(
        name: "WaylandServer",
        dependencies: [
            "WaylandServerC", "SwiftWaylandProtocolRuntime", "WaylandProtocolTypes",
            "WaylandProtocolsC",
        ], path: "swift-wayland/Sources/WaylandServer", cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx),
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]),
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "WaylandServerDispatch",
        dependencies: [
            "WaylandServerC", "WaylandServer", "SwiftWaylandProtocolRuntime",
            "WaylandProtocolTypes",
            "WaylandProtocolsC",
        ], path: "swift-wayland/Sources/WaylandServerDispatch",
        cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx),
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]),
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "WaylandClientDispatch",
        dependencies: [
            "WaylandClientC", "SwiftWaylandProtocolRuntime", "WaylandProtocolTypes",
            "WaylandProtocolsC",
        ], path: "swift-wayland/Sources/WaylandClientDispatch",
        cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx),
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]),
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "WaylandClient", dependencies: ["WaylandClientC", "WaylandClientDispatch"],
        path: "swift-wayland/Sources/WaylandClient", cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx),
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]),
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "WaylandClientCTests",
        dependencies: [
            "WaylandClientC", "SwiftWaylandProtocolRuntime", "WaylandProtocolTypes",
            "WaylandProtocolsC",
        ], path: "swift-wayland/Tests/WaylandClientCTests", cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "WaylandProtocolModelTests", dependencies: ["WaylandProtocolModel"],
        path: "swift-wayland/Tests/WaylandProtocolModelTests",
        cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "SwiftWaylandGeneratorTests",
        dependencies: ["SwiftWaylandGenerator", "WaylandProtocolModel"],
        path: "swift-wayland/Tests/SwiftWaylandGeneratorTests",
        cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "WaylandServerTests",
        dependencies: [
            "WaylandServer", "SwiftWaylandProtocolRuntime", "WaylandProtocolTypes",
            "WaylandProtocolsC",
        ], path: "swift-wayland/Tests/WaylandServerTests", cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx),
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]),
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "WaylandClientTests", dependencies: ["WaylandClient", "WaylandClientDispatch"],
        path: "swift-wayland/Tests/WaylandClientTests", cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx),
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]),
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "WaylandLoopbackTests",
        dependencies: [
            "WaylandServer", "WaylandServerDispatch", "WaylandClient", "WaylandClientDispatch",
            "SwiftWaylandProtocolRuntime", "WaylandProtocolTypes", "WaylandProtocolsC",
        ], path: "swift-wayland/Tests/WaylandLoopbackTests", cSettings: [.unsafeFlags(["-Werror"])],
        cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx),
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]),
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .systemLibrary(
        name: "WaylandUtilC", path: "swift-wayland/protocol-runtime/Sources/WaylandUtilC",
        pkgConfig: "wayland-client"),
    .target(
        name: "WaylandProtocolsC", dependencies: ["WaylandUtilC"],
        path: "swift-wayland/protocol-runtime/Sources/WaylandProtocolsC"),
    .target(
        name: "WaylandProtocolTypes",
        path: "swift-wayland/protocol-runtime/Sources/WaylandProtocolTypes",
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "SwiftWaylandProtocolRuntime", dependencies: ["WaylandProtocolTypes"],
        path: "swift-wayland/protocol-runtime/Sources/SwiftWaylandProtocolRuntime",
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusWindowClientContracts",
        path: "window-client/Sources/NucleusWindowClientContracts",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusWindowClientRuntime",
        dependencies: [
            "NucleusLinuxPrimitives", "NucleusLinuxPrimitivesC", "NucleusLinuxReactor",
            "NucleusLinuxReactorC", "NucleusLinuxDBus", "NucleusLinuxSessionC",
            "NucleusThemeAssetIO",
        ], path: "window-client/Sources/NucleusWindowClientRuntime",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .systemLibrary(
        name: "NucleusWindowClientXkbC", path: "window-client/Sources/NucleusWindowClientXkbC",
        pkgConfig: "xkbcommon"),
    .systemLibrary(
        name: "NucleusWindowClientVulkanWaylandC",
        path: "window-client/Sources/NucleusWindowClientVulkanWaylandC"),
    .target(
        name: "NucleusWindowClientWayland",
        dependencies: [
            "NucleusWindowClientContracts", "NucleusWindowClientXkbC", "NucleusWindowClientRuntime",
            "WaylandClientC", "WaylandClientDispatch", "WaylandClient",
            "SwiftWaylandProtocolRuntime",
            "WaylandProtocolTypes", "WaylandProtocolsC", "NucleusFoundation",
        ], path: "window-client/Sources/NucleusWindowClientWayland",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx),
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]),
            .unsafeFlags([]), .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusWindowClientPasteboard",
        dependencies: [
            "NucleusWindowClientWayland", "NucleusWindowClientRuntime", "WaylandClientC",
            "WaylandClientDispatch", "SwiftWaylandProtocolRuntime", "WaylandProtocolTypes",
            "WaylandProtocolsC", "Nucleus", "NucleusApp", "NucleusAppHostBundle", "NucleusLayers",
            "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend", "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
        ], path: "window-client/Sources/NucleusWindowClientPasteboard",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx),
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]),
            .strictMemorySafety(), .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusWindowClientRender",
        dependencies: [
            "NucleusFoundation", "NucleusWindowClientRuntime", "NucleusWindowClientWayland",
            "WaylandClientDispatch", "Nucleus", "NucleusApp", "NucleusAppHostBundle",
            "NucleusLayers",
            "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend", "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
            "Vulkan", "VulkanC", "Tracy", "NucleusWindowClientVulkanWaylandC",
        ], path: "window-client/Sources/NucleusWindowClientRender",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusWindowClientInput",
        dependencies: [
            "NucleusWindowClientWayland", "WaylandClientC", "WaylandClientDispatch",
            "SwiftWaylandProtocolRuntime", "WaylandProtocolTypes", "WaylandProtocolsC",
            "NucleusFoundation", "Nucleus", "NucleusApp", "NucleusAppHostBundle", "NucleusLayers",
            "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend", "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
        ], path: "window-client/Sources/NucleusWindowClientInput",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .target(
        name: "NucleusWindowClientHost",
        dependencies: [
            "NucleusWindowClientContracts", "NucleusWindowClientRuntime",
            "NucleusWindowClientWayland",
            "NucleusWindowClientPasteboard", "NucleusWindowClientRender",
            "NucleusWindowClientInput",
            "Nucleus", "NucleusApp", "NucleusAppHostBundle", "NucleusLayers", "NucleusRenderHost",
            "NucleusRenderModel", "NucleusRenderer", "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend",
            "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
        ], path: "window-client/Sources/NucleusWindowClientHost",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusWindowClientWaylandTests", dependencies: ["NucleusWindowClientWayland"],
        path: "window-client/Tests/NucleusWindowClientWaylandTests",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
    .testTarget(
        name: "NucleusWindowClientRenderTests",
        dependencies: [
            "NucleusWindowClientRender", "NucleusPresentationBackendContractTestSupport",
        ],
        path: "window-client/Tests/NucleusWindowClientRenderTests",
        cSettings: [.unsafeFlags(["-Werror"])], cxxSettings: [.unsafeFlags(["-Werror"])],
        swiftSettings: [
            .interoperabilityMode(.Cxx), .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]),
]
let androidTargets: [Target] = [
    .target(name: "NucleusAndroidC", path: "core/platform-android/c", publicHeadersPath: "."),
    .target(
        name: "NucleusAndroidCore",
        dependencies: [
            "NucleusAndroidHostLifecycle", "NucleusAndroidC", "Vulkan", "VulkanC", "Nucleus",
            "NucleusApp", "NucleusAppHostBundle", "NucleusLayers", "NucleusRenderHost",
            "NucleusRenderModel", "NucleusRenderer", "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend",
            "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
        ], path: "core/platform-android/swift-core",
        swiftSettings: [
            .strictMemorySafety(), .swiftLanguageMode(.v6), .interoperabilityMode(.Cxx),
            .unsafeFlags(["-warnings-as-errors", "-Werror", "StrictLanguageFeatures"]),
            .unsafeFlags([
                "-Xcc", "-I", "-Xcc",
                repoRoot + "/core/third-party/skia/third_party/externals/vulkan-headers/include",
                "-disable-cmo",
            ]),
        ],
        linkerSettings: [
            .linkedLibrary("vulkan"),
            .unsafeFlags([
                "-L",
                homeDirectory
                    + "/.cache/nucleus/swift-platforms/release-6.4.x/current/android/swift-release-6.4.x_android.artifactbundle/swift-android/swift-resources/usr/lib/swift-aarch64/android",
            ]),
        ]),
    .target(
        name: "NucleusAndroidJNI",
        dependencies: [
            "NucleusAndroidHostLifecycle", "NucleusAndroidCore", "NucleusAndroidC",
            .product(name: "SwiftJava", package: "swift-java"),
        ], path: "core/platform-android/swift-jni", exclude: ["swift-java.config"],
        swiftSettings: [
            .strictMemorySafety(), .swiftLanguageMode(.v6), .interoperabilityMode(.Cxx),
            .unsafeFlags(["-warnings-as-errors", "-Werror", "StrictLanguageFeatures"]),
        ],
        linkerSettings: [
            .linkedLibrary("android"),
            .unsafeFlags([
                "-Xlinker", "-soname", "-Xlinker", "libnucleus-android.so", "-Xlinker", "-z",
                "-Xlinker",
                "max-page-size=16384",
            ]),
        ]),
]

let package = Package(
    name: "Nucleus",
    products: hostProducts + (isAndroidTarget ? androidProducts : []),
    dependencies: hostDependencies + (isAndroidTarget ? androidDependencies : []),
    targets: hostTargets + (isAndroidTarget ? androidTargets : []),
    cxxLanguageStandard: .cxx20)
