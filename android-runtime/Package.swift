// swift-tools-version:6.4

import Foundation
import PackageDescription

func pkgConfig(_ arguments: [String]) -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["pkg-config"] + arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    do { try process.run() } catch { return [] }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return [] }
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
let gfxstreamHostLibrary = packageRoot
    .appendingPathComponent(".gfxstream-build/host/host/libgfxstream_backend.a").path
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
            name: "NucleusAndroidGfxstreamHost",
            targets: ["NucleusAndroidGfxstreamHostC"]),
        .library(
            name: "NucleusAndroidGraphicsPlatform",
            targets: ["NucleusAndroidGraphicsPlatform"]),
        .library(
            name: "NucleusAndroidGpuBrokerCore",
            targets: ["NucleusAndroidGpuBrokerCore"]),
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
        .executable(name: "nucleus-android-surface-probe", targets: ["NucleusAndroidSurfaceProbe"]),
        .executable(
            name: "nucleus-android-presentation-qualifier",
            targets: ["NucleusAndroidPresentationQualifier"]),
    ],
    dependencies: [
        .package(path: "../collider"),
        .package(name: "NucleusLinuxPlatform", path: "../platform-linux"),
        .package(path: "../swift-wayland"),
    ],
    targets: [
        .target(
            name: "AndroidRuntimeColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "collider")]),
        .target(
            name: "NucleusAndroidIPCC",
            path: "Sources/NucleusAndroidIPCC",
            publicHeadersPath: "include"),
        .target(
            name: "NucleusAndroidSharedRingC",
            path: "Sources/NucleusAndroidSharedRingC",
            publicHeadersPath: "include"),
        .target(
            name: "NucleusAndroidGfxstreamWorkerProtocolC",
            path: "Sources/NucleusAndroidGfxstreamWorkerProtocolC",
            publicHeadersPath: "include"),
        .target(
            name: "NucleusAndroidGfxstreamAdaptersCxx",
            dependencies: ["NucleusAndroidSharedRingC"],
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
            dependencies: ["NucleusAndroidGraphicsContract", "NucleusAndroidIPCC"]),
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
        .executableTarget(
            name: "NucleusAndroidGpuBroker",
            dependencies: [
                "NucleusAndroidGraphicsContract",
                "NucleusAndroidGraphicsPlatform",
                "NucleusAndroidGpuBrokerCore",
                "NucleusAndroidIPC",
                "NucleusAndroidIPCC",
                "NucleusAndroidGfxstreamWorkerProtocolC",
                .product(
                    name: "NucleusLinuxReactor",
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
                "NucleusAndroidIPCC",
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
                    name: "NucleusLinuxReactor",
                    package: "NucleusLinuxPlatform"),
                .product(name: "WaylandClient", package: "swift-wayland"),
                .product(name: "WaylandClientC", package: "swift-wayland"),
                .product(name: "WaylandClientDispatch", package: "swift-wayland"),
                .product(name: "WaylandProtocolsC", package: "swift-wayland"),
            ],
            swiftSettings: [.interoperabilityMode(.Cxx)]),
        .testTarget(
            name: "NucleusAndroidGraphicsContractTests",
            dependencies: ["NucleusAndroidGraphicsContract"]),
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
                "NucleusAndroidGraphicsContract",
                "NucleusAndroidGraphicsPlatform",
            ]),
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
        .unsafeFlags(["-warnings-as-errors"]),
        .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
    ]
    target.cSettings = (target.cSettings ?? []) + [.unsafeFlags(["-Werror"])]
}
