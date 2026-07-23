// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NucleusWorkspace",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "nucleus-workspace", targets: ["NucleusWorkspace"]),
    ],
    dependencies: [
        .package(name: "NucleusLinuxPlatform", path: "platform-linux"),
    ],
    targets: [
        .executableTarget(
            name: "NucleusWorkspace",
            dependencies: [
                .product(
                    name: "NucleusLinuxSession",
                    package: "NucleusLinuxPlatform"),
            ]),
        .testTarget(
            name: "NucleusWorkspaceTests",
            dependencies: [
                "NucleusWorkspace",
                .product(
                    name: "NucleusLinuxSession",
                    package: "NucleusLinuxPlatform"),
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
