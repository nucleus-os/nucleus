// swift-tools-version:6.4
//
// Privileged configuration source I/O. The resolved model lives in model/ so
// ordinary runtime consumers cannot acquire parsing or filesystem authority.

import PackageDescription

let package = Package(
    name: "NucleusConfigIOPackage",
    products: [
        .library(name: "ConfigColliderRecipe", targets: ["ConfigColliderRecipe"]),
        .library(
            name: "NucleusConfigIO",
            type: .dynamic,
            targets: ["NucleusConfigIO", "NucleusConfigSyntax"]),
    ],
    dependencies: [
        .package(path: "../collider/engine"),
        .package(name: "NucleusConfigModel", path: "model"),
    ],
    targets: [
        .target(
            name: "ConfigColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),

        // Source preparation: offset-preserving comment stripping and the
        // structural pre-validation that gives hand-edit mistakes a real
        // line and column. No dependencies, including no Foundation.
        .target(
            name: "NucleusConfigSyntax",
            path: "Sources/NucleusConfigSyntax"),
        .testTarget(
            name: "NucleusConfigSyntaxTests",
            dependencies: ["NucleusConfigSyntax"],
            path: "Tests/NucleusConfigSyntaxTests"),

        .target(
            name: "NucleusConfigIO",
            dependencies: [
                "NucleusConfigSyntax",
                .product(
                    name: "NucleusConfig",
                    package: "NucleusConfigModel"),
            ]),
        .testTarget(
            name: "NucleusConfigTests",
            dependencies: [
                "NucleusConfigIO",
                "NucleusConfigSyntax",
                .product(
                    name: "NucleusConfig",
                    package: "NucleusConfigModel"),
            ],
            path: "Tests/NucleusConfigTests"),
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
