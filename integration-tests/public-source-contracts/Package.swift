// swift-tools-version: 6.4

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .interoperabilityMode(.Cxx),
    .strictMemorySafety(),
    .unsafeFlags(["-warnings-as-errors"]),
    .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
]

let package = Package(
    name: "NucleusPublicSourceContracts",
    platforms: [.macOS(.v27)],
    dependencies: [
        .package(name: "nucleus", path: "../..")
    ],
    targets: [
        .target(
            name: "PortableAuthoringClient",
            dependencies: [.product(name: "Nucleus", package: "nucleus")],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "DesktopClient",
            dependencies: [.product(name: "NucleusDesktop", package: "nucleus")],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "ReactRuntimeClient",
            dependencies: [.product(name: "NucleusReactRuntime", package: "nucleus")],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "FoundationClient",
            dependencies: [.product(name: "NucleusFoundation", package: "nucleus")],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "SessionProtocolClient",
            dependencies: [.product(name: "NucleusSessionProtocol", package: "nucleus")],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "AndroidRuntimeCoreClient",
            dependencies: [.product(name: "NucleusAndroidRuntimeCore", package: "nucleus")],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "PublicSourceContractTests",
            dependencies: [
                "AndroidRuntimeCoreClient", "DesktopClient", "FoundationClient",
                "PortableAuthoringClient", "ReactRuntimeClient", "SessionProtocolClient",
            ],
            swiftSettings: swiftSettings
        ),
    ]
)
