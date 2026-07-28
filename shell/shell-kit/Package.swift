// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "NucleusShellKitPackage",
    products: [
        .library(
            name: "NucleusShellKit",
            type: .dynamic,
            targets: ["NucleusShellRuntime"]),
    ],
    dependencies: [
        .package(name: "Nucleus", path: "../../core"),
        .package(name: "NucleusFoundation", path: "../../foundation"),
        .package(
            name: "NucleusWindowClientPackage",
            path: "../../window-client"),
        .package(
            name: "NucleusLinuxPlatform",
            path: "../../platform-linux"),
        .package(
            name: "NucleusLinuxDesktopPackage",
            path: "../../platform-linux/desktop"),
        .package(
            name: "NucleusSessionProtocolPackage",
            path: "../../session/protocol"),
        .package(
            name: "NucleusConfigModel",
            path: "../../config/model"),
        .package(
            name: "NucleusShellAuthWirePackage",
            path: "../auth-wire"),
        .package(name: "swift-tracy", path: "../../swift-tracy"),
    ],
    targets: [
        .target(
            name: "NucleusShellSignalC",
            path: "Sources/NucleusShellSignalC",
            publicHeadersPath: "include"),
        .target(
            name: "NucleusShellProcessC",
            path: "Sources/NucleusShellProcessC",
            publicHeadersPath: "include"),
        .target(
            name: "NucleusShellProduct",
            dependencies: [
                .product(name: "Nucleus", package: "Nucleus"),
            ],
            path: "Sources/NucleusShellProduct",
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags([
                    "-enable-experimental-feature", "Lifetimes",
                ]),
            ]),
        .target(
            name: "NucleusShellServices",
            dependencies: [
                .product(
                    name: "NucleusFoundation",
                    package: "NucleusFoundation"),
                .product(
                    name: "NucleusLinux",
                    package: "NucleusLinuxPlatform"),
                .product(name: "Nucleus", package: "Nucleus"),
                .product(
                    name: "NucleusConfig",
                    package: "NucleusConfigModel"),
                .product(
                    name: "NucleusSessionProtocol",
                    package: "NucleusSessionProtocolPackage"),
            ],
            path: "Sources/NucleusShellServices",
            swiftSettings: [.interoperabilityMode(.Cxx)]),
        .target(
            name: "NucleusShellAuth",
            dependencies: [
                .product(
                    name: "NucleusShellAuthWire",
                    package: "NucleusShellAuthWirePackage"),
                "NucleusShellProcessC",
                "NucleusShellProduct",
                .product(name: "Nucleus", package: "Nucleus"),
            ],
            path: "Sources/NucleusShellAuth",
            swiftSettings: [.interoperabilityMode(.Cxx)]),
        .target(
            name: "NucleusShellRuntime",
            dependencies: [
                .product(
                    name: "NucleusFoundation",
                    package: "NucleusFoundation"),
                .product(
                    name: "NucleusWindowClient",
                    package: "NucleusWindowClientPackage"),
                "NucleusShellSignalC",
                "NucleusShellProduct",
                "NucleusShellAuth",
                "NucleusShellServices",
                .product(
                    name: "NucleusLinux",
                    package: "NucleusLinuxPlatform"),
                .product(
                    name: "NucleusLinuxDesktop",
                    package: "NucleusLinuxDesktopPackage"),
                .product(
                    name: "NucleusSessionProtocol",
                    package: "NucleusSessionProtocolPackage"),
                .product(
                    name: "NucleusConfig",
                    package: "NucleusConfigModel"),
                .product(name: "Nucleus", package: "Nucleus"),
                .product(name: "SwiftTracy", package: "swift-tracy"),
            ],
            path: "Sources/NucleusShellRuntime",
            swiftSettings: [.interoperabilityMode(.Cxx)]),
        .executableTarget(
            name: "NucleusShellPamAttemptFixture",
            path: "Tests/Fixtures/NucleusShellPamAttemptFixture"),
        .testTarget(
            name: "NucleusWindowClientRuntimeTests",
            dependencies: [
                .product(
                    name: "NucleusWindowClient",
                    package: "NucleusWindowClientPackage"),
                "NucleusShellSignalC",
            ],
            path: "Tests/NucleusShellLoopTests"),
        .testTarget(
            name: "NucleusShellServicesTests",
            dependencies: [
                "NucleusShellServices",
                .product(
                    name: "NucleusConfig",
                    package: "NucleusConfigModel"),
                .product(
                    name: "NucleusSessionProtocol",
                    package: "NucleusSessionProtocolPackage"),
            ],
            path: "Tests/NucleusShellServicesTests",
            swiftSettings: [.interoperabilityMode(.Cxx)]),
        .testTarget(
            name: "NucleusShellAuthTests",
            dependencies: [
                "NucleusShellAuth",
                .product(
                    name: "NucleusShellAuthWire",
                    package: "NucleusShellAuthWirePackage"),
                "NucleusShellProcessC",
                "NucleusShellPamAttemptFixture",
                .product(name: "Nucleus", package: "Nucleus"),
            ],
            path: "Tests/NucleusShellAuthTests",
            swiftSettings: [.interoperabilityMode(.Cxx)]),
        .testTarget(
            name: "NucleusShellProductTests",
            dependencies: [
                "NucleusShellProduct",
                .product(name: "Nucleus", package: "Nucleus"),
                .product(
                    name: "NucleusFoundation",
                    package: "NucleusFoundation"),
            ],
            path: "Tests/NucleusShellProductTests",
            swiftSettings: [.interoperabilityMode(.Cxx)]),
    ])

for target in package.targets {
    switch target.type {
    case .regular, .executable, .test:
        break
    default:
        continue
    }
    var swiftSettings = (target.swiftSettings ?? []) + [
        .strictMemorySafety(),
        .unsafeFlags(["-warnings-as-errors"]),
        .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
    ]
    if let feature = Context.environment[
        "NUCLEUS_SWIFT_DIAGNOSTIC_FEATURE"
    ] {
        swiftSettings.append(.unsafeFlags([
            "-enable-upcoming-feature", feature,
        ]))
    }
    target.swiftSettings = swiftSettings
    target.cSettings = (target.cSettings ?? []) + [
        .unsafeFlags(["-Werror"]),
    ]
    target.cxxSettings = (target.cxxSettings ?? []) + [
        .unsafeFlags(["-Werror"]),
    ]
}
