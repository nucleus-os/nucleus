// swift-tools-version:6.4

import PackageDescription

let package = Package(
    name: "NucleusLinuxDesktopPackage",
    products: [
        .library(
            name: "NucleusLinuxDesktop",
            type: .dynamic,
            targets: [
                "NucleusLinuxAccessibility",
                "NucleusLinuxEnvironment",
            ]),
        .executable(
            name: "NucleusLinuxBenchmarks",
            targets: ["NucleusLinuxBenchmarks"]),
    ],
    dependencies: [
        .package(name: "Nucleus", path: "../../core"),
        .package(name: "NucleusLinuxPlatform", path: ".."),
    ],
    targets: [
        .target(
            name: "NucleusLinuxAccessibility",
            dependencies: [
                .product(name: "Nucleus", package: "Nucleus"),
                .product(
                    name: "NucleusLinux",
                    package: "NucleusLinuxPlatform"),
            ],
            path: "Sources/NucleusLinuxAccessibility",
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .strictMemorySafety(),
            ]),
        .target(
            name: "NucleusLinuxEnvironment",
            dependencies: [
                .product(name: "Nucleus", package: "Nucleus"),
                .product(
                    name: "NucleusLinux",
                    package: "NucleusLinuxPlatform"),
            ],
            path: "Sources/NucleusLinuxEnvironment",
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .strictMemorySafety(),
            ]),
        .executableTarget(
            name: "NucleusLinuxBenchmarks",
            dependencies: [
                "NucleusLinuxAccessibility",
                .product(name: "Nucleus", package: "Nucleus"),
                .product(
                    name: "NucleusBenchmarkSupport",
                    package: "Nucleus"),
                .product(
                    name: "NucleusLinux",
                    package: "NucleusLinuxPlatform"),
            ],
            path: "Benchmarks/NucleusLinuxBenchmarks",
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags(["-enable-experimental-feature", "Lifetimes"]),
            ]),
        .testTarget(
            name: "NucleusLinuxAccessibilityTests",
            dependencies: [
                "NucleusLinuxAccessibility",
                .product(name: "Nucleus", package: "Nucleus"),
            ],
            path: "Tests/NucleusLinuxAccessibilityTests",
            swiftSettings: [.interoperabilityMode(.Cxx)],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "--no-as-needed"]),
            ]),
        .testTarget(
            name: "NucleusLinuxEnvironmentTests",
            dependencies: [
                "NucleusLinuxEnvironment",
                .product(name: "Nucleus", package: "Nucleus"),
            ],
            path: "Tests/NucleusLinuxEnvironmentTests",
            swiftSettings: [.interoperabilityMode(.Cxx)],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "--no-as-needed"]),
            ]),
    ]
)

for target in package.targets {
    target.swiftSettings = (target.swiftSettings ?? []) + [
        .strictMemorySafety(),
        .unsafeFlags(["-warnings-as-errors"]),
        .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
    ]
    target.cSettings = (target.cSettings ?? []) + [.unsafeFlags(["-Werror"])]
    target.cxxSettings =
        (target.cxxSettings ?? []) + [.unsafeFlags(["-Werror"])]
}
