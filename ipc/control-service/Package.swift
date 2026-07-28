// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "NucleusControlServiceExecutable",
    products: [
        .executable(
            name: "NucleusControlService",
            targets: ["NucleusControlServiceExecutable"]),
    ],
    dependencies: [
        .package(
            name: "NucleusControlServicePackage",
            path: "../control-service-core"),
    ],
    targets: [
        .executableTarget(
            name: "NucleusControlServiceExecutable",
            dependencies: [
                .product(
                    name: "NucleusControlService",
                    package: "NucleusControlServicePackage"),
            ],
            swiftSettings: [
                .strictMemorySafety(),
                .unsafeFlags(["-warnings-as-errors"]),
                .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
            ]),
    ]
)
