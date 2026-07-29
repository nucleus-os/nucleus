// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "collider-cli",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "collider", targets: ["Collider"]),
        .executable(
            name: "collider-android-privileged",
            targets: ["ColliderAndroidPrivilegedExecutable"]),
    ],
    dependencies: [
        .package(path: "engine"),
        .package(path: "../third-party/swift-argument-parser"),
        .package(name: "Nucleus", path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "Collider",
            dependencies: ["ColliderCommands"]),
        .executableTarget(
            name: "ColliderAndroidPrivilegedExecutable",
            dependencies: ["ColliderAndroidPrivileged"]),
        .target(
            name: "ColliderAndroidPrivileged",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "ColliderRuntime", package: "engine"),
            ]),
        .target(
            name: "ColliderCommands",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "ColliderAndroidPrivileged",
                .product(name: "ColliderCore", package: "engine"),
                .product(name: "ColliderRuntime", package: "engine"),
                .product(
                    name: "NucleusSessionProtocol",
                    package: "Nucleus"),
                .product(
                    name: "NucleusAndroidContainerContract",
                    package: "Nucleus"),
                "AndroidRuntimeColliderRecipe",
                "ChromiumColliderRecipe",
                "CompositorAppColliderRecipe",
                "CompositorColliderRecipe",
                "ConfigColliderRecipe",
                "CoreColliderRecipe",
                "IPCColliderRecipe",
                "LinuxColliderRecipe",
                "ReactNativeColliderRecipe",
                "ShellColliderRecipe",
                "SwiftPlatformColliderRecipe",
                "TracyColliderRecipe",
                "VulkanColliderRecipe",
                "WaylandColliderRecipe",
            ]),
        .target(
            name: "AndroidRuntimeColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),
        .target(
            name: "ChromiumColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),
        .target(
            name: "CompositorAppColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),
        .target(
            name: "CompositorColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),
        .target(
            name: "ConfigColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),
        .target(
            name: "CoreColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),
        .target(
            name: "IPCColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),
        .target(
            name: "LinuxColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),
        .target(
            name: "ReactNativeColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),
        .target(
            name: "ShellColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),
        .target(
            name: "SwiftPlatformColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),
        .target(
            name: "TracyColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),
        .target(
            name: "VulkanColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),
        .target(
            name: "WaylandColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),
        .testTarget(
            name: "ColliderCommandsTests",
            dependencies: [
                "ColliderCommands",
                "ColliderAndroidPrivileged",
                "AndroidRuntimeColliderRecipe",
                "ChromiumColliderRecipe",
                .product(name: "ColliderCore", package: "engine"),
                "CoreColliderRecipe",
                .product(
                    name: "NucleusSessionProtocol",
                    package: "Nucleus"),
                "ReactNativeColliderRecipe",
                "TracyColliderRecipe",
                "VulkanColliderRecipe",
                "WaylandColliderRecipe",
            ]),
        .testTarget(
            name: "SwiftPlatformColliderRecipeTests",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                "SwiftPlatformColliderRecipe",
            ]),
    ]
)

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
    if let feature = Context.environment["NUCLEUS_SWIFT_DIAGNOSTIC_FEATURE"] {
        swiftSettings.append(.unsafeFlags(["-enable-upcoming-feature", feature]))
    }
    target.swiftSettings = swiftSettings
    target.cSettings = (target.cSettings ?? []) + [
        .unsafeFlags(["-Werror"]),
    ]
    target.cxxSettings = (target.cxxSettings ?? []) + [
        .unsafeFlags(["-Werror"]),
    ]
}
