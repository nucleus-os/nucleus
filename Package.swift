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
