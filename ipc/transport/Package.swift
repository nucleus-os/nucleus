// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "NucleusIPCTransportPackage",
    products: [
        .library(
            name: "NucleusIPCTransport",
            type: .dynamic,
            targets: ["NucleusIPCTransport", "NucleusIPCTransportC"]),
    ],
    targets: [
        .target(
            name: "NucleusIPCTransportC",
            publicHeadersPath: "include"),
        .target(
            name: "NucleusIPCTransport",
            dependencies: ["NucleusIPCTransportC"],
            swiftSettings: [
                .strictMemorySafety(),
                .unsafeFlags(["-warnings-as-errors"]),
                .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
            ]),
        .testTarget(
            name: "NucleusIPCTransportTests",
            dependencies: ["NucleusIPCTransport"],
            swiftSettings: [
                .strictMemorySafety(),
                .unsafeFlags(["-warnings-as-errors"]),
                .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
            ]),
    ]
)
