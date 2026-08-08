// swift-tools-version: 6.4
import PackageDescription

var packageDependencies: [Package.Dependency] = [
    .package(path: "engine"),
    .package(path: "../third-party/swift-argument-parser"),
]
var nucleusSessionDependencies: [Target.Dependency] = []
var nucleusAndroidRuntimeDependencies: [Target.Dependency] = []
#if os(Linux)
packageDependencies.append(.package(name: "Nucleus", path: ".."))
nucleusSessionDependencies.append(
    .product(name: "NucleusSessionProtocol", package: "Nucleus"))
nucleusAndroidRuntimeDependencies.append(
    .product(name: "NucleusAndroidRuntimeCore", package: "Nucleus"))
#endif

let package = Package(
    name: "collider-cli",
    platforms: [.macOS("27")],
    products: [
        .executable(name: "collider", targets: ["Collider"]),
        .executable(
            name: "nucleus-runtime-assembler",
            targets: ["NucleusRuntimeAssembler"]),
    ],
    dependencies: packageDependencies,
    targets: [
        .executableTarget(
            name: "Collider",
            dependencies: ["ColliderCLI"]),
        .executableTarget(
            name: "NucleusRuntimeAssembler",
            dependencies: [
                .product(name: "ColliderRuntime", package: "engine"),
                "ShellColliderRecipe",
            ]),
        .target(
            name: "ColliderCLI",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(
                    name: "ColliderAppleContainer",
                    package: "engine",
                    condition: .when(platforms: [.macOS])),
                .product(name: "ColliderCore", package: "engine"),
                .product(name: "ColliderPersistence", package: "engine"),
                .product(name: "ColliderRuntime", package: "engine"),
                "ColliderWorkspaceCommands",
                .target(
                    name: "ColliderLinuxOperations",
                    condition: .when(platforms: [.linux])),
            ]),
        .target(
            name: "ColliderWorkspaceCommands",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "ColliderCore", package: "engine"),
                .product(name: "ColliderEngine", package: "engine"),
                .product(name: "ColliderPersistence", package: "engine"),
                .product(name: "ColliderRuntime", package: "engine"),
                "ColliderSwiftPM",
                "AndroidRuntimeColliderRecipe",
                "ChromiumColliderRecipe",
                "CompositorColliderRecipe",
                "CoreColliderRecipe",
                "LinuxColliderRecipe",
                "NativeBuilderColliderRecipe",
                "ReactNativeColliderRecipe",
                "ReleaseGateColliderRecipe",
                "ShellColliderRecipe",
                "SwiftTargetSDKColliderRecipe",
                "VulkanColliderRecipe",
                "WaylandColliderRecipe",
            ]),
        .target(
            name: "ColliderLinuxOperations",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "ColliderCore", package: "engine"),
                .product(name: "ColliderRuntime", package: "engine"),
                "ColliderWorkspaceCommands",
                "AndroidRuntimeColliderRecipe",
                "ShellColliderRecipe",
            ] + nucleusSessionDependencies + nucleusAndroidRuntimeDependencies),
        .target(
            name: "ColliderSwiftPM",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),
        .target(
            name: "AndroidRuntimeColliderRecipe",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                "NativeBuilderColliderRecipe",
                "ShellColliderRecipe",
            ] + nucleusAndroidRuntimeDependencies),
        .target(
            name: "ChromiumColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),
        .target(
            name: "CompositorColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),
        .target(
            name: "CoreColliderRecipe",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                "NativeBuilderColliderRecipe",
            ]),
        .target(
            name: "LinuxColliderRecipe",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                "NativeBuilderColliderRecipe",
                "ShellColliderRecipe",
            ]),
        .target(
            name: "NativeBuilderColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),
        .target(
            name: "ReactNativeColliderRecipe",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                "NativeBuilderColliderRecipe",
            ]),
        .target(
            name: "ReleaseGateColliderRecipe",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                "NativeBuilderColliderRecipe",
            ]),
        .target(
            name: "ShellColliderRecipe",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                "NativeBuilderColliderRecipe",
            ] + nucleusAndroidRuntimeDependencies),
        .target(
            name: "SwiftTargetSDKColliderRecipe",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                "NativeBuilderColliderRecipe",
            ]),
        .target(
            name: "VulkanColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),
        .target(
            name: "WaylandColliderRecipe",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                "NativeBuilderColliderRecipe",
            ]),
        .testTarget(
            name: "ChromiumColliderRecipeTests",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                .product(name: "ColliderEngine", package: "engine"),
                .product(name: "ColliderPersistence", package: "engine"),
                .product(name: "ColliderRuntime", package: "engine"),
                "ChromiumColliderRecipe",
            ]),
        .testTarget(
            name: "ColliderCLITests",
            dependencies: [
                "ColliderCLI",
                "ColliderWorkspaceCommands",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .target(
                    name: "ColliderLinuxOperations",
                    condition: .when(platforms: [.linux])),
                .product(name: "ColliderCore", package: "engine"),
                .product(name: "ColliderPersistence", package: "engine"),
                .product(name: "ColliderRuntime", package: "engine"),
            ]),
        .testTarget(
            name: "ColliderWorkspaceCommandsTests",
            dependencies: [
                "ColliderWorkspaceCommands",
                "AndroidRuntimeColliderRecipe",
                "ChromiumColliderRecipe",
                "CompositorColliderRecipe",
                .product(
                    name: "ColliderAppleContainer",
                    package: "engine",
                    condition: .when(platforms: [.macOS])),
                .product(name: "ColliderCore", package: "engine"),
                .product(name: "ColliderEngine", package: "engine"),
                .product(name: "ColliderPersistence", package: "engine"),
                .product(name: "ColliderPlanning", package: "engine"),
                .product(name: "ColliderRuntime", package: "engine"),
                .product(name: "ColliderTesting", package: "engine"),
                "CoreColliderRecipe",
                "NativeBuilderColliderRecipe",
                "ReactNativeColliderRecipe",
                "ReleaseGateColliderRecipe",
                "SwiftTargetSDKColliderRecipe",
                "VulkanColliderRecipe",
                "WaylandColliderRecipe",
            ]),
        .testTarget(
            name: "ColliderLinuxOperationsTests",
            dependencies: [
                .target(
                    name: "ColliderLinuxOperations",
                    condition: .when(platforms: [.linux])),
                "ColliderWorkspaceCommands",
                "AndroidRuntimeColliderRecipe",
                .product(name: "ColliderCore", package: "engine"),
                .product(name: "ColliderPersistence", package: "engine"),
                .product(name: "ColliderRuntime", package: "engine"),
            ] + nucleusSessionDependencies + nucleusAndroidRuntimeDependencies),
        .testTarget(
            name: "CoreColliderRecipeTests",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                .product(name: "ColliderEngine", package: "engine"),
                .product(name: "ColliderRuntime", package: "engine"),
                "CoreColliderRecipe",
            ]),
        .testTarget(
            name: "ColliderSwiftPMTests",
            dependencies: [
                "ColliderSwiftPM",
                .product(name: "ColliderCore", package: "engine"),
                .product(name: "ColliderEngine", package: "engine"),
                .product(name: "ColliderRuntime", package: "engine"),
            ]),
        .testTarget(
            name: "SwiftTargetSDKColliderRecipeTests",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                .product(name: "ColliderEngine", package: "engine"),
                .product(name: "ColliderRuntime", package: "engine"),
                .product(name: "ColliderTesting", package: "engine"),
                "SwiftTargetSDKColliderRecipe",
            ]),
        .testTarget(
            name: "ShellColliderRecipeTests",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                "NativeBuilderColliderRecipe",
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
