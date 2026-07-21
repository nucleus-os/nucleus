// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NucleusWorkspace",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "nucleus-workspace", targets: ["NucleusWorkspace"]),
    ],
    targets: [
        .executableTarget(name: "NucleusWorkspace"),
        .testTarget(name: "NucleusWorkspaceTests", dependencies: ["NucleusWorkspace"]),
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
