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

let serverPackages = [
    "xcb-ewmh", "xcb", "xcb-icccm", "xcb-composite", "xcb-xfixes",
    "xcb-res", "libinput", "libudev", "libseat", "xkbcommon",
]
let integrationLinkFlags =
    pkgConfig(["--libs", "wayland-client"] + serverPackages)
    + pkgConfig(["--libs-only-L"] + serverPackages)
        .compactMap { $0.hasPrefix("-L") ? String($0.dropFirst(2)) : nil }
        .flatMap { ["-Xlinker", "-rpath", "-Xlinker", $0] }

let integrationDependencies: [Target.Dependency] = [
    .product(
        name: "NucleusWindowClient",
        package: "NucleusWindowClientPackage"),
    .product(name: "Nucleus", package: "Nucleus"),
    .product(
        name: "NucleusCompositorWaylandRuntime",
        package: "compositor-core"),
    .product(
        name: "NucleusRenderServerTestSupport",
        package: "compositor-core"),
    .product(
        name: "NucleusCompositorWindowScene",
        package: "compositor-core"),
]

let package = Package(
    name: "NucleusWindowClientIntegrationTests",
    dependencies: [
        .package(
            name: "NucleusWindowClientPackage",
            path: "../../window-client"),
        .package(name: "Nucleus", path: "../../core"),
        .package(
            name: "compositor-core",
            path: "../../compositor/compositor-core"),
    ],
    targets: [
        .testTarget(
            name: "NucleusWindowClientPasteboardIntegrationTests",
            dependencies: integrationDependencies,
            swiftSettings: [.interoperabilityMode(.Cxx)],
            linkerSettings: [.unsafeFlags(integrationLinkFlags)]),
        .testTarget(
            name: "NucleusWindowClientInputIntegrationTests",
            dependencies: integrationDependencies,
            swiftSettings: [.interoperabilityMode(.Cxx)],
            linkerSettings: [.unsafeFlags(integrationLinkFlags)]),
    ])

for target in package.targets {
    target.swiftSettings = (target.swiftSettings ?? []) + [
        .strictMemorySafety(),
        .unsafeFlags(["-warnings-as-errors"]),
        .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
    ]
}
