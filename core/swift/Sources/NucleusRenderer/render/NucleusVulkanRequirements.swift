// Phase 10b.2 — the single Swift source of truth for the Vulkan instance/device
// extensions and modern features Nucleus requires. Device creation fails closed
// when a required feature is absent (no silent fallback).

import VulkanC
import Vulkan

public enum VkRequirements {
    /// How the render core presents. Selects the Vulkan WSI vs. DRM/dmabuf extension set at
    /// device creation. `platformDefault` keeps the built-in behavior (Android WSI / Linux
    /// DRM); `waylandClientWSI` is an out-of-process Wayland client (nucleus-shell) that
    /// presents onto a client wl_surface via a swapchain — same Linux OS, but WSI not DRM.
    public enum PresentationMode: Sendable {
        case platformDefault
        case waylandClientWSI
    }

    /// The complete, non-negotiable Vulkan contract for one presentation
    /// architecture. A physical device is selectable only when every extension,
    /// feature, entry point, API-version, and queue requirement is satisfied.
    public struct Contract: Sendable {
        public let presentation: PresentationMode
        public let minimumApiVersion: VkVersion
        public let instanceExtensions: [String]
        public let deviceExtensions: [String]
        public let requiredInstanceEntryPoints: [String]
        public let requiredDeviceEntryPoints: [String]
        public let requiresTimelineSemaphore: Bool
        public let requiresSamplerYcbcrConversion: Bool
        public let requiresSwapchainMaintenance1: Bool
    }

    public static func contract(for mode: PresentationMode = .platformDefault) -> Contract {
        let wsi: Bool
        switch mode {
        case .waylandClientWSI: wsi = true
        case .platformDefault:
            #if os(Android)
            wsi = true
            #else
            wsi = false
            #endif
        }
        let commonDeviceEntryPoints = [
            "vkAllocateMemory", "vkBindImageMemory", "vkBindImageMemory2",
            "vkCreateBuffer", "vkCreateCommandPool", "vkCreateDescriptorPool",
            "vkCreateFence", "vkCreateImage", "vkCreateImageView",
            "vkCreatePipelineLayout", "vkCreateSemaphore", "vkDestroyBuffer",
            "vkDestroyCommandPool", "vkDestroyDescriptorPool", "vkDestroyDevice",
            "vkDestroyFence", "vkDestroyImage", "vkDestroyImageView",
            "vkDestroyPipelineLayout", "vkDestroySemaphore", "vkFreeMemory", "vkGetDeviceQueue",
            "vkGetFenceStatus", "vkGetImageMemoryRequirements",
            "vkGetImageMemoryRequirements2", "vkQueueSubmit", "vkQueueWaitIdle",
            "vkResetFences", "vkWaitForFences",
        ]
        let wsiDeviceEntryPoints = [
            "vkAcquireNextImageKHR", "vkCreateSwapchainKHR", "vkDestroySwapchainKHR",
            "vkGetSwapchainImagesKHR", "vkQueuePresentKHR", "vkReleaseSwapchainImagesKHR",
        ]
        let drmDeviceEntryPoints = [
            "vkGetMemoryFdPropertiesKHR", "vkGetSemaphoreFdKHR", "vkImportSemaphoreFdKHR",
        ]
        let commonInstanceEntryPoints = [
            "vkCreateDevice", "vkDestroyInstance", "vkEnumerateDeviceExtensionProperties",
            "vkEnumeratePhysicalDevices", "vkGetDeviceProcAddr", "vkGetPhysicalDeviceFeatures2",
            "vkGetPhysicalDeviceFormatProperties2", "vkGetPhysicalDeviceProperties",
            "vkGetPhysicalDeviceQueueFamilyProperties",
        ]
        let wsiInstanceEntryPoints = [
            "vkDestroySurfaceKHR", "vkGetPhysicalDeviceSurfaceCapabilitiesKHR",
            "vkGetPhysicalDeviceSurfaceFormatsKHR", "vkGetPhysicalDeviceSurfaceSupportKHR",
        ]
        return Contract(
            presentation: mode,
            minimumApiVersion: minimumApiVersion,
            instanceExtensions: instanceExtensions(for: mode),
            deviceExtensions: deviceExtensions(for: mode),
            requiredInstanceEntryPoints: commonInstanceEntryPoints + (wsi ? wsiInstanceEntryPoints : []),
            requiredDeviceEntryPoints: commonDeviceEntryPoints
                + (wsi ? wsiDeviceEntryPoints : drmDeviceEntryPoints),
            requiresTimelineSemaphore: true,
            requiresSamplerYcbcrConversion: true,
            requiresSwapchainMaintenance1: wsi)
    }

