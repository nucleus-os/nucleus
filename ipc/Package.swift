// swift-tools-version:6.4
//
// Build tooling and the public control executable. Runtime protocol, transport,
// and client implementations live in role-specific nested packages.

import PackageDescription

let package = Package(
    name: "NucleusIPCPackage",
    products: [
        .library(name: "IPCColliderRecipe", targets: ["IPCColliderRecipe"]),
        .executable(name: "nucleus", targets: ["NucleusControlCLI"]),
    ],
    dependencies: [
        .package(path: "../collider/engine"),
        .package(name: "NucleusConfigModel", path: "../config/model"),
        .package(
            name: "NucleusControlProtocolPackage",
            path: "control-protocol"),
        .package(
            name: "NucleusControlClientPackage",
            path: "control-client"),
        .package(path: "../third-party/swift-argument-parser"),
    ],
    targets: [
        .target(
            name: "IPCColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),

        .executableTarget(
            name: "NucleusControlCLI",
            dependencies: [
                .product(
                    name: "NucleusControlClient",
                    package: "NucleusControlClientPackage"),
                .product(
                    name: "NucleusControlProtocol",
                    package: "NucleusControlProtocolPackage"),
                .product(
                    name: "NucleusConfig",
                    package: "NucleusConfigModel"),
                .product(
                    name: "ArgumentParser",
                    package: "swift-argument-parser"),
            ],
            path: "Sources/NucleusControlCLI"),
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
