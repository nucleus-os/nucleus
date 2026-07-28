// swift-tools-version:6.4

import PackageDescription

let package = Package(
    name: "NucleusLinuxPlatform",
    products: [
        .library(name: "LinuxColliderRecipe", targets: ["LinuxColliderRecipe"]),
        .library(
            name: "NucleusLinux",
            type: .dynamic,
            targets: [
                "NucleusLinuxPrimitives",
                "NucleusLinuxPrimitivesC",
                "NucleusLinuxReactor",
                "NucleusLinuxReactorC",
                "NucleusLinuxDBus",
                "NucleusLinuxSessionC",
                "NucleusThemeAssetIO",
            ]),
        .executable(
            name: "NucleusLinuxThreadSanitizerHarness",
            targets: ["NucleusLinuxThreadSanitizerHarness"]),
    ],
    dependencies: [
        .package(path: "../collider/engine"),
        .package(path: "../third-party/swift-system"),
    ],
    targets: [
        .target(
            name: "LinuxColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),
        .target(
            name: "NucleusLinuxPrimitives",
            dependencies: ["NucleusLinuxPrimitivesC"],
            path: "Sources/NucleusLinuxPrimitives",
            swiftSettings: [
                .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]),
            ]),
        .target(
            name: "NucleusLinuxPrimitivesC",
            path: "Sources/NucleusLinuxPrimitivesC",
            publicHeadersPath: "include"),
        .target(
            name: "NucleusLinuxReactor",
            dependencies: [
                "NucleusLinuxPrimitives",
                "NucleusLinuxReactorC",
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            path: "Sources/NucleusLinuxReactor",
            swiftSettings: [
                .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]),
            ]),
        .target(
            name: "NucleusLinuxReactorC",
            path: "Sources/NucleusLinuxReactorC",
            publicHeadersPath: "include"),
        .systemLibrary(
            name: "NucleusLinuxDBusC",
            path: "Sources/NucleusLinuxDBusC",
            pkgConfig: "libsystemd"),
        .target(
            name: "NucleusLinuxDBus",
            dependencies: ["NucleusLinuxDBusC", "NucleusLinuxReactor"],
            path: "Sources/NucleusLinuxDBus"),
        .target(
            name: "NucleusLinuxSessionC",
            path: "Sources/NucleusLinuxSessionC",
            publicHeadersPath: "include"),
        .target(
            name: "NucleusThemeAssetIO",
            path: "Sources/NucleusThemeAssetIO",
            swiftSettings: [.strictMemorySafety()]),
        .executableTarget(
            name: "NucleusLinuxThreadSanitizerHarness",
            dependencies: [
                "NucleusLinuxReactor",
                "NucleusLinuxReactorC",
            ],
            path: "SanitizerHarnesses/NucleusLinuxThreadSanitizerHarness",
            swiftSettings: [
                .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]),
            ]),
        .testTarget(
            name: "NucleusLinuxPrimitivesTests",
            dependencies: [
                "NucleusLinuxPrimitives",
                "NucleusLinuxPrimitivesC",
            ],
            path: "Tests/NucleusLinuxPrimitivesTests",
            swiftSettings: [
                .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]),
            ]),
        .testTarget(
            name: "NucleusLinuxReactorTests",
            dependencies: ["NucleusLinuxReactor"],
            path: "Tests/NucleusLinuxReactorTests",
            swiftSettings: [
                .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]),
            ]),
        .testTarget(
            name: "NucleusLinuxDBusTests",
            dependencies: ["NucleusLinuxDBus"],
            path: "Tests/NucleusLinuxDBusTests"),
        .testTarget(
            name: "NucleusThemeAssetIOTests",
            dependencies: ["NucleusThemeAssetIO"],
            path: "Tests/NucleusThemeAssetIOTests"),
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
