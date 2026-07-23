// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "NucleusBrowser",
    products: [
        .library(
            name: "ChromiumColliderRecipe",
            targets: ["ChromiumColliderRecipe"]),
    ],
    dependencies: [
        .package(path: "../collider/engine"),
    ],
    targets: [
        .target(
            name: "ChromiumColliderRecipe",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
            ]),
    ])

for target in package.targets {
    target.swiftSettings = (target.swiftSettings ?? []) + [
        .unsafeFlags(["-warnings-as-errors"]),
        .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
    ]
}
