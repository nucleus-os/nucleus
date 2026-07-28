// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "SwiftWaylandProtocolRuntime",
    products: [
        .library(
            name: "SwiftWaylandProtocolRuntime",
            type: .dynamic,
            targets: [
                "SwiftWaylandProtocolRuntime",
                "WaylandProtocolTypes",
                "WaylandProtocolsC",
            ]),
    ],
    targets: [
        .systemLibrary(
            name: "WaylandUtilC",
            path: "Sources/WaylandUtilC",
            pkgConfig: "wayland-client"),
        .target(
            name: "WaylandProtocolsC",
            dependencies: ["WaylandUtilC"]),
        .target(
            name: "WaylandProtocolTypes",
            swiftSettings: [
                .strictMemorySafety(),
                .unsafeFlags(["-warnings-as-errors"]),
                .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
            ]),
        .target(
            name: "SwiftWaylandProtocolRuntime",
            dependencies: ["WaylandProtocolTypes"],
            swiftSettings: [
                .strictMemorySafety(),
                .unsafeFlags(["-warnings-as-errors"]),
                .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
            ]),
    ]
)
