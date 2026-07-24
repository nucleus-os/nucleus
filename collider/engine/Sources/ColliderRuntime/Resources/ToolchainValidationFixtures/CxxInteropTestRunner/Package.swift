// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "CxxInteropTestRunner",
    products: [.library(name: "Example", targets: ["Example"])],
    targets: [
        .target(name: "Example"),
        .testTarget(
            name: "ExampleTests",
            dependencies: ["Example"],
            swiftSettings: [.interoperabilityMode(.Cxx)]),
    ]
)
