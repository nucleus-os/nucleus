// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "collider",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ColliderCore", targets: ["ColliderCore"]),
        .library(name: "ColliderRuntime", targets: ["ColliderRuntime"]),
        .library(name: "NucleusSessionProtocol", targets: ["NucleusSessionProtocol"]),
    ],
    dependencies: [
        .package(path: "../third-party/swift-system"),
        .package(path: "../third-party/swift-subprocess"),
        .package(path: "../third-party/swift-crypto"),
    ],
    targets: [
        .target(
            name: "ColliderCore",
            dependencies: [
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
            name: "ColliderPlatformC",
            path: "Sources/ColliderPlatformC",
            publicHeadersPath: "include"),
        .target(
            name: "ColliderRuntime",
            dependencies: [
                "ColliderCore",
                "ColliderDownloads",
                "ColliderPlatformC",
                .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SystemPackage", package: "swift-system"),
            ]),
        .target(name: "NucleusSessionProtocol"),
        .testTarget(
            name: "ColliderCoreTests",
            dependencies: [
                "ColliderCore", "ColliderDownloads", "ColliderRuntime",
            ]),
    ]
)

for target in package.targets {
    target.swiftSettings = (target.swiftSettings ?? []) + [
        .unsafeFlags(["-warnings-as-errors"]),
        .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
    ]
    target.cSettings = (target.cSettings ?? []) + [.unsafeFlags(["-Werror"])]
}
