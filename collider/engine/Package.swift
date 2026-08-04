// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "engine",
    platforms: [.macOS("27")],
    products: [
        .library(name: "ColliderCore", targets: ["ColliderCore"]),
        .library(name: "ColliderRuntime", targets: ["ColliderRuntime"]),
    ],
    dependencies: [
        .package(path: "../../third-party/container"),
        .package(path: "../../third-party/containerization"),
        .package(path: "../../third-party/swift-system"),
        .package(path: "../../third-party/swift-subprocess"),
        .package(path: "../../third-party/swift-crypto"),
        .package(path: "../../third-party/swift-log"),
    ],
    targets: [
        .target(
            name: "ColliderCore",
            dependencies: [
                .product(name: "SystemPackage", package: "swift-system")
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
            name: "ColliderPlatformC",
            path: "Sources/ColliderPlatformC",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedLibrary("dl", .when(platforms: [.linux]))
            ]),
        .target(
            name: "ColliderRuntime",
            dependencies: [
                "ColliderCore",
                "ColliderDownloads",
                "ColliderPlatformC",
                .product(
                    name: "ContainerAPIClient",
                    package: "container"),
                .product(
                    name: "ContainerBuild",
                    package: "container"),
                .product(
                    name: "ContainerCommands",
                    package: "container"),
                .product(
                    name: "ContainerResource",
                    package: "container"),
                .product(
                    name: "Containerization",
                    package: "containerization"),
                .product(
                    name: "Subprocess",
                    package: "swift-subprocess"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            resources: [
                .copy("Resources/ToolchainValidationFixtures")
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
