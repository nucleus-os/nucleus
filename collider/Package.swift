// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "collider-cli",
    platforms: [.macOS("27")],
    products: [
        .executable(name: "collider", targets: ["Collider"])
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
        .target(
            name: "ColliderCommands",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "ColliderCore", package: "engine"),
                .product(name: "ColliderRuntime", package: "engine"),
                .product(
                    name: "NucleusSessionProtocol",
                    package: "Nucleus",
                    condition: .when(platforms: [.linux])),
                .product(
                    name: "NucleusAndroidRuntimeCore",
                    package: "Nucleus",
                    condition: .when(platforms: [.linux])),
                "AndroidRuntimeColliderRecipe",
                "ChromiumColliderRecipe",
                "CompositorAppColliderRecipe",
                "CompositorColliderRecipe",
                "ConfigColliderRecipe",
                "CoreColliderRecipe",
                "IPCColliderRecipe",
                "LinuxColliderRecipe",
                "NativeBuilderColliderRecipe",
                "ReactNativeColliderRecipe",
                "ShellColliderRecipe",
                "SwiftTargetSDKColliderRecipe",
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
            name: "NativeBuilderColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),
        .target(
            name: "ReactNativeColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),
        .target(
            name: "ShellColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),
        .target(
            name: "SwiftTargetSDKColliderRecipe",
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
                "AndroidRuntimeColliderRecipe",
                "ChromiumColliderRecipe",
                .product(name: "ColliderCore", package: "engine"),
                "CoreColliderRecipe",
                "NativeBuilderColliderRecipe",
                .product(
                    name: "NucleusSessionProtocol",
                    package: "Nucleus",
                    condition: .when(platforms: [.linux])),
                .product(
                    name: "NucleusAndroidRuntimeCore",
                    package: "Nucleus",
                    condition: .when(platforms: [.linux])),
                "ReactNativeColliderRecipe",
                "SwiftTargetSDKColliderRecipe",
                "TracyColliderRecipe",
                "VulkanColliderRecipe",
                "WaylandColliderRecipe",
            ]),
        .testTarget(
            name: "SwiftTargetSDKColliderRecipeTests",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                "SwiftTargetSDKColliderRecipe",
            ]),
        .testTarget(
            name: "ShellColliderRecipeTests",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                "ShellColliderRecipe",
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
    var swiftSettings =
        (target.swiftSettings ?? []) + [
            .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]
    if let feature = Context.environment["NUCLEUS_SWIFT_DIAGNOSTIC_FEATURE"] {
        swiftSettings.append(.unsafeFlags(["-enable-upcoming-feature", feature]))
    }
    target.swiftSettings = swiftSettings
    target.cSettings =
        (target.cSettings ?? []) + [
            .unsafeFlags(["-Werror"])
        ]
    target.cxxSettings =
        (target.cxxSettings ?? []) + [
            .unsafeFlags(["-Werror"])
        ]
}
