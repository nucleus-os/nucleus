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
    return String(
        decoding: output.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self)
        .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        .map(String.init)
}

let xkbClientCcFlags =
    pkgConfig(["--cflags", "xkbcommon"]).flatMap { ["-Xcc", $0] }
let package = Package(
    name: "NucleusWindowClientPackage",
    products: [
        .library(
            name: "NucleusWindowClient",
            type: .dynamic,
            targets: [
                "NucleusWindowClientContracts",
                "NucleusWindowClientRuntime",
                "NucleusWindowClientWayland",
                "NucleusWindowClientPasteboard",
                "NucleusWindowClientRender",
                "NucleusWindowClientInput",
                "NucleusWindowClientHost",
            ]),
    ],
    dependencies: [
        .package(name: "Nucleus", path: "../core"),
        .package(name: "NucleusFoundation", path: "../foundation"),
        .package(name: "NucleusLinuxPlatform", path: "../platform-linux"),
        .package(name: "swift-vulkan", path: "../swift-vulkan"),
        .package(name: "swift-wayland", path: "../swift-wayland"),
        .package(
            name: "SwiftWaylandProtocolRuntime",
            path: "../swift-wayland/protocol-runtime"),
        .package(name: "swift-tracy", path: "../swift-tracy"),
    ],
    targets: [
        .target(name: "NucleusWindowClientContracts"),
        .target(
            name: "NucleusWindowClientRuntime",
            dependencies: [
                .product(
                    name: "NucleusLinux",
                    package: "NucleusLinuxPlatform"),
            ]),
        .systemLibrary(
            name: "NucleusWindowClientXkbC",
            pkgConfig: "xkbcommon"),
        .target(
            name: "NucleusWindowClientWayland",
            dependencies: [
                "NucleusWindowClientContracts",
                "NucleusWindowClientXkbC",
                "NucleusWindowClientRuntime",
                .product(name: "WaylandClientC", package: "swift-wayland"),
                .product(
                    name: "WaylandClientDispatch",
                    package: "swift-wayland"),
                .product(name: "WaylandClient", package: "swift-wayland"),
                .product(
                    name: "SwiftWaylandProtocolRuntime",
                    package: "SwiftWaylandProtocolRuntime"),
                .product(
                    name: "NucleusFoundation",
                    package: "NucleusFoundation"),
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags([
                    "-enable-experimental-feature", "Lifetimes",
                ]),
                .unsafeFlags(xkbClientCcFlags),
            ]),
        .target(
            name: "NucleusWindowClientPasteboard",
            dependencies: [
                "NucleusWindowClientWayland",
                "NucleusWindowClientRuntime",
                .product(name: "WaylandClientC", package: "swift-wayland"),
                .product(
                    name: "WaylandClientDispatch",
                    package: "swift-wayland"),
                .product(
                    name: "SwiftWaylandProtocolRuntime",
                    package: "SwiftWaylandProtocolRuntime"),
                .product(name: "Nucleus", package: "Nucleus"),
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags([
                    "-enable-experimental-feature", "Lifetimes",
                ]),
            ]),
        .target(
            name: "NucleusWindowClientRender",
            dependencies: [
                .product(
                    name: "NucleusFoundation",
                    package: "NucleusFoundation"),
                "NucleusWindowClientRuntime",
                "NucleusWindowClientWayland",
                .product(
                    name: "WaylandClientDispatch",
                    package: "swift-wayland"),
                .product(name: "Nucleus", package: "Nucleus"),
                .product(name: "SwiftVulkan", package: "swift-vulkan"),
                .product(name: "VulkanC", package: "swift-vulkan"),
                .product(name: "SwiftTracy", package: "swift-tracy"),
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
            ]),
        .target(
            name: "NucleusWindowClientInput",
            dependencies: [
                "NucleusWindowClientWayland",
                .product(name: "WaylandClientC", package: "swift-wayland"),
                .product(
                    name: "WaylandClientDispatch",
                    package: "swift-wayland"),
                .product(
                    name: "SwiftWaylandProtocolRuntime",
                    package: "SwiftWaylandProtocolRuntime"),
                .product(
                    name: "NucleusFoundation",
                    package: "NucleusFoundation"),
                .product(name: "Nucleus", package: "Nucleus"),
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .strictMemorySafety(),
            ]),
        .target(
            name: "NucleusWindowClientHost",
            dependencies: [
                "NucleusWindowClientContracts",
                "NucleusWindowClientRuntime",
                "NucleusWindowClientWayland",
                "NucleusWindowClientPasteboard",
                "NucleusWindowClientRender",
                "NucleusWindowClientInput",
                .product(name: "Nucleus", package: "Nucleus"),
            ],
            swiftSettings: [.interoperabilityMode(.Cxx)]),
        .testTarget(
            name: "NucleusWindowClientWaylandTests",
            dependencies: ["NucleusWindowClientWayland"],
            swiftSettings: [.interoperabilityMode(.Cxx)]),
        .testTarget(
            name: "NucleusWindowClientRenderTests",
            dependencies: [
                "NucleusWindowClientRender",
                .product(
                    name:
                        "NucleusPresentationBackendContractTestSupport",
                    package: "Nucleus"),
            ],
            swiftSettings: [.interoperabilityMode(.Cxx)]),
    ])

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
        swiftSettings.append(
            .unsafeFlags(["-enable-upcoming-feature", feature]))
    }
    target.swiftSettings = swiftSettings
    target.cSettings =
        (target.cSettings ?? []) + [.unsafeFlags(["-Werror"])]
    target.cxxSettings =
        (target.cxxSettings ?? []) + [.unsafeFlags(["-Werror"])]
}
