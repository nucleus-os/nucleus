// swift-tools-version: 6.4
//
// Canonical first-party Swift package. Generated once during the package
// consolidation; this manifest is the maintained source of truth.

import PackageDescription

func linuxPkgConfig(_ name: String) -> String? {
    #if os(Linux)
    name
    #else
    nil
    #endif
}

let products: [Product] = [
    .library(name: "NucleusAndroidRuntimeCore", targets: ["NucleusAndroidRuntimeCore"]),
    .executable(name: "nucleus-android-runtime", targets: ["NucleusAndroidRuntime"]),
    .executable(
        name: "nucleus-android-runtime-privileged",
        targets: ["NucleusAndroidRuntimePrivileged"]),
    .executable(name: "nucleus-android-gpu-broker", targets: ["NucleusAndroidGpuBroker"]),
    .executable(
        name: "nucleus-android-gfxstream-workload", targets: ["NucleusAndroidGfxstreamWorkload"]),
    .executable(
        name: "nucleus-android-gfxstream-broker", targets: ["NucleusAndroidGfxstreamBroker"]),
    .executable(name: "nucleus-android-display-host", targets: ["NucleusAndroidDisplayHost"]),
    .executable(
        name: "nucleus-android-shared-ring-stress", targets: ["NucleusAndroidSharedRingStress"]),
    .executable(
        name: "NucleusAndroidThreadSanitizerHarness",
        targets: ["NucleusAndroidThreadSanitizerHarness"]),
    .executable(
        name: "NucleusRenderServerThreadSanitizerHarness",
        targets: ["NucleusRenderServerThreadSanitizerHarness"]),
    .executable(name: "NucleusConfigService", targets: ["NucleusConfigServiceExecutable"]),
    .library(name: "Nucleus", targets: ["Nucleus"]),
    .executable(name: "NucleusHeadlessBenchmarks", targets: ["NucleusHeadlessBenchmarks"]),
    .executable(
        name: "NucleusCoreThreadSanitizerHarness", targets: ["NucleusCoreThreadSanitizerHarness"]),
    .library(name: "NucleusDesktop", targets: ["NucleusDesktop"]),
    .library(name: "NucleusFoundation", targets: ["NucleusFoundation"]),
    .executable(name: "nucleus", targets: ["NucleusControlCLI"]),
    .executable(name: "NucleusControlService", targets: ["NucleusControlServiceExecutable"]),
    .executable(
        name: "NucleusLinuxThreadSanitizerHarness", targets: ["NucleusLinuxThreadSanitizerHarness"]),
    .executable(name: "NucleusLinuxBenchmarks", targets: ["NucleusLinuxBenchmarks"]),
    .executable(name: "NucleusSessionSupervisor", targets: ["NucleusSessionSupervisor"]),
    .library(name: "NucleusReactRuntime", targets: ["NucleusReactRuntime"]),
    .executable(
        name: "NucleusReactThreadSanitizerHarness", targets: ["NucleusReactThreadSanitizerHarness"]),
    .executable(name: "NucleusReactBenchmarks", targets: ["NucleusReactBenchmarks"]),
    .library(name: "NucleusSessionProtocol", targets: ["NucleusSessionProtocol"]),
    .executable(name: "SwiftWaylandGen", targets: ["SwiftWaylandGen"]),
    .library(name: "nucleus-android", type: .dynamic, targets: ["NucleusAndroidDeployment"]),
]
let dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-binary-parsing.git", exact: "0.0.2"),
    .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1"),
    .package(url: "https://github.com/swift-server/async-http-client.git", branch: "main"),
    .package(name: "swift-argument-parser", path: "third-party/swift-argument-parser"),
    .package(name: "swift-java", path: "third-party/swift-java"),
    .package(url: "https://github.com/apple/swift-nio.git", branch: "main"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", branch: "main"),
    .package(
        url: "https://github.com/swiftlang/swift-syntax.git",
        revision: "050f1a346fbbac0ca2cfb15a95274f7bd1cf0ccf"),
    .package(url: "https://github.com/nucleus-os/swift-system.git", branch: "nucleus"),
]

let reactNativeSwiftSettings: [SwiftSetting] = [
    .unsafeFlags([
        "-Xcc", "-DJS_RUNTIME_HERMES=1",
        "-Xcc", "-DHERMES_V1_ENABLED=1",
        "-Xcc", "-DREACT_NATIVE_DEBUG=1",
        "-Xcc", "-DFOLLY_NO_CONFIG=1",
        "-Xcc", "-DFOLLY_MOBILE=0",
        "-Xcc", "-DFOLLY_CFG_NO_COROUTINES=1",
        "-Xcc", "-DFMT_USE_CONSTEVAL=0",
        "-Xcc", "-DSK_GRAPHITE",
        "-Xcc", "-DSK_VULKAN",
        "-Xcc", "-std=c++20",
    ])
]

let reactNativeBridgeCxxSettings: [CXXSetting] = [
    .unsafeFlags([
        "-std=c++20", "-DFOLLY_NO_CONFIG=1", "-DFOLLY_MOBILE=0", "-DFOLLY_USE_LIBCPP=1",
        "-DFOLLY_CFG_NO_COROUTINES=1", "-DFOLLY_HAVE_CLOCK_GETTIME=1",
        "-DFOLLY_HAVE_PTHREAD=1",
    ])
]

let reactNativeHostCxxSettings: [CXXSetting] = [
    .unsafeFlags([
        "-std=c++20", "-fexceptions", "-frtti", "-DJS_RUNTIME_HERMES=1",
        "-DHERMES_V1_ENABLED=1", "-DREACT_NATIVE_DEBUG=1", "-DFOLLY_NO_CONFIG=1",
        "-DFOLLY_MOBILE=0", "-DFOLLY_CFG_NO_COROUTINES=1", "-DFMT_USE_CONSTEVAL=0",
        "-DSK_GRAPHITE", "-DSK_VULKAN", "-DNUCLEUS=1",
    ])
]

let reactNativeRuntimeLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-Xlinker", "--start-group", "-lhermes_lean_combined", "-lreact_native",
        "-lworklets", "-lreanimated",
        "-lreact_cxx_platform", "-lyogacore", "-lfolly_runtime", "-lglog", "-lfmt",
        "-ldouble-conversion", "-Xlinker", "--end-group", "-latomic", "-lpthread", "-ldl",
        "-lm", "-Xlinker", "--start-group", "-lskia", "-lskshaper", "-lskparagraph",
        "-lskunicode_core", "-lskunicode_icu", "-lsvg", "-lskcms", "-lskresources",
        "-lfreetype2", "-lharfbuzz", "-licu", "-lpng", "-ljpeg", "-ljpeg12", "-ljpeg16",
        "-lwebp", "-lwebp_sse41", "-lexpat", "-lzlib", "-lwuffs", "-ldng_sdk", "-lpiex",
        "-Xlinker", "--end-group", "-ldl",
        "-lpthread", "-lm",
    ])
]

