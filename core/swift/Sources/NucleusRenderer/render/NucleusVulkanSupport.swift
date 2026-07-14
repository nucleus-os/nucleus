// Nucleus-specific Vulkan support.
//
// The generic ergonomic helpers (VK.loadBaseDispatch, VkEnumerate, VkOwned,
// VkOwnedImageBox, withCStringArray, device-child constructors) live in the
// swift-vulkan package (VulkanErgonomics.swift) and are re-exported by this
// module transitively through `import Vulkan`.

// Re-export Vulkan module symbols so downstream consumers of NucleusRenderer
// get the ergonomics without importing Vulkan directly.
@_exported import Vulkan
