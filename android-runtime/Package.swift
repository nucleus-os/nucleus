// swift-tools-version:6.4

import Foundation
import PackageDescription

func pkgConfig(_ arguments: [String]) -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["pkg-config"] + arguments
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    do {
        try process.run()
    } catch {
        fatalError("could not launch pkg-config: \(error)")
    }
    process.waitUntilExit()
    let errorOutput = String(
        decoding: errors.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self)
    guard process.terminationStatus == 0 else {
        fatalError(
            "pkg-config \(arguments.joined(separator: " ")) failed: "
                + errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        .map(String.init)
}

let drmVulkanCFlags = pkgConfig(["--cflags", "libdrm", "gbm", "vulkan"])
let drmVulkanLinkFlags = pkgConfig(["--libs", "libdrm", "gbm", "vulkan"])
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let workspaceRoot = packageRoot.deletingLastPathComponent()
let mesaIOStreamInclude = workspaceRoot
    .appendingPathComponent("third-party/mesa/src/gfxstream/guest/iostream/include").path
let mesaVulkanEncoderInclude = workspaceRoot
    .appendingPathComponent("third-party/mesa/src/gfxstream/guest/vulkan_enc").path
let gfxstreamHostInclude = workspaceRoot
    .appendingPathComponent("third-party/gfxstream/host/include").path
let gfxstreamHostRoot = workspaceRoot
    .appendingPathComponent("third-party/gfxstream").path
let gfxstreamHostLibrary =
    ProcessInfo.processInfo.environment["NUCLEUS_GFXSTREAM_HOST_LIBRARY"]
    ?? packageRoot
        .appendingPathComponent(
            ".gfxstream-build/host/host/libgfxstream_backend.a"
        ).path
let gfxstreamGuestLibrary = packageRoot
    .appendingPathComponent(
        ".gfxstream-build/guest/src/gfxstream/guest/vulkan/libvulkan_gfxstream.so").path
let toolchainLibrary = ProcessInfo.processInfo.environment["SWIFT_TOOLCHAIN"]
    .map { URL(fileURLWithPath: $0).appendingPathComponent("lib").path }
let gfxstreamHostCxxIncludes = [
    "\(gfxstreamHostRoot)/host/common/include",
    "\(gfxstreamHostRoot)/host/features/include",
    "\(gfxstreamHostRoot)/host/include",
    "\(gfxstreamHostRoot)/host/iostream/include",
    "\(gfxstreamHostRoot)/host/library/include",
]

let package = Package(
    name: "android-runtime",
    platforms: [.macOS(.v15)],
    products: [
        .library(
            name: "AndroidRuntimeColliderRecipe",
            targets: ["AndroidRuntimeColliderRecipe"]),
        .library(
            name: "NucleusAndroidGraphicsContract",
            targets: ["NucleusAndroidGraphicsContract"]),
        .library(name: "NucleusAndroidIPC", targets: ["NucleusAndroidIPC"]),
        .library(
            name: "NucleusAndroidGfxstreamTransport",
            targets: ["NucleusAndroidGfxstreamTransport"]),
        .library(
            name: "NucleusAndroidGfxstreamAdapters",
            targets: ["NucleusAndroidGfxstreamAdaptersCxx"]),
        .library(
            name: "NucleusAndroidGfxstreamGuestTransport",
            targets: ["NucleusAndroidGfxstreamGuestTransportCxx"]),
        .library(
            name: "NucleusAndroidGfxstreamHost",
            targets: ["NucleusAndroidGfxstreamHostC"]),
        .library(
            name: "NucleusAndroidGraphicsPlatform",
            targets: ["NucleusAndroidGraphicsPlatform"]),
        .library(
            name: "NucleusAndroidGpuBrokerCore",
            targets: ["NucleusAndroidGpuBrokerCore"]),
        .library(
            name: "NucleusAndroidContainerContract",
            targets: ["NucleusAndroidContainerContract"]),
        .library(
            name: "NucleusAndroidDisplayHostCore",
            targets: ["NucleusAndroidDisplayHostCore"]),
        .library(
            name: "NucleusAndroidSurfaceProbeCore",
            targets: ["NucleusAndroidSurfaceProbeCore"]),
        .executable(name: "nucleus-android-gpu-broker", targets: ["NucleusAndroidGpuBroker"]),
        .executable(
            name: "nucleus-android-gfxstream-host-probe",
            targets: ["NucleusAndroidGfxstreamHostProbe"]),
        .executable(
            name: "nucleus-android-gfxstream-workload",
            targets: ["NucleusAndroidGfxstreamWorkload"]),
        .executable(
            name: "nucleus-android-gfxstream-broker",
            targets: ["NucleusAndroidGfxstreamBroker"]),
        .executable(
            name: "nucleus-android-display-host",
            targets: ["NucleusAndroidDisplayHost"]),
        .executable(
            name: "nucleus-android-shared-ring-stress",
            targets: ["NucleusAndroidSharedRingStress"]),
        .executable(name: "nucleus-android-surface-probe", targets: ["NucleusAndroidSurfaceProbe"]),
        .executable(
            name: "nucleus-android-presentation-qualifier",
            targets: ["NucleusAndroidPresentationQualifier"]),
        .executable(
            name: "NucleusAndroidThreadSanitizerHarness",
            targets: ["NucleusAndroidThreadSanitizerHarness"]),
    ],
    dependencies: [
        .package(path: "../collider/engine"),
        .package(name: "NucleusLinuxPlatform", path: "../platform-linux"),
        .package(path: "../swift-wayland"),
        .package(
            name: "SwiftWaylandProtocolRuntime",
            path: "../swift-wayland/protocol-runtime"),
        .package(
            name: "NucleusIPCTransportPackage",
            path: "../ipc/transport"),
    ],
    targets: [
        .target(
            name: "AndroidRuntimeColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),
        .target(
            name: "NucleusAndroidProcessLifecycleC",
            publicHeadersPath: "include"),
        .target(
            name: "NucleusAndroidComposerProtocolC",
            path: "aosp/device/nucleus/nucleus_x86_64/native/composer-protocol",
            publicHeadersPath: "include"),
        .target(
            name: "NucleusAndroidSharedRingC",
            path: "aosp/device/nucleus/nucleus_x86_64/native/shared-ring",
            publicHeadersPath: "include"),
        .target(
            name: "NucleusAndroidGfxstreamWorkerProtocolC",
            path: "Sources/NucleusAndroidGfxstreamWorkerProtocolC",
            publicHeadersPath: "include"),
        .target(
            name: "NucleusAndroidGfxstreamGuestTransportCxx",
            dependencies: [
                .product(
                    name: "NucleusIPCTransport",
                    package: "NucleusIPCTransportPackage"),
                "NucleusAndroidSharedRingC",
            ],
            path: "aosp/device/nucleus/nucleus_x86_64/native/gfxstream-guest",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags(["-I\(mesaIOStreamInclude)"]),
            ]),
        .target(
            name: "NucleusAndroidGfxstreamAdaptersCxx",
            dependencies: [
                "NucleusAndroidGfxstreamGuestTransportCxx",
                "NucleusAndroidSharedRingC",
            ],
            path: "Sources/NucleusAndroidGfxstreamAdaptersCxx",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags([
                    "-I\(mesaIOStreamInclude)",
                    "-I\(gfxstreamHostInclude)",
                ]),
            ],
            linkerSettings: [.linkedLibrary("dl")]),
        .target(
            name: "NucleusAndroidGfxstreamAdaptersTestSupport",
            dependencies: [
                "NucleusAndroidGfxstreamAdaptersCxx",
                "NucleusAndroidSharedRingC",
            ],
            path: "Sources/NucleusAndroidGfxstreamAdaptersTestSupport",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags([
                    "-I\(mesaIOStreamInclude)",
                    "-I\(gfxstreamHostInclude)",
                ]),
            ]),
        .target(
            name: "NucleusAndroidGfxstreamHostC",
            dependencies: [
                "NucleusAndroidGfxstreamAdaptersCxx",
                "NucleusAndroidSharedRingC",
            ],
            path: "Sources/NucleusAndroidGfxstreamHostC",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags(gfxstreamHostCxxIncludes.map { "-I\($0)" }),
            ],
            linkerSettings: [
                .unsafeFlags([
                    gfxstreamHostLibrary,
                ] + (toolchainLibrary.map {
                    ["-Xlinker", "-rpath", "-Xlinker", $0]
                } ?? [])),
                .linkedLibrary("dl"),
                .linkedLibrary("rt"),
            ]),
        .target(
            name: "NucleusAndroidDrmC",
            path: "Sources/NucleusAndroidDrmC",
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(drmVulkanCFlags)],
            linkerSettings: [.unsafeFlags(drmVulkanLinkFlags)]),
        .target(name: "NucleusAndroidGraphicsContract"),
        .target(
            name: "NucleusAndroidIPC",
            dependencies: [
                "NucleusAndroidGraphicsContract",
                .product(
                    name: "NucleusIPCTransport",
                    package: "NucleusIPCTransportPackage"),
            ]),
        .target(
            name: "NucleusAndroidGfxstreamTransport",
            dependencies: ["NucleusAndroidSharedRingC"]),
        .target(
            name: "NucleusAndroidGraphicsPlatform",
            dependencies: ["NucleusAndroidGraphicsContract", "NucleusAndroidDrmC"]),
        .target(
            name: "NucleusAndroidGpuBrokerCore",
            dependencies: [
                "NucleusAndroidGraphicsContract",
                "NucleusAndroidGraphicsPlatform",
                "NucleusAndroidIPC",
            ]),
        .target(name: "NucleusAndroidContainerContract"),
        .executableTarget(
            name: "NucleusAndroidGpuBroker",
            dependencies: [
                "NucleusAndroidGraphicsContract",
                "NucleusAndroidGraphicsPlatform",
                "NucleusAndroidGpuBrokerCore",
                "NucleusAndroidIPC",
                "NucleusAndroidProcessLifecycleC",
                .product(
                    name: "NucleusIPCTransport",
                    package: "NucleusIPCTransportPackage"),
                "NucleusAndroidGfxstreamWorkerProtocolC",
                .product(
                    name: "NucleusLinux",
                    package: "NucleusLinuxPlatform"),
            ]),
        .executableTarget(
            name: "NucleusAndroidGfxstreamHostProbe",
            dependencies: [
                "NucleusAndroidDrmC",
                "NucleusAndroidGfxstreamHostC",
            ]),
        .executableTarget(
            name: "NucleusAndroidGfxstreamWorkload",
            dependencies: [
                "NucleusAndroidDrmC",
                "NucleusAndroidGfxstreamAdaptersCxx",
                "NucleusAndroidGfxstreamHostC",
                "NucleusAndroidProcessLifecycleC",
                .product(
                    name: "NucleusIPCTransport",
                    package: "NucleusIPCTransportPackage"),
                "NucleusAndroidSharedRingC",
                "NucleusAndroidGfxstreamWorkerProtocolC",
            ],
            cxxSettings: [
                .define(
                    "NUCLEUS_ANDROID_GFXSTREAM_GUEST_ICD",
                    to: "\"\(gfxstreamGuestLibrary)\""),
                .unsafeFlags(["-I\(mesaVulkanEncoderInclude)"]),
            ],
            linkerSettings: [
                .linkedLibrary("dl"),
                .linkedLibrary("pthread"),
            ]),
        .executableTarget(
            name: "NucleusAndroidGfxstreamBroker",
            dependencies: [
                "NucleusAndroidDrmC",
                "NucleusAndroidGfxstreamGuestTransportCxx",
                "NucleusAndroidGfxstreamHostC",
                "NucleusAndroidProcessLifecycleC",
                .product(
                    name: "NucleusIPCTransport",
                    package: "NucleusIPCTransportPackage"),
                "NucleusAndroidSharedRingC",
            ],
            path: "Sources/NucleusAndroidGfxstreamBroker",
            linkerSettings: [
                .linkedLibrary("pthread"),
                .unsafeFlags(["-Wl,--export-dynamic"]),
            ]),
        .executableTarget(
            name: "NucleusAndroidDisplayHost",
            dependencies: ["NucleusAndroidDisplayHostCore"],
            swiftSettings: [.interoperabilityMode(.Cxx)]),
        .target(
            name: "NucleusAndroidDisplayHostCore",
            dependencies: [
                "NucleusAndroidComposerProtocolC",
                "NucleusAndroidDrmC",
                "NucleusAndroidGraphicsContract",
                "NucleusAndroidGraphicsPlatform",
                "NucleusAndroidProcessLifecycleC",
                .product(
                    name: "NucleusIPCTransport",
                    package: "NucleusIPCTransportPackage"),
                .product(
                    name: "NucleusLinux",
                    package: "NucleusLinuxPlatform"),
                .product(name: "WaylandClient", package: "swift-wayland"),
                .product(name: "WaylandClientC", package: "swift-wayland"),
                .product(name: "WaylandClientDispatch", package: "swift-wayland"),
                .product(
                    name: "SwiftWaylandProtocolRuntime",
                    package: "SwiftWaylandProtocolRuntime"),
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags([
                    "-enable-experimental-feature", "Lifetimes",
                ]),
            ]),
        .executableTarget(
            name: "NucleusAndroidSharedRingStress",
            dependencies: ["NucleusAndroidSharedRingC"],
            path: "Sources/NucleusAndroidSharedRingStress"),
        .executableTarget(
            name: "NucleusAndroidSurfaceProbe",
            dependencies: ["NucleusAndroidSurfaceProbeCore"],
            swiftSettings: [.interoperabilityMode(.Cxx)]),
        .target(
            name: "NucleusAndroidPresentationQualification",
            dependencies: ["NucleusAndroidSurfaceProbeCore"],
            swiftSettings: [.interoperabilityMode(.Cxx)]),
        .executableTarget(
            name: "NucleusAndroidPresentationQualifier",
            dependencies: ["NucleusAndroidPresentationQualification"],
            swiftSettings: [.interoperabilityMode(.Cxx)]),
        .target(
            name: "NucleusAndroidSurfaceProbeCore",
            dependencies: [
                "NucleusAndroidGraphicsContract",
                "NucleusAndroidIPC",
                "NucleusAndroidDrmC",
                .product(
                    name: "NucleusLinux",
                    package: "NucleusLinuxPlatform"),
                .product(name: "WaylandClient", package: "swift-wayland"),
                .product(name: "WaylandClientC", package: "swift-wayland"),
                .product(name: "WaylandClientDispatch", package: "swift-wayland"),
                .product(
                    name: "SwiftWaylandProtocolRuntime",
                    package: "SwiftWaylandProtocolRuntime"),
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags([
                    "-enable-experimental-feature", "Lifetimes",
                ]),
            ]),
        .testTarget(
            name: "NucleusAndroidGraphicsContractTests",
            dependencies: ["NucleusAndroidGraphicsContract"]),
        .testTarget(
            name: "NucleusAndroidContainerContractTests",
            dependencies: ["NucleusAndroidContainerContract"]),
        .testTarget(
            name: "NucleusAndroidIPCTests",
            dependencies: ["NucleusAndroidGraphicsContract", "NucleusAndroidIPC"]),
        .testTarget(
            name: "NucleusAndroidGfxstreamTransportTests",
            dependencies: ["NucleusAndroidGfxstreamTransport"]),
        .testTarget(
            name: "NucleusAndroidGfxstreamAdaptersTests",
            dependencies: ["NucleusAndroidGfxstreamAdaptersTestSupport"]),
        .testTarget(
            name: "NucleusAndroidGraphicsPlatformTests",
            dependencies: [
                "NucleusAndroidDrmC",
                "NucleusAndroidDrmCTestSupport",
                "NucleusAndroidGraphicsContract",
                "NucleusAndroidGraphicsPlatform",
            ]),
        .target(
            name: "NucleusAndroidDrmCTestSupport",
            dependencies: ["NucleusAndroidDrmC"],
            path: "Tests/Support/NucleusAndroidDrmCTestSupport",
            publicHeadersPath: "include"),
        .executableTarget(
            name: "NucleusAndroidThreadSanitizerHarness",
            dependencies: [
                "NucleusAndroidDrmC",
                "NucleusAndroidDrmCTestSupport",
                "NucleusAndroidGfxstreamTransport",
            ],
            path: "SanitizerHarnesses/NucleusAndroidThreadSanitizerHarness"),
        .testTarget(
            name: "NucleusAndroidGpuBrokerCoreTests",
            dependencies: [
                "NucleusAndroidGraphicsContract",
                "NucleusAndroidGraphicsPlatform",
                "NucleusAndroidGpuBrokerCore",
                "NucleusAndroidIPC",
            ]),
        .testTarget(
            name: "NucleusAndroidSurfaceProbeCoreTests",
            dependencies: [
                "NucleusAndroidGraphicsContract",
                "NucleusAndroidSurfaceProbeCore",
            ],
            swiftSettings: [.interoperabilityMode(.Cxx)]),
        .testTarget(
            name: "NucleusAndroidDisplayHostCoreTests",
            dependencies: [
                "NucleusAndroidDisplayHostCore",
                .product(
                    name: "NucleusIPCTransport",
                    package: "NucleusIPCTransportPackage"),
                .product(
                    name: "NucleusLinux",
                    package: "NucleusLinuxPlatform"),
            ],
            swiftSettings: [.interoperabilityMode(.Cxx)]),
    ],
    cxxLanguageStandard: .cxx20)

for target in package.targets {
    switch target.type {
    case .regular, .executable, .test:
        break
    default:
        continue
    }
    target.swiftSettings = (target.swiftSettings ?? []) + [
        .strictMemorySafety(),
        .unsafeFlags(["-warnings-as-errors"]),
        .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
    ]
    target.cSettings = (target.cSettings ?? []) + [.unsafeFlags(["-Werror"])]
}
