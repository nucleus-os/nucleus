// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "NucleusShellAuthWirePackage",
    products: [
        .library(
            name: "NucleusShellAuthWire",
            targets: ["NucleusShellAuthWire"]),
    ],
    targets: [
        .target(
            name: "NucleusShellAuthWire",
            path: "Sources/NucleusShellAuthWire"),
        .testTarget(
            name: "NucleusShellAuthWireTests",
            dependencies: ["NucleusShellAuthWire"],
            path: "Tests/NucleusShellInputTests"),
    ])

for target in package.targets {
    target.swiftSettings = (target.swiftSettings ?? []) + [
        .strictMemorySafety(),
        .unsafeFlags(["-warnings-as-errors"]),
        .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
    ]
}
