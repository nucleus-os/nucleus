// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "NucleusControlServicePackage",
    products: [
        .library(
            name: "NucleusControlService",
            type: .dynamic,
            targets: ["NucleusControlService"]),
    ],
    dependencies: [
        .package(name: "NucleusIPCTransportPackage", path: "../transport"),
        .package(
            name: "NucleusControlProtocolPackage",
            path: "../control-protocol"),
        .package(
            name: "NucleusLinuxPlatform",
            path: "../../platform-linux"),
        .package(
            name: "NucleusSessionProtocolPackage",
            path: "../../session/protocol"),
    ],
    targets: [
        .target(
            name: "NucleusControlService",
            dependencies: [
                .product(
                    name: "NucleusIPCTransport",
                    package: "NucleusIPCTransportPackage"),
                .product(
                    name: "NucleusControlProtocol",
                    package: "NucleusControlProtocolPackage"),
                .product(
                    name: "NucleusLinux",
                    package: "NucleusLinuxPlatform"),
                .product(
                    name: "NucleusSessionProtocol",
                    package: "NucleusSessionProtocolPackage"),
            ]),
        .testTarget(
            name: "NucleusControlServiceTests",
            dependencies: ["NucleusControlService"]),
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
