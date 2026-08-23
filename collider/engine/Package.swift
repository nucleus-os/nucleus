// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "engine",
    platforms: [.macOS("27")],
    products: [
        .library(
            name: "ColliderAppleContainer",
            targets: ["ColliderAppleContainer"]),
        .library(name: "ColliderCore", targets: ["ColliderCore"]),
        .library(name: "ColliderEngine", targets: ["ColliderEngine"]),
        .library(name: "ColliderPersistence", targets: ["ColliderPersistence"]),
        .library(name: "ColliderPlanning", targets: ["ColliderPlanning"]),
        .library(name: "ColliderRuntime", targets: ["ColliderRuntime"]),
        .library(name: "ColliderTesting", targets: ["ColliderTesting"]),
    ],
    dependencies: [
        .package(path: "../../third-party/container"),
        .package(url: "https://github.com/apple/containerization.git", exact: "0.40.2"),
        .package(
            url: "https://github.com/nucleus-os/swift-system.git",
            revision: "2b0f3ac4a6b12719c7f72ebe7db26a34dabd7979"),
        .package(
            url: "https://github.com/nucleus-os/swift-subprocess.git",
            revision: "809c53762b881a045030acdbddd7399dd92a6175"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1"),
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.14.0"),
    ],
    targets: [
        .target(
            name: "ColliderAppleContainer",
            dependencies: [
                "ColliderCore",
                "ColliderRuntime",
                .product(name: "ContainerAPIClient", package: "container"),
                .product(name: "ContainerBuild", package: "container"),
                .product(name: "ContainerCommands", package: "container"),
                .product(name: "ContainerResource", package: "container"),
                .product(name: "Containerization", package: "containerization"),
                .product(
                    name: "ContainerizationOCI",
                    package: "containerization"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SystemPackage", package: "swift-system"),
            ]),
        .target(
            name: "ColliderCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SystemPackage", package: "swift-system"),
            ]),
        .target(
            name: "ColliderPlanning",
            dependencies: ["ColliderCore"]),
        .target(
            name: "ColliderPersistence",
            dependencies: [
                "ColliderCore",
                "ColliderPlatformC",
                .product(
                    name: "Subprocess",
                    package: "swift-subprocess"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SystemPackage", package: "swift-system"),
            ]),
        .target(
            name: "ColliderDownloads",
            dependencies: [
                "ColliderCore",
                "ColliderPlatformC",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SystemPackage", package: "swift-system"),
            ]),
        .target(
            name: "ColliderEngine",
            dependencies: [
                "ColliderCore",
                "ColliderPersistence",
                "ColliderPlanning",
                "ColliderRuntime",
            ]),
        .target(
            name: "ColliderPlatformC",
            path: "Sources/ColliderPlatformC",
            publicHeadersPath: "include"),
        .target(
            name: "ColliderRuntime",
            dependencies: [
                "ColliderCore",
                "ColliderDownloads",
                "ColliderPersistence",
                "ColliderPlatformC",
                .product(
                    name: "Subprocess",
                    package: "swift-subprocess"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SystemPackage", package: "swift-system"),
            ]),
        .target(
            name: "ColliderTesting",
            dependencies: ["ColliderCore"]),
        .testTarget(
            name: "ColliderCoreTests",
            dependencies: [
                "ColliderAppleContainer", "ColliderCore", "ColliderDownloads",
                "ColliderEngine",
                "ColliderPersistence", "ColliderPlanning", "ColliderRuntime",
            ],
            resources: [
                .copy("Resources/ToolchainValidationFixtures")
            ]),
        .testTarget(
            name: "ColliderPersistenceTests",
            dependencies: ["ColliderCore", "ColliderPersistence"]),
        .testTarget(
            name: "ColliderPlanningTests",
            dependencies: [
                "ColliderCore", "ColliderPersistence", "ColliderPlanning",
            ]),
    ]
)

for target in package.targets {
    target.swiftSettings =
        (target.swiftSettings ?? []) + [
            .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]
    target.cSettings = (target.cSettings ?? []) + [.unsafeFlags(["-Werror"])]
}
