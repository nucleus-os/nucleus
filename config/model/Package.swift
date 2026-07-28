// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "NucleusConfigModel",
    products: [
        .library(
            name: "NucleusConfig",
            type: .dynamic,
            targets: ["NucleusConfig"]),
    ],
    targets: [
        .target(
            name: "NucleusConfig",
            swiftSettings: [
                .strictMemorySafety(),
                .unsafeFlags(["-warnings-as-errors"]),
                .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
            ]),
        .testTarget(
            name: "NucleusConfigModelTests",
            dependencies: ["NucleusConfig"],
            swiftSettings: [
                .strictMemorySafety(),
                .unsafeFlags(["-warnings-as-errors"]),
                .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
            ]),
    ]
)
