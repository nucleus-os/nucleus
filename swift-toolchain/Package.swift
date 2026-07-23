// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "NucleusSwiftPlatform",
    platforms: [.macOS(.v15)],
    products: [
        .library(
            name: "SwiftPlatformColliderRecipe",
            targets: ["SwiftPlatformColliderRecipe"]),
    ],
    dependencies: [
        .package(path: "../collider"),
    ],
    targets: [
        .target(
            name: "SwiftPlatformColliderRecipe",
            dependencies: [
                .product(name: "ColliderCore", package: "collider"),
            ]),
        .testTarget(
            name: "SwiftPlatformColliderRecipeTests",
            dependencies: [
                "SwiftPlatformColliderRecipe",
                .product(name: "ColliderCore", package: "collider"),
            ]),
    ])

for target in package.targets {
    target.swiftSettings = (target.swiftSettings ?? []) + [
        .unsafeFlags(["-warnings-as-errors"]),
        .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
    ]
}
