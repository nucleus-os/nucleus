// swift-tools-version:6.4
//
// The Nucleus configuration model.
//
// This package depends on no other first-party component — not the compositor,
// not the shell, not the render core. That is the point: the compositor, the
// shell, and the control CLI all read the same configuration, so the model that
// defines it cannot belong to any one of them. It also keeps the package
// testable on its own, with no Wayland, DRM, or Vulkan link requirement.

import PackageDescription

let package = Package(
    name: "NucleusConfigPackage",
    products: [
        .library(name: "ConfigColliderRecipe", targets: ["ConfigColliderRecipe"]),
        .library(name: "NucleusConfigSyntax", targets: ["NucleusConfigSyntax"]),
        .library(name: "NucleusConfig", targets: ["NucleusConfig"]),
    ],
    dependencies: [
        .package(path: "../collider/engine"),
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

        // The configuration model: all-optional `*Part` decode targets, the
        // resolved values the runtime reads, and the layering between them.
        .target(
            name: "NucleusConfig",
            dependencies: ["NucleusConfigSyntax"],
            path: "Sources/NucleusConfig"),
        .testTarget(
            name: "NucleusConfigTests",
            dependencies: ["NucleusConfig", "NucleusConfigSyntax"],
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