    /// Instance extensions required to create the Nucleus instance. Android adds the WSI
    /// surface pair so the swapchain presenter can create an `ANativeWindow` surface; the
    /// Wayland client mode adds `VK_KHR_surface` + `VK_KHR_wayland_surface`; the Linux
    /// compositor presents through DRM/KMS and needs no instance WSI extension.
    public static func instanceExtensions(for mode: PresentationMode = .platformDefault) -> [String] {
        var exts = [
            VK.Ext.khrGetPhysicalDeviceProperties2,
            VK.Ext.khrExternalMemoryCapabilities,
            VK.Ext.khrExternalSemaphoreCapabilities,
        ]
        switch mode {
        case .waylandClientWSI:
            exts += [VK.Ext.khrSurface, VK.Ext.khrSurfaceMaintenance1, VK.Ext.khrWaylandSurface]
        case .platformDefault:
            #if os(Android)
            exts += [VK.Ext.khrSurface, VK.Ext.khrSurfaceMaintenance1, VK.Ext.khrAndroidSurface]
            #endif
        }
        return exts
    }

    /// Device extensions required for presentation + GPU resource sharing. The Linux
    /// compositor imports client DMA-BUFs with explicit sync into DRM-modifier scanout
    /// images; the Android and Wayland-client swapchain paths have neither dmabuf import nor
    /// DRM modifiers, so they require only the swapchain + the portable memory/sync set.
    public static func deviceExtensions(for mode: PresentationMode = .platformDefault) -> [String] {
        let swapchainSet: [String] = [
            VK.Ext.khrSwapchain,
            VK.Ext.khrSwapchainMaintenance1,
            VK.Ext.khrTimelineSemaphore,
            VK.Ext.khrGetMemoryRequirements2,
            VK.Ext.khrSamplerYcbcrConversion,
            VK.Ext.khrBindMemory2,
            VK.Ext.khrMaintenance1,
            VK.Ext.khrMaintenance3,
        ]
        switch mode {
        case .waylandClientWSI:
            return swapchainSet
        case .platformDefault:
            #if os(Android)
            return swapchainSet
            #else
            return [
                VK.Ext.khrExternalMemoryFd,
                VK.Ext.extExternalMemoryDmaBuf,
                VK.Ext.extImageDrmFormatModifier,
                VK.Ext.khrExternalSemaphoreFd,
                VK.Ext.khrTimelineSemaphore,
                VK.Ext.khrGetMemoryRequirements2,
                VK.Ext.khrSamplerYcbcrConversion,
                VK.Ext.khrBindMemory2,
                VK.Ext.khrMaintenance1,
                VK.Ext.khrMaintenance3,
                VK.Ext.extQueueFamilyForeign,
            ]
            #endif
        }
    }

    /// The minimum core feature level the device must advertise.
    public static let minimumApiVersion = VkVersion(major: 1, minor: 4)

}

/// A packed Vulkan API version (`VK_MAKE_API_VERSION`). Stored as the raw u32 the
/// API uses; `major`/`minor`/`patch` decode the bitfields.
public struct VkVersion: Equatable, Comparable, Sendable {
    public var raw: UInt32
    public init(raw: UInt32) { self.raw = raw }
    public init(variant: UInt32 = 0, major: UInt32, minor: UInt32, patch: UInt32 = 0) {
        self.raw = (variant << 29) | (major << 22) | (minor << 12) | patch
    }
    public var major: UInt32 { (raw >> 22) & 0x7F }
    public var minor: UInt32 { (raw >> 12) & 0x3FF }
    public var patch: UInt32 { raw & 0xFFF }
    public static func < (a: VkVersion, b: VkVersion) -> Bool { a.raw < b.raw }
}
