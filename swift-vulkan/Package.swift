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
        // The generated typed API (VK.* dispatch tables, scoped enums /
        // option sets / typed handles) over the raw C module.
        .library(name: "Vulkan", targets: ["Vulkan"]),
        // The raw C module, vended separately because consumers import it directly
        // for the C structs / handles (VkImage, VkImportMemoryFdInfoKHR, …).
        .library(name: "VulkanC", targets: ["VulkanC"]),
    ],
    targets: [
        // The raw Vulkan C API. A systemLibrary (not a compiled C target) so the header
        // is processed at each import site — importers can inject platform defines like
        // -DVK_USE_PLATFORM_WAYLAND_KHR to pull the guarded WSI headers. Vendors the
        // Vulkan headers in its own dir (found via the systemLibrary's include path), so
        // no external -I is needed; the modulemap links the loader.
        .systemLibrary(
            name: "VulkanC",
            path: "Sources/VulkanC"
        ),
        // The generated Swift binding core (committed; regenerate on a headers bump
        // via `swift package generate-vulkan`).
        .target(
            name: "Vulkan",
            dependencies: ["VulkanC"]
        ),
        // vk.xml → Vulkan.swift generator + its command plugin.
        .executableTarget(name: "VulkanGen", path: "Tools/VulkanGen"),
        .plugin(
            name: "GenerateVulkan",
            capability: .command(
                intent: .custom(
                    verb: "generate-vulkan",
                    description: "Regenerate the Vulkan bindings from the vendored vk.xml"
                ),
                permissions: [.writeToPackageDirectory(reason: "Emit generated Vulkan.swift")]
            ),
            dependencies: ["VulkanGen"],
            path: "Plugins/GenerateVulkan"
        ),
        .testTarget(name: "VulkanTests", dependencies: ["Vulkan"]),
    ]
)
