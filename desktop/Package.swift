// swift-tools-version:6.4

import PackageDescription

let package = Package(
    name: "NucleusDesktopPackage",
    products: [
        .library(name: "NucleusDesktop", targets: ["NucleusDesktop"]),
    ],
    dependencies: [
        .package(name: "Nucleus", path: "../core"),
        .package(
            name: "NucleusWindowClientPackage",
            path: "../window-client"),
    ],
    targets: [
        .target(
            name: "NucleusDesktop",
            dependencies: [
                .product(name: "Nucleus", package: "Nucleus"),
                .product(
                    name: "NucleusWindowClient",
                    package: "NucleusWindowClientPackage"),
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .strictMemorySafety(),
                .unsafeFlags(["-warnings-as-errors"]),
                .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
            ]),
        .testTarget(
            name: "NucleusDesktopTests",
            dependencies: ["NucleusDesktop"],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .strictMemorySafety(),
                .unsafeFlags(["-warnings-as-errors"]),
                .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
            ]),
    ])
