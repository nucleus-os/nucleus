// swift-tools-version:6.4

import PackageDescription

let package = Package(
    name: "NucleusLinuxPlatform",
    products: [
        .library(
            name: "NucleusLinuxReactor",
            targets: ["NucleusLinuxReactor"]),
        .library(name: "NucleusLinuxDBus", targets: ["NucleusLinuxDBus"]),
        .library(
            name: "NucleusLinuxEnvironment",
            targets: ["NucleusLinuxEnvironment"]),
        .library(
            name: "NucleusLinuxAccessibility",
            targets: ["NucleusLinuxAccessibility"]),
        .executable(
            name: "NucleusLinuxBenchmarks",
            targets: ["NucleusLinuxBenchmarks"]),
        .executable(
            name: "NucleusLinuxThreadSanitizerHarness",
            targets: ["NucleusLinuxThreadSanitizerHarness"]),
    ],
    dependencies: [
        .package(name: "Nucleus", path: "../core"),
        .package(path: "../core/third-party/swift-system"),
    ],
    targets: [
        .target(
            name: "NucleusLinuxReactor",
            dependencies: [
                "NucleusLinuxReactorC",
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            path: "Sources/NucleusLinuxReactor",
            swiftSettings: [
                .unsafeFlags([
                    "-enable-experimental-feature", "Lifetimes",
                ]),
            ]),
        .target(
            name: "NucleusLinuxReactorC",
            path: "Sources/NucleusLinuxReactorC",
            publicHeadersPath: "include"),
        .executableTarget(
            name: "NucleusLinuxThreadSanitizerHarness",
            dependencies: [
                "NucleusLinuxReactor",
                "NucleusLinuxReactorC",
            ],
            path: "SanitizerHarnesses/NucleusLinuxThreadSanitizerHarness",
            swiftSettings: [
                .unsafeFlags([
                    "-enable-experimental-feature", "Lifetimes",
                ]),
            ]),
        .systemLibrary(
            name: "NucleusLinuxDBusC",
            path: "Sources/NucleusLinuxDBusC",
            pkgConfig: "libsystemd"),
        .target(
            name: "NucleusLinuxDBus",
            dependencies: ["NucleusLinuxDBusC", "NucleusLinuxReactor"],
            path: "Sources/NucleusLinuxDBus"),
        .target(
            name: "NucleusLinuxAccessibility",
            dependencies: [
                "NucleusLinuxDBus",
                "NucleusLinuxReactor",
                .product(name: "NucleusUI", package: "Nucleus"),
            ],
            path: "Sources/NucleusLinuxAccessibility",
            swiftSettings: [.interoperabilityMode(.Cxx)]),
        .target(
            name: "NucleusLinuxEnvironment",
            dependencies: [
                "NucleusLinuxDBus",
                "NucleusLinuxReactor",
                .product(name: "NucleusUI", package: "Nucleus"),
            ],
            path: "Sources/NucleusLinuxEnvironment",
            swiftSettings: [.interoperabilityMode(.Cxx)]),
        .executableTarget(
            name: "NucleusLinuxBenchmarks",
            dependencies: [
                "NucleusLinuxAccessibility",
                .product(
                    name: "NucleusBenchmarkSupport",
                    package: "Nucleus"),
                .product(name: "NucleusUI", package: "Nucleus"),
            ],
            path: "Benchmarks/NucleusLinuxBenchmarks",
            swiftSettings: [.interoperabilityMode(.Cxx)]),
        .testTarget(
            name: "NucleusLinuxReactorTests",
            dependencies: ["NucleusLinuxReactor"],
            path: "Tests/NucleusLinuxReactorTests",
            swiftSettings: [
                .unsafeFlags([
                    "-enable-experimental-feature", "Lifetimes",
                ]),
            ]),
        .testTarget(
            name: "NucleusLinuxDBusTests",
            dependencies: ["NucleusLinuxDBus"],
            path: "Tests/NucleusLinuxDBusTests"),
        .testTarget(
            name: "NucleusLinuxAccessibilityTests",
            dependencies: [
                "NucleusLinuxAccessibility",
                .product(name: "NucleusUI", package: "Nucleus"),
            ],
            path: "Tests/NucleusLinuxAccessibilityTests",
            swiftSettings: [.interoperabilityMode(.Cxx)]),
        .testTarget(
            name: "NucleusLinuxEnvironmentTests",
            dependencies: [
                "NucleusLinuxEnvironment",
                .product(name: "NucleusUI", package: "Nucleus"),
            ],
            path: "Tests/NucleusLinuxEnvironmentTests",
            swiftSettings: [.interoperabilityMode(.Cxx)]),
    ]
)


for target in package.targets {
    switch target.type {
    case .regular, .executable, .test:
        break
    default:
        continue
    }
    target.swiftSettings = (target.swiftSettings ?? []) + [
        .unsafeFlags(["-warnings-as-errors"]),
    ]
    target.cSettings = (target.cSettings ?? []) + [
        .unsafeFlags(["-Werror"]),
    ]
    target.cxxSettings = (target.cxxSettings ?? []) + [
        .unsafeFlags(["-Werror"]),
    ]
}
