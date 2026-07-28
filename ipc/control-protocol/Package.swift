// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "NucleusControlProtocolPackage",
    products: [
        .library(
            name: "NucleusControlProtocol",
            type: .dynamic,
            targets: ["NucleusControlProtocol"]),
    ],
    dependencies: [
        .package(name: "NucleusFoundation", path: "../../foundation"),
        .package(name: "NucleusConfigModel", path: "../../config/model"),
    ],
    targets: [
        .target(
            name: "NucleusControlProtocol",
            dependencies: [
                .product(
                    name: "NucleusFoundation",
                    package: "NucleusFoundation"),
                .product(
                    name: "NucleusConfig",
                    package: "NucleusConfigModel"),
            ],
            swiftSettings: [
                .strictMemorySafety(),
                .unsafeFlags(["-warnings-as-errors"]),
                .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
            ]),
        .testTarget(
            name: "NucleusControlProtocolTests",
            dependencies: ["NucleusControlProtocol"],
            swiftSettings: [
                .strictMemorySafety(),
                .unsafeFlags(["-warnings-as-errors"]),
                .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
            ]),
    ]
)
