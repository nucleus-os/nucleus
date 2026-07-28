// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "NucleusSessionProtocolPackage",
    products: [
        .library(
            name: "NucleusSessionProtocol",
            type: .dynamic,
            targets: ["NucleusSessionProtocol"]),
    ],
    dependencies: [
        .package(
            name: "NucleusConfigModel",
            path: "../../config/model"),
        .package(
            name: "NucleusIPCTransportPackage",
            path: "../../ipc/transport"),
    ],
    targets: [
        .target(
            name: "NucleusSessionProtocol",
            dependencies: [
                .product(name: "NucleusConfig", package: "NucleusConfigModel"),
                .product(
                    name: "NucleusIPCTransport",
                    package: "NucleusIPCTransportPackage"),
            ],
            swiftSettings: [
                .strictMemorySafety(),
                .unsafeFlags(["-warnings-as-errors"]),
                .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
            ]),
        .testTarget(
            name: "NucleusSessionProtocolTests",
            dependencies: [
                "NucleusSessionProtocol",
                .product(
                    name: "NucleusIPCTransport",
                    package: "NucleusIPCTransportPackage"),
            ],
            swiftSettings: [
                .strictMemorySafety(),
                .unsafeFlags(["-warnings-as-errors"]),
                .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
            ]),
    ]
)
