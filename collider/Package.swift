// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "collider-cli",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "collider", targets: ["Collider"]),
    ],
    dependencies: [
        .package(path: "engine"),
        .package(path: "../third-party/swift-argument-parser"),
        .package(name: "NucleusSwiftPlatform", path: "../swift-toolchain"),
        .package(name: "swift-tracy", path: "../swift-tracy"),
        .package(name: "swift-vulkan", path: "../swift-vulkan"),
        .package(name: "swift-wayland", path: "../swift-wayland"),
        .package(name: "Nucleus", path: "../core"),
        .package(name: "NucleusLinuxPlatform", path: "../platform-linux"),
        .package(name: "android-runtime", path: "../android-runtime"),
        .package(name: "NucleusReactNative", path: "../react-native"),
        .package(name: "compositor-core", path: "../compositor/compositor-core"),
        .package(name: "NucleusCompositorApp", path: "../compositor/compositor"),
        .package(name: "NucleusShell", path: "../shell"),
        .package(name: "NucleusBrowser", path: "../chromium"),
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
                .product(name: "NucleusSessionProtocol", package: "engine"),
                .product(
                    name: "SwiftPlatformColliderRecipe",
                    package: "NucleusSwiftPlatform"),
                .product(name: "TracyColliderRecipe", package: "swift-tracy"),
                .product(name: "VulkanColliderRecipe", package: "swift-vulkan"),
                .product(name: "WaylandColliderRecipe", package: "swift-wayland"),
                .product(name: "CoreColliderRecipe", package: "Nucleus"),
                .product(name: "LinuxColliderRecipe", package: "NucleusLinuxPlatform"),
                .product(name: "AndroidRuntimeColliderRecipe", package: "android-runtime"),
                .product(name: "ReactNativeColliderRecipe", package: "NucleusReactNative"),
                .product(name: "CompositorColliderRecipe", package: "compositor-core"),
                .product(name: "CompositorAppColliderRecipe", package: "NucleusCompositorApp"),
                .product(name: "ShellColliderRecipe", package: "NucleusShell"),
                .product(name: "ChromiumColliderRecipe", package: "NucleusBrowser"),
            ]),
        .testTarget(
            name: "ColliderCommandsTests",
            dependencies: [
                "ColliderCommands",
                .product(name: "AndroidRuntimeColliderRecipe", package: "android-runtime"),
                .product(name: "ChromiumColliderRecipe", package: "NucleusBrowser"),
                .product(name: "ColliderCore", package: "engine"),
                .product(name: "CoreColliderRecipe", package: "Nucleus"),
                .product(name: "NucleusSessionProtocol", package: "engine"),
                .product(name: "ReactNativeColliderRecipe", package: "NucleusReactNative"),
                .product(name: "VulkanColliderRecipe", package: "swift-vulkan"),
                .product(name: "WaylandColliderRecipe", package: "swift-wayland"),
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
