// swift-tools-version:6.4

import PackageDescription

let package = Package(
    name: "NucleusLinuxSessionPackage",
    products: [
        .executable(
            name: "NucleusSessionSupervisor",
            targets: ["NucleusSessionSupervisor"]),
    ],
    dependencies: [
        .package(name: "NucleusFoundation", path: "../../foundation"),
        .package(name: "NucleusLinuxPlatform", path: ".."),
        .package(
            name: "NucleusSessionProtocolPackage",
            path: "../../session/protocol"),
        .package(
            name: "NucleusConfigServiceExecutablePackage",
            path: "../../config/config-service"),
        .package(
            name: "NucleusControlServiceExecutable",
            path: "../../ipc/control-service"),
        .package(
            name: "NucleusControlClientPackage",
            path: "../../ipc/control-client"),
        .package(
            name: "NucleusControlProtocolPackage",
            path: "../../ipc/control-protocol"),
        .package(
            name: "NucleusIPCTransportPackage",
            path: "../../ipc/transport"),
        .package(
            name: "NucleusIPCPackage",
            path: "../../ipc"),
    ],
    targets: [
        .executableTarget(
            name: "NucleusSessionSupervisor",
            dependencies: [
                .product(
                    name: "NucleusFoundation",
                    package: "NucleusFoundation"),
                .product(
                    name: "NucleusLinux",
                    package: "NucleusLinuxPlatform"),
                .product(
                    name: "NucleusSessionProtocol",
                    package: "NucleusSessionProtocolPackage"),
                .product(
                    name: "NucleusIPCTransport",
                    package: "NucleusIPCTransportPackage"),
            ],
            path: "Sources/NucleusSessionSupervisor"),
        .executableTarget(
            name: "NucleusSessionFixture",
            dependencies: [
                .product(
                    name: "NucleusControlClient",
                    package: "NucleusControlClientPackage"),
                .product(
                    name: "NucleusControlProtocol",
                    package: "NucleusControlProtocolPackage"),
                .product(
                    name: "NucleusSessionProtocol",
                    package: "NucleusSessionProtocolPackage"),
                .product(
                    name: "NucleusIPCTransport",
                    package: "NucleusIPCTransportPackage"),
            ],
            path: "Tests/Fixtures/NucleusSessionFixture"),
        .testTarget(
            name: "NucleusLinuxSessionTests",
            dependencies: [
                "NucleusSessionSupervisor",
                "NucleusSessionFixture",
                .product(
                    name: "NucleusConfigService",
                    package: "NucleusConfigServiceExecutablePackage"),
                .product(
                    name: "NucleusControlService",
                    package: "NucleusControlServiceExecutable"),
                .product(
                    name: "NucleusControlClient",
                    package: "NucleusControlClientPackage"),
                .product(
                    name: "NucleusControlProtocol",
                    package: "NucleusControlProtocolPackage"),
                .product(
                    name: "NucleusIPCTransport",
                    package: "NucleusIPCTransportPackage"),
                .product(
                    name: "nucleus",
                    package: "NucleusIPCPackage"),
                .product(
                    name: "NucleusSessionProtocol",
                    package: "NucleusSessionProtocolPackage"),
            ],
            path: "Tests/NucleusLinuxSessionTests"),
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
