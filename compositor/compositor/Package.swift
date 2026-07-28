// swift-tools-version:6.4
//
// The Nucleus compositor application package.
// This package is intentionally only the installed composition root and its
// Collider recipe. All server implementation and tests live in compositor-core.

import PackageDescription

let package = Package(
    name: "NucleusCompositorApp",
    products: [
        .library(name: "CompositorAppColliderRecipe", targets: ["CompositorAppColliderRecipe"]),
    ],
    dependencies: [
        .package(path: "../../collider/engine"),
        .package(
            name: "NucleusSessionProtocolPackage",
            path: "../../session/protocol"),
        .package(name: "NucleusFoundation", path: "../../foundation"),
        .package(path: "../compositor-core"),
    ],
    targets: [
        .target(
            name: "CompositorAppColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),
        .executableTarget(
            name: "NucleusCompositor",
            dependencies: [
                .product(
                    name: "NucleusRenderServer",
                    package: "compositor-core"),
                .product(
                    name: "NucleusFoundation",
                    package: "NucleusFoundation"),
                .product(
                    name: "NucleusSessionProtocol",
                    package: "NucleusSessionProtocolPackage"),
            ],
            path: "Sources/NucleusCompositor",
            swiftSettings: [.interoperabilityMode(.Cxx)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "--as-needed"])]
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
