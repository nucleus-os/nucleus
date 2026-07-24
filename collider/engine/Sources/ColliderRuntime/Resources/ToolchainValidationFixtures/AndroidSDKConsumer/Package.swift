// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "AndroidSDKConsumer",
    products: [.executable(name: "hello", targets: ["hello"])],
    targets: [
        .executableTarget(
            name: "hello",
            swiftSettings: [.interoperabilityMode(.Cxx)],
            plugins: ["FoundationXMLHostPlugin"]),
        .plugin(name: "FoundationXMLHostPlugin", capability: .buildTool()),
    ]
)