let targets: [Target] = [
    .target(
        name: "NucleusAndroidProcessLifecycleC",
        path: "android-runtime/Sources/NucleusAndroidProcessLifecycleC"),
    .target(
        name: "NucleusAndroidComposerProtocolC",
        path: "android-runtime/aosp/device/nucleus/nucleus_x86_64/native/composer-protocol"),
    .target(
        name: "NucleusAndroidPresentationProtocolC",
        path:
            "android-runtime/aosp/device/nucleus/nucleus_x86_64/native/presentation-protocol"),
    .target(
        name: "NucleusAndroidDisplayControlProtocolC",
        path:
            "android-runtime/aosp/device/nucleus/nucleus_x86_64/native/display-control-protocol"),
    .target(
        name: "NucleusAndroidSharedRingC",
        path: "android-runtime/aosp/device/nucleus/nucleus_x86_64/native/shared-ring"),
    .target(
        name: "NucleusAndroidGfxstreamWorkerProtocolC",
        path: "android-runtime/Sources/NucleusAndroidGfxstreamWorkerProtocolC"),
    .target(
        name: "NucleusAndroidGfxstreamGuestTransportCxx",
        dependencies: ["NucleusIPCTransport", "NucleusIPCTransportC", "NucleusAndroidSharedRingC"],
        path: "android-runtime/aosp/device/nucleus/nucleus_x86_64/native/gfxstream-guest"),
    .target(
        name: "NucleusAndroidGfxstreamAdaptersCxx",
        dependencies: ["NucleusAndroidGfxstreamGuestTransportCxx", "NucleusAndroidSharedRingC"],
        path: "android-runtime/Sources/NucleusAndroidGfxstreamAdaptersCxx",
        linkerSettings: [.linkedLibrary("dl")]),
    .target(
        name: "NucleusAndroidGfxstreamAdaptersTestSupport",
        dependencies: ["NucleusAndroidGfxstreamAdaptersCxx", "NucleusAndroidSharedRingC"],
        path: "android-runtime/Tests/Support",
        sources: ["NucleusAndroidGfxstreamAdaptersTestSupport/AdapterBehaviorTests.cpp"],
        publicHeadersPath: "NucleusAndroidGfxstreamAdaptersTestSupport/include"),
    .target(
        name: "NucleusAndroidGfxstreamHostC",
        dependencies: ["NucleusAndroidGfxstreamAdaptersCxx", "NucleusAndroidSharedRingC"],
        path: "android-runtime/Sources/NucleusAndroidGfxstreamHostC",
        linkerSettings: [
            .linkedLibrary("gfxstream_backend"), .linkedLibrary("dl"), .linkedLibrary("rt"),
        ]),
    .target(
        name: "NucleusAndroidDrmC",
        dependencies: ["NucleusCompositorDrmC", "VulkanC"],
        path: "android-runtime/Sources/NucleusAndroidDrmC"),
    .target(
        name: "NucleusAndroidGraphicsContract",
        path: "android-runtime/Sources/NucleusAndroidGraphicsContract"),
    .target(
        name: "NucleusAndroidIPC",
        dependencies: [
            "NucleusAndroidGraphicsContract", "NucleusIPCTransport", "NucleusIPCTransportC",
        ], path: "android-runtime/Sources/NucleusAndroidIPC"),
    .target(
        name: "NucleusAndroidGfxstreamTransport", dependencies: ["NucleusAndroidSharedRingC"],
        path: "android-runtime/Sources/NucleusAndroidGfxstreamTransport"),
    .target(
        name: "NucleusAndroidGraphicsPlatform",
        dependencies: ["NucleusAndroidGraphicsContract", "NucleusAndroidDrmC"],
        path: "android-runtime/Sources/NucleusAndroidGraphicsPlatform"),
    .target(
        name: "NucleusAndroidGpuBrokerCore",
        dependencies: [
            "NucleusAndroidGraphicsContract", "NucleusAndroidGraphicsPlatform", "NucleusAndroidIPC",
        ], path: "android-runtime/Sources/NucleusAndroidGpuBrokerCore"),
    .target(
        name: "NucleusAndroidContainerContract",
        dependencies: [
            .product(name: "BinaryParsing", package: "swift-binary-parsing"),
            .product(name: "SwiftProtobuf", package: "swift-protobuf"),
        ],
        path: "android-runtime/Sources/NucleusAndroidContainerContract"),
    .target(
        name: "NucleusAndroidRuntimeCore",
        dependencies: [
            "NucleusAndroidContainerContract",
            "NucleusAndroidRuntimePlatformC",
        ],
        path: "android-runtime/Sources/NucleusAndroidRuntimeCore"),
    .target(
        name: "NucleusAndroidRuntimeBridgeProtocol",
        dependencies: [
            "NucleusAndroidRuntimeCore",
            "NucleusIPCTransport",
        ],
        path:
            "android-runtime/Sources/NucleusAndroidRuntimeBridgeProtocol"),
    .target(
        name: "NucleusAndroidRuntimeBrokerCore",
        dependencies: [
            "NucleusAndroidRuntimeBridgeProtocol",
            "NucleusAndroidRuntimeCore",
            "NucleusSessionProtocol",
        ],
        path: "android-runtime/Sources/NucleusAndroidRuntimeBrokerCore"),
    .target(
        name: "NucleusAndroidRuntimePlatformC",
        path: "android-runtime/Sources/NucleusAndroidRuntimePlatformC"),
    .target(
        name: "NucleusAndroidRuntimeHostLinux",
        dependencies: [
            "NucleusAndroidRuntimeCore",
            "NucleusAndroidRuntimePlatformC",
        ],
        path: "android-runtime/Sources/NucleusAndroidRuntimeHostLinux"),
    .executableTarget(
        name: "NucleusAndroidRuntime",
        dependencies: [
            "NucleusAndroidRuntimeBrokerCore",
            "NucleusAndroidRuntimeCore",
            "NucleusAndroidRuntimeHostLinux",
            "NucleusSessionProtocol",
        ],
        path: "android-runtime/Sources/NucleusAndroidRuntime"),
    .executableTarget(
        name: "NucleusAndroidRuntimePrivileged",
        dependencies: ["NucleusAndroidRuntimeCore"],
        path: "android-runtime/Sources/NucleusAndroidRuntimePrivileged"),
    .executableTarget(
        name: "NucleusAndroidGpuBroker",
        dependencies: [
            "NucleusAndroidGraphicsContract", "NucleusAndroidGraphicsPlatform",
            "NucleusAndroidGpuBrokerCore", "NucleusAndroidIPC", "NucleusAndroidProcessLifecycleC",
            "NucleusIPCTransport", "NucleusIPCTransportC", "NucleusAndroidGfxstreamWorkerProtocolC",
            "NucleusLinuxPrimitives", "NucleusLinuxPrimitivesC", "NucleusLinuxReactor",
            "NucleusLinuxReactorC", "NucleusLinuxDBus", "NucleusLinuxSessionC",
            "NucleusThemeAssetIO",
        ], path: "android-runtime/Sources/NucleusAndroidGpuBroker"),
    .executableTarget(
        name: "NucleusAndroidGfxstreamWorkload",
        dependencies: [
            "NucleusAndroidDrmC", "NucleusAndroidGfxstreamAdaptersCxx",
            "NucleusAndroidGfxstreamHostC",
            "NucleusAndroidProcessLifecycleC", "NucleusIPCTransport", "NucleusIPCTransportC",
            "NucleusAndroidSharedRingC", "NucleusAndroidGfxstreamWorkerProtocolC",
        ], path: "android-runtime/Sources/NucleusAndroidGfxstreamWorkload",
        linkerSettings: [.linkedLibrary("dl"), .linkedLibrary("pthread")]),
    .executableTarget(
        name: "NucleusAndroidGfxstreamBroker",
        dependencies: [
            "NucleusAndroidDrmC", "NucleusAndroidGfxstreamGuestTransportCxx",
            "NucleusAndroidGfxstreamHostC", "NucleusAndroidProcessLifecycleC",
            "NucleusIPCTransport",
            "NucleusIPCTransportC", "NucleusAndroidSharedRingC",
        ], path: "android-runtime/Sources/NucleusAndroidGfxstreamBroker",
        linkerSettings: [
            .linkedLibrary("pthread"), .unsafeFlags(["-Xlinker", "--export-dynamic"]),
        ]),
    .executableTarget(
        name: "NucleusAndroidDisplayHost", dependencies: ["NucleusAndroidDisplayHostCore"],
        path: "android-runtime/Sources/NucleusAndroidDisplayHost"),
    .target(
        name: "NucleusAndroidDisplayHostCore",
        dependencies: [
            "NucleusAndroidComposerProtocolC",
            "NucleusAndroidDisplayControlProtocolC", "NucleusAndroidDrmC",
            "NucleusAndroidGraphicsContract",
            "NucleusAndroidGraphicsPlatform", "NucleusAndroidProcessLifecycleC",
            "NucleusAndroidPresentationProtocolC",
            "NucleusAndroidRuntimeBridgeProtocol",
            "NucleusIPCTransport",
            "NucleusIPCTransportC", "NucleusLinuxPrimitives", "NucleusLinuxPrimitivesC",
            "NucleusLinuxReactor", "NucleusLinuxReactorC", "NucleusLinuxDBus",
            "NucleusLinuxSessionC",
            "NucleusThemeAssetIO", "WaylandClient", "WaylandClientC", "WaylandClientDispatch",
            "WaylandProtocolTypes", "WaylandProtocolsC",
        ], path: "android-runtime/Sources/NucleusAndroidDisplayHostCore",
        swiftSettings: [
            .enableUpcomingFeature("InternalImportsByDefault"),
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]),
        ]),
    .executableTarget(
        name: "NucleusAndroidSharedRingStress", dependencies: ["NucleusAndroidSharedRingC"],
        path: "android-runtime/Sources/NucleusAndroidSharedRingStress"),
    .testTarget(
        name: "NucleusAndroidGraphicsContractTests",
        dependencies: ["NucleusAndroidGraphicsContract"],
        path: "android-runtime/Tests/NucleusAndroidGraphicsContractTests"),
    .testTarget(
        name: "NucleusAndroidContainerContractTests",
        dependencies: ["NucleusAndroidContainerContract"],
        path: "android-runtime/Tests/NucleusAndroidContainerContractTests"),
    .testTarget(
        name: "NucleusAndroidRuntimeCoreTests",
        dependencies: ["NucleusAndroidRuntimeCore"],
        path: "android-runtime/Tests/NucleusAndroidRuntimeCoreTests"),
    .testTarget(
        name: "NucleusAndroidRuntimeHostLinuxTests",
        dependencies: ["NucleusAndroidRuntimeHostLinux"],
        path:
            "android-runtime/Tests/NucleusAndroidRuntimeHostLinuxTests"),
    .testTarget(
        name: "NucleusAndroidRuntimeBridgeProtocolTests",
        dependencies: [
            "NucleusAndroidRuntimeBridgeProtocol",
            "NucleusAndroidRuntimeBrokerCore",
            "NucleusIPCTransport",
            "NucleusSessionProtocol",
        ],
        path:
            "android-runtime/Tests/NucleusAndroidRuntimeBridgeProtocolTests"),
    .testTarget(
        name: "NucleusAndroidIPCTests",
        dependencies: ["NucleusAndroidGraphicsContract", "NucleusAndroidIPC"],
        path: "android-runtime/Tests/NucleusAndroidIPCTests"),
    .testTarget(
        name: "NucleusAndroidGfxstreamTransportTests",
        dependencies: ["NucleusAndroidGfxstreamTransport"],
        path: "android-runtime/Tests/NucleusAndroidGfxstreamTransportTests"),
    .testTarget(
        name: "NucleusAndroidGfxstreamAdaptersTests",
        dependencies: ["NucleusAndroidGfxstreamAdaptersTestSupport"],
        path: "android-runtime/Tests/NucleusAndroidGfxstreamAdaptersTests"),
    .testTarget(
        name: "NucleusAndroidGraphicsPlatformTests",
        dependencies: [
            "NucleusAndroidDrmC", "NucleusAndroidDrmCTestSupport",
            "NucleusAndroidGraphicsContract",
            "NucleusAndroidGraphicsPlatform",
        ], path: "android-runtime/Tests/NucleusAndroidGraphicsPlatformTests"),
    .target(
        name: "NucleusAndroidDrmCTestSupport",
        dependencies: ["NucleusAndroidDrmC"],
        path: "android-runtime/Tests/Support/NucleusAndroidDrmCTestSupport"),
    .executableTarget(
        name: "NucleusAndroidThreadSanitizerHarness",
        dependencies: [
            "NucleusAndroidDrmC", "NucleusAndroidDrmCTestSupport",
            "NucleusAndroidGfxstreamTransport",
        ], path: "android-runtime/SanitizerHarnesses/NucleusAndroidThreadSanitizerHarness"),
    .testTarget(
        name: "NucleusAndroidGpuBrokerCoreTests",
        dependencies: [
            "NucleusAndroidGraphicsContract", "NucleusAndroidGraphicsPlatform",
            "NucleusAndroidGpuBrokerCore", "NucleusAndroidIPC",
        ], path: "android-runtime/Tests/NucleusAndroidGpuBrokerCoreTests"),
    .testTarget(
        name: "NucleusAndroidDisplayHostCoreTests",
        dependencies: [
            "NucleusAndroidComposerProtocolC", "NucleusAndroidDisplayHostCore",
            "NucleusIPCTransport", "NucleusIPCTransportC",
            "NucleusLinuxPrimitives", "NucleusLinuxPrimitivesC", "NucleusLinuxReactor",
            "NucleusLinuxReactorC", "NucleusLinuxDBus", "NucleusLinuxSessionC",
            "NucleusThemeAssetIO",
        ], path: "android-runtime/Tests/NucleusAndroidDisplayHostCoreTests"),
    .target(
        name: "NucleusCompositorServerTypes",
        path: "compositor/compositor-core/Sources/NucleusCompositorServerTypes"),
    .systemLibrary(
        name: "NucleusCompositorDrmC",
        path: "compositor/compositor-core/Sources/NucleusCompositorDrmC",
        pkgConfig: linuxPkgConfig("nucleus-compositor-drm")),
    .systemLibrary(
        name: "NucleusCompositorXcbC",
        path: "compositor/compositor-core/Sources/NucleusCompositorXcbC",
        pkgConfig: linuxPkgConfig("nucleus-compositor-xcb")),
    .systemLibrary(
        name: "NucleusCompositorInputC",
        path: "compositor/compositor-core/Sources/NucleusCompositorInputC",
        pkgConfig: linuxPkgConfig("nucleus-compositor-input")),
    .target(
        name: "NucleusCompositorSignalC",
        path: "compositor/compositor-core/Sources/NucleusCompositorSignalC"),
    .target(
        name: "NucleusCompositorRenderSession",
        path: "compositor/compositor-core/Sources/NucleusCompositorRenderSession"),
    .target(
        name: "WaylandWireTestC", path: "compositor/compositor-core/Tests/WaylandWireTestC"),
    .target(
        name: "NucleusCompositorServer",
        dependencies: [
            "NucleusFoundation", "Nucleus", "NucleusApp", "NucleusAppHostBundle", "NucleusLayers",
            "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend", "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
            "NucleusCompositorServerTypes",
        ], path: "compositor/compositor-core/Sources/NucleusCompositorServer"),
    .target(
        name: "NucleusCompositorWindowManager",
        dependencies: [
            "NucleusFoundation", "Nucleus", "NucleusApp", "NucleusAppHostBundle", "NucleusLayers",
            "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend", "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
            "NucleusCompositorServerTypes", "NucleusCompositorServer", "Tracy",
        ], path: "compositor/compositor-core/Sources/NucleusCompositorWindowManager"),
    .target(
        name: "NucleusCompositorWindowScene",
        dependencies: [
            "NucleusFoundation", "Nucleus", "NucleusApp", "NucleusAppHostBundle", "NucleusLayers",
            "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend", "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
            "NucleusCompositorServerTypes",
        ], path: "compositor/compositor-core/Sources/NucleusCompositorWindowScene"),
    .target(
        name: "NucleusCompositorPolicy",
        dependencies: [
            "NucleusCompositorServer", "NucleusCompositorServerTypes",
            "NucleusCompositorWindowManager", "Nucleus", "NucleusApp",
            "NucleusAppHostBundle", "NucleusLayers", "NucleusRenderHost", "NucleusRenderModel",
            "NucleusRenderer", "NucleusSkiaGraphiteBridge", "NucleusTextBackend",
            "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder", "NucleusFoundation",
            "NucleusConfig", "NucleusLinuxPrimitives", "NucleusLinuxPrimitivesC",
            "NucleusLinuxReactor",
            "NucleusLinuxReactorC", "NucleusLinuxDBus", "NucleusLinuxSessionC",
            "NucleusThemeAssetIO",
            "NucleusSessionProtocol",
            .product(name: "BinaryParsing", package: "swift-binary-parsing"),
        ], path: "compositor/compositor-core/Sources/NucleusCompositorPolicy"),
    .target(
        name: "NucleusCompositorWaylandRuntime",
        dependencies: [
            "NucleusFoundation", "WaylandServerC", "WaylandServer", "WaylandServerDispatch",
            "WaylandProtocolTypes", "WaylandProtocolsC",
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
            .product(name: "BinaryParsing", package: "swift-binary-parsing"),
        ], path: "compositor/compositor-core/Sources/NucleusCompositorWaylandRuntime",
        swiftSettings: [
            .enableUpcomingFeature("InternalImportsByDefault"),
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]),
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
        ], path: "compositor/compositor-core/Tests",
        exclude: [
            "NucleusCompositorPolicyTests",
            "NucleusCompositorRenderRuntimeTests",
            "NucleusCompositorRenderSessionTests",
            "NucleusCompositorRendererLinuxTests",
            "NucleusCompositorServerTests",
            "NucleusCompositorWaylandCTests",
            "NucleusCompositorWaylandRuntimeTests",
            "NucleusCompositorWindowManagerTests",
            "NucleusCompositorWindowSceneTests",
            "NucleusRenderServerRuntimeTests",
            "WaylandWireTestC",
        ],
        sources: ["Support/NucleusRenderServerTestSupport/WaylandRouterTestFixture.swift"],
        swiftSettings: [
            .enableUpcomingFeature("InternalImportsByDefault"),
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]),
        ]),
    .target(
        name: "NucleusCompositorRendererLinux",
        dependencies: [
            "NucleusAppHostProtocols", "NucleusFoundation", "Nucleus", "NucleusApp",
            "NucleusAppHostBundle", "NucleusLayers",
            "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend", "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
            "VulkanC", "Vulkan", "Tracy", "NucleusCompositorDrmC",
            .product(name: "BinaryParsing", package: "swift-binary-parsing"),
        ], path: "compositor/compositor-core/Sources/NucleusCompositorRendererLinux"),
    .target(
        name: "NucleusCompositorRenderRuntime",
        dependencies: [
            "NucleusAppHostProtocols", "Nucleus", "NucleusApp", "NucleusAppHostBundle",
            "NucleusLayers", "NucleusRenderHost",
            "NucleusRenderModel", "NucleusRenderer", "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend",
            "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
            "NucleusCompositorRendererLinux", "VulkanC", "NucleusCompositorDrmC", "Tracy",
            "NucleusCompositorServer",
        ], path: "compositor/compositor-core/Sources/NucleusCompositorRenderRuntime"),
    .target(
        name: "NucleusRenderServerRuntime",
        dependencies: [
            "NucleusAppHostProtocols", "NucleusFoundation", "Nucleus", "NucleusApp",
            "NucleusAppHostBundle", "NucleusLayers",
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
        swiftSettings: [
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"])
        ]),
    .executableTarget(
        name: "NucleusRenderServerThreadSanitizerHarness",
        dependencies: [
            "NucleusRenderServerRuntime", "NucleusCompositorSignalC",
            "NucleusCompositorWaylandRuntime",
            "NucleusRenderServerTestSupport",
        ],
        path:
            "compositor/compositor-core/SanitizerHarnesses/NucleusRenderServerThreadSanitizerHarness"
    ),
    .testTarget(
        name: "NucleusCompositorRenderSessionTests",
        dependencies: ["NucleusCompositorRenderSession"],
        path: "compositor/compositor-core/Tests/NucleusCompositorRenderSessionTests"),
    .testTarget(
        name: "NucleusRenderServerRuntimeTests",
        dependencies: ["NucleusRenderServerRuntime", "NucleusConfig"],
        path: "compositor/compositor-core/Tests/NucleusRenderServerRuntimeTests",
        swiftSettings: [
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"])
        ]),
    .testTarget(
        name: "NucleusCompositorRendererLinuxTests",
        dependencies: [
            "NucleusAppHostProtocols", "NucleusCompositorRendererLinux", "Nucleus", "NucleusApp",
            "NucleusAppHostBundle",
            "NucleusLayers", "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge", "NucleusTextBackend", "NucleusTextRenderingBridge",
            "NucleusUI",
            "NucleusUIEmbedder", "NucleusPresentationBackendContractTestSupport",
            "NucleusFoundation",
            "Vulkan",
        ], path: "compositor/compositor-core/Tests/NucleusCompositorRendererLinuxTests"),
    .testTarget(
        name: "NucleusCompositorRenderRuntimeTests",
        dependencies: [
            "NucleusAppHostProtocols", "NucleusCompositorRenderRuntime",
            "NucleusCompositorRendererLinux",
            "NucleusCompositorServer",
            "Nucleus", "NucleusApp", "NucleusAppHostBundle", "NucleusLayers", "NucleusRenderHost",
            "NucleusRenderModel", "NucleusRenderer", "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend",
            "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
        ], path: "compositor/compositor-core/Tests/NucleusCompositorRenderRuntimeTests"),
    .testTarget(
        name: "NucleusCompositorWaylandCTests",
        dependencies: [
            "WaylandServerC", "WaylandProtocolTypes",
            "WaylandProtocolsC",
        ], path: "compositor/compositor-core/Tests/NucleusCompositorWaylandCTests"),
    .testTarget(
        name: "NucleusCompositorServerTests", dependencies: ["NucleusCompositorServer"],
        path: "compositor/compositor-core/Tests/NucleusCompositorServerTests"),
    .testTarget(
        name: "NucleusCompositorWindowManagerTests",
        dependencies: ["NucleusCompositorServer", "NucleusCompositorWindowManager"],
        path: "compositor/compositor-core/Tests/NucleusCompositorWindowManagerTests"),
    .testTarget(
        name: "NucleusCompositorWaylandRuntimeTests",
        dependencies: [
            "NucleusCompositorWaylandRuntime", "NucleusCompositorServer",
            "NucleusCompositorServerTypes", "NucleusCompositorWindowManager",
            "NucleusCompositorWindowScene", "NucleusConfig",
            "Nucleus",
            "NucleusApp", "NucleusAppHostBundle", "NucleusLayers", "NucleusRenderHost",
            "NucleusRenderModel", "NucleusRenderer", "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend",
            "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder", "NucleusCompositorXcbC",
            "NucleusCompositorInputC", "WaylandServerC", "WaylandServer",
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
        ],
        swiftSettings: [
            .enableUpcomingFeature("InternalImportsByDefault"),
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]),
        ]),
    .testTarget(
        name: "NucleusCompositorPolicyTests",
        dependencies: [
            "NucleusCompositorPolicy", "NucleusCompositorServer", "NucleusCompositorServerTypes",
            "NucleusConfig", "Nucleus", "NucleusApp",
            "NucleusAppHostBundle",
            "NucleusLayers", "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge", "NucleusTextBackend", "NucleusTextRenderingBridge",
            "NucleusUI",
            "NucleusUIEmbedder",
        ], path: "compositor/compositor-core/Tests/NucleusCompositorPolicyTests"),
    .testTarget(
        name: "NucleusCompositorWindowSceneTests",
        dependencies: [
            "NucleusCompositorWindowScene", "Nucleus", "NucleusApp", "NucleusAppHostBundle",
            "NucleusLayers", "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge", "NucleusTextBackend", "NucleusTextRenderingBridge",
            "NucleusUI",
            "NucleusUIEmbedder",
        ], path: "compositor/compositor-core/Tests/NucleusCompositorWindowSceneTests"),
    .executableTarget(
        name: "NucleusCompositor",
        dependencies: [
            "NucleusRenderServerRuntime", "NucleusFoundation", "NucleusSessionProtocol",
        ],
        path: "compositor/compositor/Sources/NucleusCompositor",
        linkerSettings: [.unsafeFlags(["-Xlinker", "--as-needed"])]),
    .target(
        name: "NucleusConfigSyntax", path: "config/Sources/NucleusConfigSyntax"),
    .testTarget(
        name: "NucleusConfigSyntaxTests", dependencies: ["NucleusConfigSyntax"],
        path: "config/Tests/NucleusConfigSyntaxTests"),
    .target(
        name: "NucleusConfigIO", dependencies: ["NucleusConfigSyntax", "NucleusConfig"],
        path: "config/Sources/NucleusConfigIO",
        swiftSettings: [
            .enableUpcomingFeature("InternalImportsByDefault")
        ]),
    .testTarget(
        name: "NucleusConfigTests",
        dependencies: ["NucleusConfigIO", "NucleusConfigSyntax", "NucleusConfig"],
        path: "config/Tests/NucleusConfigTests"),
    .target(
        name: "NucleusConfigService",
        dependencies: [
            "NucleusConfig", "NucleusConfigIO", "NucleusConfigSyntax", "NucleusLinuxPrimitives",
            "NucleusLinuxPrimitivesC", "NucleusLinuxReactor", "NucleusLinuxReactorC",
            "NucleusLinuxDBus",
            "NucleusLinuxSessionC", "NucleusThemeAssetIO", "NucleusSessionProtocol",
        ], path: "config/config-service-core/Sources/NucleusConfigService",
        swiftSettings: [
            .enableUpcomingFeature("InternalImportsByDefault")
        ]),
    .testTarget(
        name: "NucleusConfigServiceTests", dependencies: ["NucleusConfigService"],
        path: "config/config-service-core/Tests/NucleusConfigServiceTests"),
    .executableTarget(
        name: "NucleusConfigServiceExecutable", dependencies: ["NucleusConfigService"],
        path: "config/config-service/Sources/NucleusConfigServiceExecutable"),
    .target(
        name: "NucleusConfig", path: "config/model/Sources/NucleusConfig"),
    .testTarget(
        name: "NucleusConfigModelTests", dependencies: ["NucleusConfig"],
        path: "config/model/Tests/NucleusConfigModelTests"),
    .target(
        name: "Nucleus",
        dependencies: [
            "NucleusApp", "NucleusUI", "NucleusFoundation",
            .target(name: "NucleusRenderSystemC", condition: .when(platforms: [.linux])),
        ],
        path: "core/swift/Sources/Nucleus",
        linkerSettings: [
            .unsafeFlags(
                [
                    "-Xlinker", "--start-group", "-lskia",
                    "-lskshaper", "-lskparagraph", "-lskunicode_core", "-lskunicode_icu", "-lsvg",
                    "-lskcms",
                    "-lskresources", "-lfreetype2", "-lharfbuzz", "-licu", "-lpng", "-ljpeg",
                    "-ljpeg12",
                    "-ljpeg16", "-lwebp", "-lwebp_sse41", "-lexpat", "-lzlib", "-lwuffs",
                    "-ldng_sdk",
                    "-lpiex", "-Xlinker", "--end-group", "-ldl", "-lpthread", "-lm", "-Xlinker",
                    "--exclude-libs=ALL", "-Xlinker",
                    "--no-undefined", "-Xlinker", "-z", "-Xlinker", "relro", "-Xlinker", "-z",
                    "-Xlinker",
                    "now",
                ], .when(platforms: [.linux]))
        ]),
    .target(
        name: "NucleusAndroidHostLifecycle", path: "core/swift/Sources/NucleusAndroidHostLifecycle"),
    .target(
        name: "NucleusLayers", dependencies: ["NucleusTypes", "NucleusFoundation"],
        path: "core/swift/Sources/NucleusLayers"),
    .systemLibrary(
        name: "NucleusRenderSystemC", path: "core/swiftpm/cmodules/NucleusRenderSystemC",
        pkgConfig: linuxPkgConfig("nucleus-render-system")),
    .target(
        name: "NucleusTextBackendNative", path: "core/render-cxx/skia",
        cxxSettings: [
            .unsafeFlags(
                [
                    "-std=c++20", "-DNDEBUG", "-DSK_GRAPHITE", "-DSK_VULKAN",
                    "-DSK_GAMMA_APPLY_TO_A8",
                    "-DSK_ALLOW_STATIC_GLOBAL_INITIALIZERS=1",
                ], .when(platforms: [.linux, .android]))
        ]),
    .target(
        name: "NucleusTextBackend",
        dependencies: [
            "NucleusUI", "NucleusTextBackendNative",
            "NucleusTextRenderingBridge",
            "Tracy",
        ], path: "core/swift/Sources/NucleusTextBackend"),
    .target(
        name: "NucleusUI",
        dependencies: [
            "NucleusTypes", "NucleusLayers", "NucleusSecureMemoryC", "NucleusFoundation", "Tracy",
        ],
        path: "core/swift/Sources/NucleusUI"),
    .target(
        name: "NucleusSecureMemoryC", path: "core/swift/Sources/NucleusSecureMemoryC"),
    .target(
        name: "NucleusUIEmbedder",
        dependencies: ["NucleusTypes", "NucleusUI", "NucleusLayers", "NucleusFoundation"],
        path: "core/swift/Sources/NucleusUIEmbedder"),
    .target(
        name: "NucleusApp", dependencies: ["NucleusUI", "NucleusLayers", "NucleusFoundation"],
        path: "core/swift/Sources/NucleusApp"),
    .target(
        name: "NucleusRenderModel", dependencies: ["NucleusTypes", "NucleusFoundation"],
        path: "core/swift/Sources/NucleusRenderModel"),
    .target(
        name: "NucleusAppHostBundle",
        dependencies: [
            "NucleusTypes", "NucleusLayers", "NucleusRenderModel", "NucleusFoundation",
        ],
        path: "core/swift/Sources/NucleusAppHostBundle",
        swiftSettings: [
            .enableUpcomingFeature("InternalImportsByDefault")
        ]),
    .target(
        name: "NucleusSkiaGraphiteBridge",
        dependencies: [
            .target(name: "NucleusRenderSystemC", condition: .when(platforms: [.linux]))
        ],
        path: "core/swift/Sources/NucleusSkiaGraphite/cxx",
        cxxSettings: [
            .unsafeFlags(
                [
                    "-std=c++20", "-DNDEBUG", "-DSK_GRAPHITE", "-DSK_VULKAN",
                    "-DSK_GAMMA_APPLY_TO_A8",
                    "-DSK_ALLOW_STATIC_GLOBAL_INITIALIZERS=1",
                ], .when(platforms: [.linux, .android]))
        ],
        linkerSettings: [
            .unsafeFlags(
                [
                    "-Xlinker", "--start-group", "-lskia", "-lskshaper", "-lskparagraph",
                    "-lskunicode_core",
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
        cxxSettings: [
            .unsafeFlags(
                [
                    "-std=c++20", "-DNDEBUG", "-DSK_GRAPHITE", "-DSK_VULKAN",
                    "-DSK_GAMMA_APPLY_TO_A8",
                    "-DSK_ALLOW_STATIC_GLOBAL_INITIALIZERS=1",
                ], .when(platforms: [.linux, .android]))
        ]),
    .testTarget(
        name: "NucleusSkiaGraphiteTests", dependencies: ["NucleusSkiaGraphiteBridge"],
        path: "core/swift/Tests/NucleusSkiaGraphiteTests",
        linkerSettings: [
            .unsafeFlags([
                "-Xlinker", "--start-group", "-lskia",
                "-lskshaper", "-lskparagraph", "-lskunicode_core", "-lskunicode_icu", "-lsvg",
                "-lskcms",
                "-lskresources", "-lfreetype2", "-lharfbuzz", "-licu", "-lpng", "-ljpeg",
                "-ljpeg12",
                "-ljpeg16", "-lwebp", "-lwebp_sse41", "-lexpat", "-lzlib", "-lwuffs", "-ldng_sdk",
                "-lpiex",
                "-Xlinker", "--end-group", "-ldl",
                "-lpthread", "-lm",
            ])
        ]),
    .target(
        name: "NucleusBlockingSynchronizationC",
        path: "core/swift/Sources/NucleusBlockingSynchronizationC"),
    .target(
        name: "NucleusRenderHost",
        dependencies: [
            "NucleusTypes", "NucleusLayers", "NucleusRenderModel", "NucleusFoundation",
        ],
        path: "core/swift/Sources/NucleusRenderHost"),
    .testTarget(
        name: "NucleusRenderHostTests",
        dependencies: [
            "NucleusTypes", "NucleusRenderHost", "NucleusLayers", "NucleusRenderModel",
            "NucleusFoundation",
        ], path: "core/swift/Tests/NucleusRenderHostTests"),
    .testTarget(
        name: "NucleusRuntimeGraphTests",
        dependencies: [
            "NucleusTypes", "NucleusAppHostBundle", "NucleusRenderHost", "NucleusRenderModel",
            "NucleusLayers", "NucleusUI", "NucleusFoundation",
        ], path: "core/swift/Tests/NucleusRuntimeGraphTests"),
    .testTarget(
        name: "NucleusAndroidHostLifecycleTests", dependencies: ["NucleusAndroidHostLifecycle"],
        path: "core/swift/Tests/NucleusAndroidHostLifecycleTests"),
    .target(
        name: "NucleusRenderer",
        dependencies: [
            "NucleusAppHostProtocols", "NucleusRenderModel", "NucleusTypes",
            "NucleusBlockingSynchronizationC",
            "NucleusFoundation", "VulkanC", "Vulkan", "NucleusSkiaGraphiteBridge", "Tracy",
        ], path: "core/swift/Sources/NucleusRenderer",
        swiftSettings: [
            .enableUpcomingFeature("InternalImportsByDefault")
        ]),
    .testTarget(
        name: "NucleusRendererTests",
        dependencies: [
            "NucleusAppHostProtocols", "NucleusTypes", "NucleusRenderer", "NucleusFoundation",
        ],
        path: "core/swift/Tests/NucleusRendererTests",
        linkerSettings: [
            .unsafeFlags([
                "-Xlinker", "--start-group", "-lskia",
                "-lskshaper", "-lskparagraph", "-lskunicode_core", "-lskunicode_icu", "-lsvg",
                "-lskcms",
                "-lskresources", "-lfreetype2", "-lharfbuzz", "-licu", "-lpng", "-ljpeg",
                "-ljpeg12",
                "-ljpeg16", "-lwebp", "-lwebp_sse41", "-lexpat", "-lzlib", "-lwuffs", "-ldng_sdk",
                "-lpiex",
                "-Xlinker", "--end-group", "-ldl",
                "-lpthread", "-lm",
            ])
        ]),
    .testTarget(
        name: "NucleusDiagnosticsTests", dependencies: ["NucleusFoundation"],
        path: "core/swift/Tests/NucleusDiagnosticsTests"),
    .testTarget(
        name: "NucleusRenderModelTests",
        dependencies: ["NucleusTypes", "NucleusRenderModel", "NucleusFoundation"],
        path: "core/swift/Tests/NucleusRenderModelTests"),
    .target(
        name: "NucleusRetainedSceneTestSupport", dependencies: ["NucleusUI"],
        path: "core/swift/Tests/Support/RetainedScene"),
    .target(
        name: "NucleusHostProjectionTestSupport", path: "core/swift/Tests/Support/HostProjection"),
    .target(
        name: "NucleusRendererTestSupport", path: "core/swift/Tests/Support/Renderer"),
    .target(
        name: "NucleusPresentationBackendContractTestSupport",
        path: "core/swift/Tests/Support/PresentationBackendContract"),
    .target(
        name: "NucleusResourceTestSupport", dependencies: ["NucleusUI"],
        path: "core/swift/Tests/Support/Resources"),
    .target(
        name: "NucleusTextRenderingTestSupport",
        dependencies: ["NucleusSkiaGraphiteBridge", "NucleusTextRenderingBridge"],
        path: "core/swift/Tests/Support/TextRendering"),
    .target(
        name: "NucleusUITestSupport",
        dependencies: ["NucleusResourceTestSupport", "NucleusTextBackend", "NucleusUI"],
        path: "core/swift/Tests/Support/UIContext"),
    .testTarget(
        name: "NucleusUmbrellaTests", dependencies: ["Nucleus"],
        path: "core/swift/Tests/NucleusUmbrellaTests"),
    .testTarget(
        name: "NucleusUIEmbedderTests",
        dependencies: [
            "NucleusTypes", "NucleusUIEmbedder", "NucleusUI", "NucleusLayers",
            "NucleusFoundation",
        ],
        path: "core/swift/Tests/NucleusUIEmbedderTests"),
    .testTarget(
        name: "NucleusAppTests", dependencies: ["NucleusApp", "NucleusUI"],
        path: "core/swift/Tests/NucleusAppTests"),
    .testTarget(
        name: "NucleusUITests",
        dependencies: [
            "NucleusTypes", "NucleusUI", "NucleusUIEmbedder", "NucleusLayers",
            "NucleusTextBackend",
            "NucleusSkiaGraphiteBridge", "NucleusRenderHost", "NucleusRenderModel",
            "NucleusRetainedSceneTestSupport", "NucleusHostProjectionTestSupport",
            "NucleusRendererTestSupport", "NucleusResourceTestSupport",
            "NucleusTextRenderingTestSupport", "NucleusUITestSupport",
            "NucleusFoundation",
        ], path: "core/swift/Tests/NucleusUITests",
        linkerSettings: [
            .unsafeFlags([
                "-Xlinker", "--start-group", "-lskia",
                "-lskshaper", "-lskparagraph", "-lskunicode_core", "-lskunicode_icu", "-lsvg",
                "-lskcms",
                "-lskresources", "-lfreetype2", "-lharfbuzz", "-licu", "-lpng", "-ljpeg",
                "-ljpeg12",
                "-ljpeg16", "-lwebp", "-lwebp_sse41", "-lexpat", "-lzlib", "-lwuffs", "-ldng_sdk",
                "-lpiex",
                "-Xlinker", "--end-group", "-ldl",
                "-lpthread", "-lm",
            ])
        ]),
    .executableTarget(
        name: "NucleusHeadlessBenchmarks",
        dependencies: [
            "NucleusBenchmarkSupport", "NucleusLayers", "NucleusUI", "NucleusRenderModel",
            "NucleusFoundation", "NucleusResourceTestSupport",
        ], path: "core/swift/Benchmarks/NucleusHeadlessBenchmarks"),
    .target(
        name: "NucleusBenchmarkSupport", dependencies: ["NucleusBenchmarkMetricsC"],
        path: "core/swift/Benchmarks/NucleusBenchmarkSupport"),
    .target(
        name: "NucleusBenchmarkMetricsC", path: "core/swift/Benchmarks/NucleusBenchmarkMetricsC"),
    .testTarget(
        name: "NucleusBenchmarkSupportTests", dependencies: ["NucleusBenchmarkSupport"],
        path: "core/swift/Tests/NucleusBenchmarkSupportTests"),
    .executableTarget(
        name: "NucleusCoreThreadSanitizerHarness",
        dependencies: [
            "NucleusAppHostProtocols", "NucleusRenderModel", "NucleusRenderer",
            "NucleusFoundation",
        ],
        path: "core/swift/SanitizerHarnesses/NucleusCoreThreadSanitizerHarness",
        linkerSettings: [
            .unsafeFlags([
                "-Xlinker", "--start-group", "-lskia",
                "-lskshaper", "-lskparagraph", "-lskunicode_core", "-lskunicode_icu", "-lsvg",
                "-lskcms",
                "-lskresources", "-lfreetype2", "-lharfbuzz", "-licu", "-lpng", "-ljpeg",
                "-ljpeg12",
                "-ljpeg16", "-lwebp", "-lwebp_sse41", "-lexpat", "-lzlib", "-lwuffs", "-ldng_sdk",
                "-lpiex",
                "-Xlinker", "--end-group", "-ldl",
                "-lpthread", "-lm",
            ])
        ]),
    .target(
        name: "NucleusDesktop",
        dependencies: [
            "Nucleus", "NucleusAppHostProtocols", "NucleusWindowClientContracts",
            "NucleusWindowClientHost",
        ], path: "desktop/Sources/NucleusDesktop"),
    .testTarget(
        name: "NucleusDesktopTests", dependencies: ["NucleusDesktop"],
        path: "desktop/Tests/NucleusDesktopTests"),
    .target(
        name: "NucleusTypes", path: "foundation/Sources/NucleusTypes"),
    .testTarget(
        name: "NucleusTypesTests", dependencies: ["NucleusAppHostProtocols", "NucleusTypes"],
        path: "foundation/Tests/NucleusTypesTests"),
    .target(
        name: "NucleusDiagnostics", path: "foundation/Sources/NucleusDiagnostics"),
    .target(
        name: "NucleusAppHostProtocols", dependencies: ["NucleusTypes"],
        path: "foundation/Sources/NucleusAppHostProtocols"),
    .target(
        name: "NucleusFoundation",
        dependencies: ["NucleusTypes", "NucleusDiagnostics", "NucleusAppHostProtocols"],
        path: "foundation/Sources/NucleusFoundation"),
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
            "NucleusCompositorWindowScene", "NucleusUITestSupport",
        ],
        path:
            "integration-tests/window-client-conformance/Tests/NucleusWindowClientPasteboardIntegrationTests",
        linkerSettings: [
            .unsafeFlags(["-lwayland-client", "-lm"])
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
            "NucleusCompositorWindowScene", "NucleusUITestSupport", "WaylandClient",
            "WaylandClientDispatch", "WaylandProtocolTypes",
        ],
        path:
            "integration-tests/window-client-conformance/Tests/NucleusWindowClientInputIntegrationTests",
        linkerSettings: [
            .unsafeFlags(["-lwayland-client", "-lm"])
        ]),
    .executableTarget(
        name: "NucleusControlCLI",
        dependencies: [
            "NucleusControlClient", "NucleusControlProtocol", "NucleusConfig",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ], path: "ipc/Sources/NucleusControlCLI"),
    .target(
        name: "NucleusControlClient",
        dependencies: ["NucleusIPCTransport", "NucleusIPCTransportC", "NucleusControlProtocol"],
        path: "ipc/control-client/Sources/NucleusControlClient"),
    .testTarget(
        name: "NucleusControlClientTests", dependencies: ["NucleusControlClient"],
        path: "ipc/control-client/Tests/NucleusControlClientTests"),
    .target(
        name: "NucleusControlProtocol", dependencies: ["NucleusFoundation", "NucleusConfig"],
        path: "ipc/control-protocol/Sources/NucleusControlProtocol"),
    .testTarget(
        name: "NucleusControlProtocolTests", dependencies: ["NucleusControlProtocol"],
        path: "ipc/control-protocol/Tests/NucleusControlProtocolTests"),
    .target(
        name: "NucleusControlService",
        dependencies: [
            "NucleusIPCTransport", "NucleusIPCTransportC", "NucleusControlProtocol",
            "NucleusLinuxPrimitives", "NucleusLinuxPrimitivesC", "NucleusLinuxReactor",
            "NucleusLinuxReactorC", "NucleusLinuxDBus", "NucleusLinuxSessionC",
            "NucleusThemeAssetIO",
            "NucleusSessionProtocol",
        ], path: "ipc/control-service-core/Sources/NucleusControlService"),
    .testTarget(
        name: "NucleusControlServiceTests", dependencies: ["NucleusControlService"],
        path: "ipc/control-service-core/Tests/NucleusControlServiceTests"),
    .executableTarget(
        name: "NucleusControlServiceExecutable", dependencies: ["NucleusControlService"],
        path: "ipc/control-service/Sources/NucleusControlServiceExecutable"),
    .target(name: "NucleusIPCTransportC", path: "ipc/transport/Sources/NucleusIPCTransportC"),
    .target(
        name: "NucleusIPCTransport", dependencies: ["NucleusIPCTransportC"],
        path: "ipc/transport/Sources/NucleusIPCTransport"),
    .testTarget(
        name: "NucleusIPCTransportTests", dependencies: ["NucleusIPCTransport"],
        path: "ipc/transport/Tests/NucleusIPCTransportTests"),
    .target(
        name: "NucleusLinuxPrimitives", dependencies: ["NucleusLinuxPrimitivesC"],
        path: "platform-linux/Sources/NucleusLinuxPrimitives",
        swiftSettings: [
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"])
        ]),
    .target(
        name: "NucleusLinuxPrimitivesC", path: "platform-linux/Sources/NucleusLinuxPrimitivesC"),
    .target(
        name: "NucleusLinuxReactor",
        dependencies: [
            "NucleusLinuxPrimitives", "NucleusLinuxReactorC",
            .product(name: "SystemPackage", package: "swift-system"),
        ], path: "platform-linux/Sources/NucleusLinuxReactor",
        swiftSettings: [
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"])
        ]),
    .target(
        name: "NucleusLinuxReactorC", path: "platform-linux/Sources/NucleusLinuxReactorC"),
    .systemLibrary(
        name: "NucleusLinuxDBusC", path: "platform-linux/Sources/NucleusLinuxDBusC",
        pkgConfig: linuxPkgConfig("libsystemd")),
    .target(
        name: "NucleusLinuxDBus", dependencies: ["NucleusLinuxDBusC", "NucleusLinuxReactor"],
        path: "platform-linux/Sources/NucleusLinuxDBus"),
    .target(
        name: "NucleusLinuxSessionC", path: "platform-linux/Sources/NucleusLinuxSessionC"),
    .target(
        name: "NucleusThemeAssetIO", path: "platform-linux/Sources/NucleusThemeAssetIO"),
    .executableTarget(
        name: "NucleusLinuxThreadSanitizerHarness",
        dependencies: ["NucleusLinuxReactor", "NucleusLinuxReactorC"],
        path: "platform-linux/SanitizerHarnesses/NucleusLinuxThreadSanitizerHarness",
        swiftSettings: [
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"])
        ]),
    .testTarget(
        name: "NucleusLinuxPrimitivesTests",
        dependencies: ["NucleusLinuxPrimitives", "NucleusLinuxPrimitivesC"],
        path: "platform-linux/Tests/NucleusLinuxPrimitivesTests",
        swiftSettings: [
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"])
        ]),
    .testTarget(
        name: "NucleusLinuxReactorTests", dependencies: ["NucleusLinuxReactor"],
        path: "platform-linux/Tests/NucleusLinuxReactorTests",
        swiftSettings: [
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"])
        ]),
    .testTarget(
        name: "NucleusLinuxDBusTests", dependencies: ["NucleusLinuxDBus"],
        path: "platform-linux/Tests/NucleusLinuxDBusTests"),
    .testTarget(
        name: "NucleusThemeAssetIOTests", dependencies: ["NucleusThemeAssetIO"],
        path: "platform-linux/Tests/NucleusThemeAssetIOTests"),
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
        ], path: "platform-linux/desktop/Sources/NucleusLinuxAccessibility"),
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
        ], path: "platform-linux/desktop/Sources/NucleusLinuxEnvironment"),
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
        swiftSettings: [
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"])
        ]),
    .testTarget(
        name: "NucleusLinuxAccessibilityTests",
        dependencies: [
            "NucleusLinuxAccessibility", "Nucleus", "NucleusApp", "NucleusAppHostBundle",
            "NucleusLayers",
            "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend", "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
            "NucleusUITestSupport",
        ], path: "platform-linux/desktop/Tests/NucleusLinuxAccessibilityTests",
        linkerSettings: [.unsafeFlags(["-Xlinker", "--no-as-needed"])]),
    .testTarget(
        name: "NucleusLinuxEnvironmentTests",
        dependencies: [
            "NucleusLinuxEnvironment", "Nucleus", "NucleusApp", "NucleusAppHostBundle",
            "NucleusLayers",
            "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend", "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
        ], path: "platform-linux/desktop/Tests/NucleusLinuxEnvironmentTests",
        linkerSettings: [.unsafeFlags(["-Xlinker", "--no-as-needed"])]),
    .executableTarget(
        name: "NucleusSessionSupervisor",
        dependencies: [
            "NucleusFoundation", "NucleusLinuxPrimitives", "NucleusLinuxPrimitivesC",
            "NucleusLinuxReactor", "NucleusLinuxReactorC", "NucleusLinuxDBus",
            "NucleusLinuxSessionC",
            "NucleusThemeAssetIO", "NucleusSessionProtocol", "NucleusIPCTransport",
            "NucleusIPCTransportC",
        ], path: "platform-linux/session/Sources/NucleusSessionSupervisor"),
    .executableTarget(
        name: "NucleusSessionFixture",
        dependencies: [
            "NucleusControlClient", "NucleusControlProtocol", "NucleusSessionProtocol",
            "NucleusIPCTransport", "NucleusIPCTransportC",
        ], path: "platform-linux/session/Tests/Fixtures/NucleusSessionFixture"),
    .testTarget(
        name: "NucleusLinuxSessionTests",
        dependencies: [
            "NucleusSessionSupervisor", "NucleusSessionFixture", "NucleusConfigServiceExecutable",
            "NucleusControlServiceExecutable", "NucleusControlClient", "NucleusControlProtocol",
            "NucleusIPCTransport", "NucleusIPCTransportC", "NucleusControlCLI",
            "NucleusSessionProtocol",
        ], path: "platform-linux/session/Tests/NucleusLinuxSessionTests"),
    .systemLibrary(
        name: "NucleusReactRuntimeCxxBridge",
        path: "react-native/swiftpm/cmodules/NucleusReactRuntimeCxxBridge"),
    .target(
        name: "NucleusReactNativeCxxBridge",
        path: "react-native/swift/Sources/NucleusReactNativeCxxBridge",
        cxxSettings: reactNativeBridgeCxxSettings),
    .testTarget(
        name: "NucleusReactNativeCxxTests", dependencies: ["NucleusReactNativeCxxBridge"],
        path: "react-native/swift/Tests/NucleusReactNativeCxxTests",
        linkerSettings: [
            .unsafeFlags([
                "-Xlinker", "--start-group", "-lhermes_lean_combined", "-lfolly_runtime",
                "-lglog", "-lfmt", "-ldouble-conversion", "-Xlinker", "--end-group", "-licu",
                "-lpthread", "-ldl", "-lm",
            ])
        ]),
    .testTarget(
        name: "NucleusReactRuntimeFabricTests",
        dependencies: [
            "NucleusAppHostProtocols",
            "NucleusReactRuntime",
            "NucleusReactRuntimeCxxBridge",
            "NucleusReactRuntimeHostCxx", "NucleusReactRuntimeCxx",
            "Nucleus",
            "NucleusApp", "NucleusAppHostBundle", "NucleusLayers", "NucleusRenderHost",
            "NucleusRenderModel", "NucleusRenderer", "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend",
            "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
        ], path: "react-native/swift/Tests/NucleusReactRuntimeFabricTests",
        swiftSettings: reactNativeSwiftSettings,
        linkerSettings: reactNativeRuntimeLinkerSettings),
    .executableTarget(
        name: "NucleusReactThreadSanitizerHarness",
        dependencies: [
            "NucleusReactRuntimeHostCxx", "NucleusReactRuntimeCxx",
            "Nucleus",
            "NucleusApp", "NucleusAppHostBundle", "NucleusLayers", "NucleusRenderHost",
            "NucleusRenderModel", "NucleusRenderer", "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend",
            "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
        ], path: "react-native/swift/SanitizerHarnesses/NucleusReactThreadSanitizerHarness",
        linkerSettings: reactNativeRuntimeLinkerSettings),
    .executableTarget(
        name: "NucleusReactBenchmarks",
        dependencies: [
            "NucleusReactRuntimeHostCxx", "NucleusReactRuntimeCxx",
            "NucleusBenchmarkSupport", "Nucleus", "NucleusApp", "NucleusAppHostBundle",
            "NucleusLayers",
            "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend", "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
        ], path: "react-native/swift/Benchmarks/NucleusReactBenchmarks",
        swiftSettings: reactNativeSwiftSettings,
        linkerSettings: reactNativeRuntimeLinkerSettings),
    .target(
        name: "NucleusReactRuntimeCxx",
        dependencies: [
            .product(name: "AsyncHTTPClient", package: "async-http-client"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOWebSocket", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            "Nucleus", "NucleusApp", "NucleusAppHostBundle", "NucleusLayers", "NucleusRenderHost",
            "NucleusRenderModel", "NucleusRenderer", "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend", "NucleusTextBackendNative",
            "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder", "Tracy",
            "NucleusFoundation",
            "NucleusReactRuntimeCxxBridge",
        ], path: "react-native/swift/Sources/NucleusReactRuntimeCxx",
        swiftSettings: reactNativeSwiftSettings),
    .target(
        name: "NucleusReactRuntimeHostCxx",
        path: "react-native/swift/Sources/NucleusReactRuntime/cxx",
        publicHeadersPath: "empty-public",
        cxxSettings: reactNativeHostCxxSettings),
    .target(
        name: "NucleusReactRuntime",
        dependencies: [
            "NucleusReactRuntimeCxx", "Nucleus", "NucleusApp", "NucleusAppHostBundle",
            "NucleusLayers",
            "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend", "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
            "NucleusFoundation", "NucleusAppHostProtocols", "Tracy",
        ], path: "react-native/swift/Sources/NucleusReactRuntime", exclude: ["cxx"],
        swiftSettings: reactNativeSwiftSettings),
    .target(
        name: "NucleusSessionProtocol",
        dependencies: ["NucleusConfig", "NucleusIPCTransport", "NucleusIPCTransportC"],
        path: "session/protocol/Sources/NucleusSessionProtocol"),
    .testTarget(
        name: "NucleusSessionProtocolTests",
        dependencies: ["NucleusSessionProtocol", "NucleusIPCTransport", "NucleusIPCTransportC"],
        path: "session/protocol/Tests/NucleusSessionProtocolTests"),
    .systemLibrary(
        name: "NucleusShellPamC", path: "shell/Sources/NucleusShellPamC",
        pkgConfig: linuxPkgConfig("pam")),
    .executableTarget(
        name: "NucleusShellPamHelper", dependencies: ["NucleusShellAuthWire", "NucleusShellPamC"],
        path: "shell/Sources/NucleusShellPamHelper"),
    .executableTarget(
        name: "NucleusShellThreadSanitizerHarness", dependencies: ["NucleusShellRuntime"],
        path: "shell/SanitizerHarnesses/NucleusShellThreadSanitizerHarness"),
    .executableTarget(
        name: "NucleusShell", dependencies: ["NucleusShellRuntime"],
        path: "shell/Sources/NucleusShell"),
    .target(
        name: "NucleusShellAuthWire", path: "shell/auth-wire/Sources/NucleusShellAuthWire"),
    .testTarget(
        name: "NucleusShellAuthWireTests", dependencies: ["NucleusShellAuthWire"],
        path: "shell/auth-wire/Tests/NucleusShellInputTests"),
    .target(
        name: "NucleusShellSignalC", path: "shell/shell-kit/Sources/NucleusShellSignalC"),
    .target(
        name: "NucleusShellProcessC", path: "shell/shell-kit/Sources/NucleusShellProcessC"),
    .target(
        name: "NucleusShellProduct",
        dependencies: [
            "Nucleus", "NucleusApp", "NucleusAppHostBundle", "NucleusLayers", "NucleusRenderHost",
            "NucleusRenderModel", "NucleusRenderer", "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend",
            "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
        ], path: "shell/shell-kit/Sources/NucleusShellProduct",
        swiftSettings: [
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"])
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
        ], path: "shell/shell-kit/Sources/NucleusShellServices"),
    .target(
        name: "NucleusShellAuth",
        dependencies: [
            "NucleusShellAuthWire", "NucleusShellProcessC", "NucleusShellProduct", "Nucleus",
            "NucleusApp", "NucleusAppHostBundle", "NucleusLayers", "NucleusRenderHost",
            "NucleusRenderModel", "NucleusRenderer", "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend",
            "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
        ], path: "shell/shell-kit/Sources/NucleusShellAuth"),
    .target(
        name: "NucleusShellRuntime",
        dependencies: [
            "NucleusAppHostProtocols", "NucleusFoundation", "NucleusWindowClientContracts",
            "NucleusWindowClientRuntime",
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
        ], path: "shell/shell-kit/Sources/NucleusShellRuntime"),
    .executableTarget(
        name: "NucleusShellPamAttemptFixture",
        path: "shell/shell-kit/Tests/Fixtures/NucleusShellPamAttemptFixture"),
    .testTarget(
        name: "NucleusWindowClientRuntimeTests",
        dependencies: [
            "NucleusWindowClientContracts", "NucleusWindowClientRuntime",
            "NucleusWindowClientWayland",
            "NucleusWindowClientPasteboard", "NucleusWindowClientRender",
            "NucleusWindowClientInput",
            "NucleusWindowClientHost", "NucleusShellSignalC",
        ], path: "shell/shell-kit/Tests/NucleusShellLoopTests"),
    .testTarget(
        name: "NucleusShellServicesTests",
        dependencies: [
            "NucleusShellServices", "NucleusConfig", "NucleusSessionProtocol", "NucleusUI",
        ],
        path: "shell/shell-kit/Tests/NucleusShellServicesTests"),
    .testTarget(
        name: "NucleusShellAuthTests",
        dependencies: [
            "NucleusShellAuth", "NucleusShellAuthWire", "NucleusShellProcessC",
            "NucleusShellPamAttemptFixture", "Nucleus", "NucleusApp", "NucleusAppHostBundle",
            "NucleusLayers", "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge", "NucleusTextBackend", "NucleusTextRenderingBridge",
            "NucleusUI",
            "NucleusUIEmbedder",
        ], path: "shell/shell-kit/Tests/NucleusShellAuthTests"),
    .testTarget(
        name: "NucleusShellProductTests",
        dependencies: [
            "NucleusShellProduct", "Nucleus", "NucleusApp", "NucleusAppHostBundle", "NucleusLayers",
            "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend", "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
            "NucleusFoundation", "NucleusUITestSupport",
        ], path: "shell/shell-kit/Tests/NucleusShellProductTests"),
    .target(
        name: "TracyBridge", path: "swift-tracy/Sources/TracyBridge",
        cxxSettings: [
            .headerSearchPath("../../third-party/tracy/public"), .unsafeFlags(["-std=c++20"]),
        ],
        linkerSettings: [
            .linkedLibrary("pthread", .when(platforms: [.linux])), .linkedLibrary("dl"),
        ]),
    .target(
        name: "Tracy", dependencies: ["TracyBridge"], path: "swift-tracy/Sources/Tracy"),
    .testTarget(
        name: "TracyTests", dependencies: ["Tracy"], path: "swift-tracy/Tests/TracyTests"),
    .systemLibrary(
        name: "VulkanC", path: "swift-vulkan/Sources/VulkanC",
        pkgConfig: linuxPkgConfig("vulkan")),
    .target(
        name: "Vulkan", dependencies: ["VulkanC"], path: "swift-vulkan/Sources/Vulkan"),
    .executableTarget(
        name: "VulkanGen", path: "swift-vulkan/Tools/VulkanGen"),
    .testTarget(
        name: "VulkanTests", dependencies: ["Vulkan"], path: "swift-vulkan/Tests/VulkanTests"),
    .target(
        name: "WaylandProtocolModel", path: "swift-wayland/Sources/WaylandProtocolModel"),
    .target(
        name: "SwiftWaylandGenerator",
        dependencies: [
            "WaylandProtocolModel", .product(name: "SwiftBasicFormat", package: "swift-syntax"),
            .product(name: "SwiftSyntax", package: "swift-syntax"),
            .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
        ], path: "swift-wayland/Sources/SwiftWaylandGenerator"),
    .executableTarget(
        name: "SwiftWaylandGen", dependencies: ["SwiftWaylandGenerator"],
        path: "swift-wayland/Sources/SwiftWaylandGen"),
    .systemLibrary(
        name: "WaylandServerC", path: "swift-wayland/Sources/WaylandServerC",
        pkgConfig: linuxPkgConfig("wayland-server")),
    .systemLibrary(
        name: "WaylandClientC", path: "swift-wayland/Sources/WaylandClientC",
        pkgConfig: linuxPkgConfig("wayland-client")),
    .target(
        name: "WaylandServer",
        dependencies: [
            "WaylandServerC", "WaylandProtocolTypes",
            "WaylandProtocolsC",
        ], path: "swift-wayland/Sources/WaylandServer",
        swiftSettings: [
            .enableUpcomingFeature("InternalImportsByDefault"),
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]),
        ]),
    .target(
        name: "WaylandServerDispatch",
        dependencies: [
            "WaylandServerC", "WaylandServer",
            "WaylandProtocolTypes",
            "WaylandProtocolsC",
        ], path: "swift-wayland/Sources/WaylandServerDispatch",
        swiftSettings: [
            .enableUpcomingFeature("InternalImportsByDefault"),
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]),
        ]),
    .target(
        name: "WaylandClientDispatch",
        dependencies: [
            "WaylandClientC", "WaylandProtocolTypes",
            "WaylandProtocolsC",
        ], path: "swift-wayland/Sources/WaylandClientDispatch",
        swiftSettings: [
            .enableUpcomingFeature("InternalImportsByDefault"),
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]),
        ]),
    .target(
        name: "WaylandClient", dependencies: ["WaylandClientC", "WaylandClientDispatch"],
        path: "swift-wayland/Sources/WaylandClient",
        swiftSettings: [
            .enableUpcomingFeature("InternalImportsByDefault"),
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]),
        ]),
    .testTarget(
        name: "WaylandClientCTests",
        dependencies: [
            "WaylandClientC", "WaylandProtocolTypes",
            "WaylandProtocolsC",
        ], path: "swift-wayland/Tests/WaylandClientCTests"),
    .testTarget(
        name: "WaylandProtocolModelTests", dependencies: ["WaylandProtocolModel"],
        path: "swift-wayland/Tests/WaylandProtocolModelTests"),
    .testTarget(
        name: "SwiftWaylandGeneratorTests",
        dependencies: ["SwiftWaylandGenerator", "WaylandProtocolModel"],
        path: "swift-wayland/Tests/SwiftWaylandGeneratorTests"),
    .testTarget(
        name: "WaylandServerTests",
        dependencies: [
            "WaylandServer", "WaylandProtocolTypes",
            "WaylandProtocolsC",
        ], path: "swift-wayland/Tests/WaylandServerTests",
        swiftSettings: [
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"])
        ]),
    .testTarget(
        name: "WaylandClientTests", dependencies: ["WaylandClient", "WaylandClientDispatch"],
        path: "swift-wayland/Tests/WaylandClientTests",
        swiftSettings: [
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"])
        ]),
    .testTarget(
        name: "WaylandLoopbackTests",
        dependencies: [
            "WaylandServer", "WaylandServerDispatch", "WaylandClient", "WaylandClientDispatch",
            "WaylandProtocolTypes", "WaylandProtocolsC",
        ], path: "swift-wayland/Tests/WaylandLoopbackTests",
        swiftSettings: [
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"])
        ]),
    .systemLibrary(
        name: "WaylandUtilC", path: "swift-wayland/protocol-runtime/Sources/WaylandUtilC"),
    .target(
        name: "WaylandProtocolsC", dependencies: ["WaylandUtilC"],
        path: "swift-wayland/protocol-runtime/Sources/WaylandProtocolsC"),
    .target(
        name: "WaylandProtocolTypes",
        path: "swift-wayland/protocol-runtime/Sources/WaylandProtocolTypes"),
    .target(
        name: "NucleusWindowClientContracts",
        path: "window-client/Sources/NucleusWindowClientContracts"),
    .target(
        name: "NucleusWindowClientRuntime",
        dependencies: [
            "NucleusLinuxPrimitives", "NucleusLinuxPrimitivesC", "NucleusLinuxReactor",
            "NucleusLinuxReactorC", "NucleusLinuxDBus", "NucleusLinuxSessionC",
            "NucleusThemeAssetIO",
        ], path: "window-client/Sources/NucleusWindowClientRuntime"),
    .systemLibrary(
        name: "NucleusWindowClientXkbC", path: "window-client/Sources/NucleusWindowClientXkbC",
        pkgConfig: linuxPkgConfig("xkbcommon")),
    .systemLibrary(
        name: "NucleusWindowClientVulkanWaylandC",
        path: "window-client/Sources/NucleusWindowClientVulkanWaylandC"),
    .target(
        name: "NucleusWindowClientWayland",
        dependencies: [
            "NucleusAppHostProtocols",
            "NucleusWindowClientContracts", "NucleusWindowClientXkbC", "NucleusWindowClientRuntime",
            "WaylandClientC", "WaylandClientDispatch", "WaylandClient",
            "WaylandProtocolTypes", "WaylandProtocolsC", "NucleusFoundation",
        ], path: "window-client/Sources/NucleusWindowClientWayland",
        swiftSettings: [
            .enableUpcomingFeature("InternalImportsByDefault"),
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]),
        ]),
    .target(
        name: "NucleusWindowClientPasteboard",
        dependencies: [
            "NucleusWindowClientWayland", "NucleusWindowClientRuntime", "WaylandClientC",
            "WaylandClientDispatch", "WaylandProtocolTypes",
            "WaylandProtocolsC", "Nucleus", "NucleusApp", "NucleusAppHostBundle", "NucleusLayers",
            "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend", "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
        ], path: "window-client/Sources/NucleusWindowClientPasteboard",
        swiftSettings: [
            .unsafeFlags(["-enable-experimental-feature", "Lifetimes"])
        ]),
    .target(
        name: "NucleusWindowClientRender",
        dependencies: [
            "NucleusAppHostProtocols", "NucleusFoundation", "NucleusWindowClientRuntime",
            "NucleusWindowClientWayland",
            "WaylandClientDispatch", "Nucleus", "NucleusApp", "NucleusAppHostBundle",
            "NucleusLayers",
            "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend", "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
            "Vulkan", "VulkanC", "Tracy", "NucleusWindowClientVulkanWaylandC",
        ], path: "window-client/Sources/NucleusWindowClientRender"),
    .target(
        name: "NucleusWindowClientInput",
        dependencies: [
            "NucleusWindowClientWayland", "WaylandClientC", "WaylandClientDispatch",
            "WaylandProtocolTypes", "WaylandProtocolsC",
            "NucleusFoundation", "Nucleus", "NucleusApp", "NucleusAppHostBundle", "NucleusLayers",
            "NucleusRenderHost", "NucleusRenderModel", "NucleusRenderer",
            "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend", "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
        ], path: "window-client/Sources/NucleusWindowClientInput"),
    .target(
        name: "NucleusWindowClientHost",
        dependencies: [
            "NucleusAppHostBundle", "NucleusAppHostProtocols", "NucleusDiagnostics",
            "NucleusLinuxReactor", "NucleusRenderModel", "NucleusTextBackend", "NucleusUI",
            "NucleusWindowClientContracts", "NucleusWindowClientRender",
            "NucleusWindowClientWayland",
        ], path: "window-client/Sources/NucleusWindowClientHost"),
    .testTarget(
        name: "NucleusWindowClientWaylandTests", dependencies: ["NucleusWindowClientWayland"],
        path: "window-client/Tests/NucleusWindowClientWaylandTests"),
    .testTarget(
        name: "NucleusWindowClientRenderTests",
        dependencies: [
            "NucleusWindowClientRender", "NucleusPresentationBackendContractTestSupport",
        ],
        path: "window-client/Tests/NucleusWindowClientRenderTests"),
    .target(name: "NucleusAndroidC", path: "core/platform-android/c", publicHeadersPath: "."),
    .target(
        name: "NucleusAndroidCore",
        dependencies: [
            "NucleusAppHostProtocols", "NucleusAndroidHostLifecycle", "NucleusAndroidC", "Vulkan",
            "VulkanC", "Nucleus",
            "NucleusApp", "NucleusAppHostBundle", "NucleusLayers", "NucleusRenderHost",
            "NucleusRenderModel", "NucleusRenderer", "NucleusSkiaGraphiteBridge",
            "NucleusTextBackend",
            "NucleusTextRenderingBridge", "NucleusUI", "NucleusUIEmbedder",
        ], path: "core/platform-android/swift-core"),
    .target(
        name: "NucleusAndroidJNI",
        dependencies: [
            "NucleusAndroidHostLifecycle", "NucleusAndroidCore", "NucleusAndroidC",
            .product(name: "SwiftJava", package: "swift-java"),
        ], path: "core/platform-android/swift-jni", exclude: ["swift-java.config"],
        plugins: [
            .plugin(name: "JExtractSwiftPlugin", package: "swift-java")
        ]),
    .target(
        name: "NucleusAndroidDeployment",
        dependencies: [
            .target(name: "NucleusAndroidJNI", condition: .when(platforms: [.android]))
        ],
        path: "core/platform-android/swift-deployment",
        linkerSettings: [
            .linkedLibrary("android", .when(platforms: [.android])),
            .unsafeFlags(
                [
                    "-Xlinker", "-soname", "-Xlinker", "libnucleus-android.so", "-Xlinker", "-z",
                    "-Xlinker",
                    "max-page-size=16384",
                ], .when(platforms: [.android])),
        ]),
]

let uniformSwiftSettings: [SwiftSetting] = [
    .interoperabilityMode(.Cxx),
    .strictMemorySafety(),
    .unsafeFlags(["-warnings-as-errors"]),
    .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
]

for target in targets {
    switch target.type {
    case .regular, .executable, .test, .macro:
        target.swiftSettings = (target.swiftSettings ?? []) + uniformSwiftSettings
        target.cSettings = (target.cSettings ?? []) + [.unsafeFlags(["-Werror"])]
        target.cxxSettings = (target.cxxSettings ?? []) + [.unsafeFlags(["-Werror"])]
    case .system, .binary, .plugin:
        break
    @unknown default:
        break
    }
}

let package = Package(
    name: "Nucleus",
    platforms: [.macOS("27")],
    products: products,
    dependencies: dependencies,
    targets: targets,
    swiftLanguageModes: [.v6],
    cxxLanguageStandard: .cxx20)
