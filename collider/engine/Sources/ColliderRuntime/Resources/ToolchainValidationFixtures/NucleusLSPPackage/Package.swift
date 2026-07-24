// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "NucleusLSPPackage",
    products: [.library(name: "Greeter", targets: ["Greeter"])],
    targets: [
        .target(name: "Greeter"),
        .executableTarget(name: "App", dependencies: ["Greeter"]),
    ]
)
