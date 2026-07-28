// swift-tools-version:6.4

import PackageDescription

let package = Package(
    name: "NucleusConfigServicePackage",
    products: [
        .library(
            name: "NucleusConfigService",
            type: .dynamic,
            targets: ["NucleusConfigService"]),
    ],
    dependencies: [
        .package(name: "NucleusConfigModel", path: "../model"),
        .package(name: "NucleusConfigIOPackage", path: ".."),
        .package(
            name: "NucleusLinuxPlatform",
            path: "../../platform-linux"),
        .package(
            name: "NucleusSessionProtocolPackage",
            path: "../../session/protocol"),
    ],
    targets: [
        .target(
            name: "NucleusConfigService",
            dependencies: [
                .product(
                    name: "NucleusConfig",
                    package: "NucleusConfigModel"),
                .product(
                    name: "NucleusConfigIO",
                    package: "NucleusConfigIOPackage"),
                .product(
                    name: "NucleusLinux",
                    package: "NucleusLinuxPlatform"),
                .product(
                    name: "NucleusSessionProtocol",
                    package: "NucleusSessionProtocolPackage"),
            ]),
        .testTarget(
            name: "NucleusConfigServiceTests",
            dependencies: ["NucleusConfigService"]),
    ]
)

for target in package.targets {
    target.swiftSettings = (target.swiftSettings ?? []) + [
        .strictMemorySafety(),
        .unsafeFlags(["-warnings-as-errors"]),
        .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
    ]
    target.cSettings = (target.cSettings ?? []) + [.unsafeFlags(["-Werror"])]
}
