// swift-tools-version:6.4
//
// The Nucleus control protocol and its command-line client.
//
// Separate from `config/` because the two answer different questions — what a
// session is configured to be, versus what it is being asked to do right now —
// but it depends on the configuration model, since a control request names the
// same operations a key binding names.
//
// Like `config/`, this package depends on no other first-party component. The
// compositor serves the protocol and the CLI speaks it; neither owns it.

import PackageDescription

let package = Package(
    name: "NucleusIPCPackage",
    products: [
        .library(name: "IPCColliderRecipe", targets: ["IPCColliderRecipe"]),
        .library(name: "NucleusIPC", targets: ["NucleusIPC"]),
        .executable(name: "nucleus", targets: ["NucleusControlCLI"]),
    ],
    dependencies: [
        .package(path: "../collider/engine"),
        .package(name: "NucleusConfigPackage", path: "../config"),
        .package(path: "../third-party/swift-argument-parser"),
    ],
    targets: [
        .target(
            name: "IPCColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),

        .target(
            name: "NucleusIPC",
            dependencies: [
                .product(name: "NucleusConfig", package: "NucleusConfigPackage"),
            ],
            path: "Sources/NucleusIPC"),
        .testTarget(
            name: "NucleusIPCTests",
            dependencies: ["NucleusIPC"],
            path: "Tests/NucleusIPCTests"),

        .executableTarget(
            name: "NucleusControlCLI",
            dependencies: [
                "NucleusIPC",
                .product(name: "NucleusConfig", package: "NucleusConfigPackage"),
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
