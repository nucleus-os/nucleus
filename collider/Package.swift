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
                "ColliderSwiftPM",
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
                "CompositorColliderRecipe",
                "CoreColliderRecipe",
                "LinuxColliderRecipe",
                "NativeBuilderColliderRecipe",
                "QualificationColliderRecipe",
                "ReactNativeColliderRecipe",
                "ReleaseGateColliderRecipe",
                "ShellColliderRecipe",
                "SwiftTargetSDKColliderRecipe",
                "VulkanColliderRecipe",
                "WaylandColliderRecipe",
            ]),
        .target(
            name: "ColliderSwiftPM",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),
        .target(
            name: "AndroidRuntimeColliderRecipe",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                "ShellColliderRecipe",
                .product(
                    name: "NucleusAndroidRuntimeCore",
                    package: "Nucleus",
                    condition: .when(platforms: [.linux])),
            ]),
        .target(
            name: "ChromiumColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),
        .target(
            name: "CompositorColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),
        .target(
            name: "CoreColliderRecipe",
            dependencies: [
                .product(name: "ColliderCore", package: "engine")
            ]),
        .target(
            name: "LinuxColliderRecipe",
            dependencies: [
                .product(name: "ColliderCore", package: "engine")
            ]),
        .target(
            name: "NativeBuilderColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),
        .target(
            name: "QualificationColliderRecipe",
            dependencies: [
                .product(name: "ColliderCore", package: "engine")
            ]),
        .target(
            name: "ReactNativeColliderRecipe",
            dependencies: [
                .product(name: "ColliderCore", package: "engine")
            ]),
        .target(
            name: "ReleaseGateColliderRecipe",
            dependencies: [
                .product(name: "ColliderCore", package: "engine")
            ]),
        .target(
            name: "ShellColliderRecipe",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                .product(
                    name: "NucleusAndroidRuntimeCore",
                    package: "Nucleus",
                    condition: .when(platforms: [.linux])),
            ]),
        .target(
            name: "SwiftTargetSDKColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),
        .target(
            name: "VulkanColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),
        .target(
            name: "WaylandColliderRecipe",
            dependencies: [
                .product(name: "ColliderCore", package: "engine")
            ]),
        .testTarget(
            name: "ChromiumColliderRecipeTests",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                .product(name: "ColliderRuntime", package: "engine"),
                "ChromiumColliderRecipe",
            ]),
        .testTarget(
            name: "ColliderCommandsTests",
            dependencies: [
                "ColliderCommands",
                "AndroidRuntimeColliderRecipe",
                "ChromiumColliderRecipe",
                "CompositorColliderRecipe",
                .product(name: "ColliderCore", package: "engine"),
                .product(name: "ColliderRuntime", package: "engine"),
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
                "VulkanColliderRecipe",
                "WaylandColliderRecipe",
            ]),
        .testTarget(
            name: "CoreColliderRecipeTests",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                .product(name: "ColliderRuntime", package: "engine"),
                "CoreColliderRecipe",
            ]),
        .testTarget(
            name: "ColliderSwiftPMTests",
            dependencies: [
                "ColliderSwiftPM",
                .product(name: "ColliderCore", package: "engine"),
                .product(name: "ColliderRuntime", package: "engine"),
            ]),
        .testTarget(
            name: "SwiftTargetSDKColliderRecipeTests",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                .product(name: "ColliderRuntime", package: "engine"),
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
            .interoperabilityMode(.Cxx),
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
