// swift-tools-version:6.4

import PackageDescription

let package = Package(
    name: "NucleusConfigServiceExecutablePackage",
    products: [
        .executable(
            name: "NucleusConfigService",
            targets: ["NucleusConfigServiceExecutable"]),
    ],
    dependencies: [
        .package(
            name: "NucleusConfigServicePackage",
            path: "../config-service-core"),
    ],
    targets: [
        .executableTarget(
            name: "NucleusConfigServiceExecutable",
            dependencies: [
                .product(
                    name: "NucleusConfigService",
                    package: "NucleusConfigServicePackage"),
            ])
    ]
)

for target in package.targets {
    target.swiftSettings = (target.swiftSettings ?? []) + [
        .strictMemorySafety(),
        .unsafeFlags(["-warnings-as-errors"]),
        .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
    ]
    target.cSettings = (target.cSettings ?? []) + [.unsafeFlags(["-Werror"])]
}
