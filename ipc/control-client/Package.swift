// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "NucleusControlClientPackage",
    products: [
        .library(
            name: "NucleusControlClient",
            type: .dynamic,
            targets: ["NucleusControlClient"]),
    ],
    dependencies: [
        .package(
            name: "NucleusIPCTransportPackage",
            path: "../transport"),
        .package(
            name: "NucleusControlProtocolPackage",
            path: "../control-protocol"),
    ],
    targets: [
        .target(
            name: "NucleusControlClient",
            dependencies: [
                .product(
                    name: "NucleusIPCTransport",
                    package: "NucleusIPCTransportPackage"),
                .product(
                    name: "NucleusControlProtocol",
                    package: "NucleusControlProtocolPackage"),
            ],
            swiftSettings: [
                .strictMemorySafety(),
                .unsafeFlags(["-warnings-as-errors"]),
                .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
            ]),
        .testTarget(
            name: "NucleusControlClientTests",
            dependencies: ["NucleusControlClient"],
            swiftSettings: [
                .strictMemorySafety(),
                .unsafeFlags(["-warnings-as-errors"]),
                .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
            ]),
    ]
)
