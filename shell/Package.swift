// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "NucleusShell",
    products: [
        .library(
            name: "ShellColliderRecipe",
            targets: ["ShellColliderRecipe"]),
    ],
    dependencies: [
        .package(path: "../collider/engine"),
        .package(
            name: "NucleusShellKitPackage",
            path: "shell-kit"),
        .package(
            name: "NucleusShellAuthWirePackage",
            path: "auth-wire"),
    ],
    targets: [
        .target(
            name: "ShellColliderRecipe",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
            ]),
        .systemLibrary(
            name: "NucleusShellPamC",
            path: "Sources/NucleusShellPamC"),
        .executableTarget(
            name: "NucleusShellPamHelper",
            dependencies: [
                .product(
                    name: "NucleusShellAuthWire",
                    package: "NucleusShellAuthWirePackage"),
                "NucleusShellPamC",
            ],
            path: "Sources/NucleusShellPamHelper",
            swiftSettings: [.interoperabilityMode(.Cxx)],
            linkerSettings: [.unsafeFlags(["-lpam"])]),
        .executableTarget(
            name: "NucleusShellThreadSanitizerHarness",
            dependencies: [
                .product(
                    name: "NucleusShellKit",
                    package: "NucleusShellKitPackage"),
            ],
            path:
                "SanitizerHarnesses/NucleusShellThreadSanitizerHarness",
            swiftSettings: [.interoperabilityMode(.Cxx)]),
        .executableTarget(
            name: "NucleusShell",
            dependencies: [
                .product(
                    name: "NucleusShellKit",
                    package: "NucleusShellKitPackage"),
            ],
            path: "Sources/NucleusShell",
            swiftSettings: [.interoperabilityMode(.Cxx)]),
    ])

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
    if let feature = Context.environment[
        "NUCLEUS_SWIFT_DIAGNOSTIC_FEATURE"
    ] {
        swiftSettings.append(.unsafeFlags([
            "-enable-upcoming-feature", feature,
        ]))
    }
    target.swiftSettings = swiftSettings
    target.cSettings = (target.cSettings ?? []) + [
        .unsafeFlags(["-Werror"]),
    ]
    target.cxxSettings = (target.cxxSettings ?? []) + [
        .unsafeFlags(["-Werror"]),
    ]
}
