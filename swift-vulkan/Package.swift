// swift-tools-version:6.4
import PackageDescription

// swift-vulkan — self-contained Swift bindings for the Vulkan API, generated from
// the Khronos registry (vk.xml) by the VulkanGen tool. No WSI is pulled on Linux
// core; the Android / Wayland surface extensions are behind platform guards in the
// C module. The Vulkan headers are vendored (Sources/VulkanC/vulkan,
// KhronosGroup/Vulkan-Headers v1.4.350), so nothing depends on a system SDK or on
// any other build tree.
let package = Package(
    name: "swift-vulkan",
    products: [
        .library(name: "VulkanColliderRecipe", targets: ["VulkanColliderRecipe"]),
        // The generated typed API (VK.* dispatch tables, scoped enums /
        // option sets / typed handles) over the raw C module.
        .library(name: "Vulkan", targets: ["Vulkan"]),
        // The raw C module, vended separately because consumers import it directly
        // for the C structs / handles (VkImage, VkImportMemoryFdInfoKHR, …).
        .library(name: "VulkanC", targets: ["VulkanC"]),
    ],
    dependencies: [.package(path: "../collider")],
    targets: [
        .target(
            name: "VulkanColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "collider")]),
        // The raw Vulkan C API. A systemLibrary (not a compiled C target) so the header
        // is processed at each import site — importers can inject platform defines like
        // -DVK_USE_PLATFORM_WAYLAND_KHR to pull the guarded WSI headers. Vendors the
        // Vulkan headers in its own dir (found via the systemLibrary's include path), so
        // no external -I is needed; the modulemap links the loader.
        .systemLibrary(
            name: "VulkanC",
            path: "Sources/VulkanC"
        ),
        // The generated Swift binding core. Collider invokes VulkanGen directly
        // when the vendored registry changes.
        .target(
            name: "Vulkan",
            dependencies: ["VulkanC"]
        ),
        // vk.xml → Vulkan.swift generator invoked by `collider generate vulkan`.
        .executableTarget(name: "VulkanGen", path: "Tools/VulkanGen"),
        .testTarget(name: "VulkanTests", dependencies: ["Vulkan"]),
    ]
)


for target in package.targets {
    switch target.type {
    case .regular, .executable, .test:
        break
    default:
        continue
    }
    var swiftSettings = (target.swiftSettings ?? []) + [
        .unsafeFlags(["-warnings-as-errors"]),
        .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
    ]
    if let feature = Context.environment["NUCLEUS_SWIFT_DIAGNOSTIC_FEATURE"] {
        swiftSettings.append(.unsafeFlags(["-enable-upcoming-feature", feature]))
    }
    target.swiftSettings = swiftSettings
    target.cSettings = (target.cSettings ?? []) + [
        .unsafeFlags(["-Werror"]),
    ]
    target.cxxSettings = (target.cxxSettings ?? []) + [
        .unsafeFlags(["-Werror"]),
    ]
}
