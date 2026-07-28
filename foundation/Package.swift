// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NucleusFoundation",
    products: [
        .library(
            name: "NucleusFoundation",
            type: .dynamic,
            targets: ["NucleusFoundation"]),
    ],
    targets: [
        .target(
            name: "NucleusTypes",
            path: "Sources/NucleusTypes",
            swiftSettings: [.strictMemorySafety()]),
        .target(
            name: "NucleusDiagnostics",
            path: "Sources/NucleusDiagnostics",
            swiftSettings: [.strictMemorySafety()]),
        .target(
            name: "NucleusAppHostProtocols",
            dependencies: ["NucleusTypes"],
            path: "Sources/NucleusAppHostProtocols",
            swiftSettings: [.strictMemorySafety()]),
        .target(
            name: "NucleusFoundation",
            dependencies: [
                "NucleusTypes",
                "NucleusDiagnostics",
                "NucleusAppHostProtocols",
            ],
            path: "Sources/NucleusFoundation",
            swiftSettings: [.strictMemorySafety()]),
    ])

for target in package.targets {
    target.swiftSettings = (target.swiftSettings ?? []) + [
        .unsafeFlags(["-warnings-as-errors"]),
        .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
    ]
}
