// extensions and modern features Nucleus requires. Device creation fails closed
// when a required feature is absent (no silent fallback).

import VulkanC
import Vulkan

public enum VkRequirements {
    /// How the render core presents. Selects the process-local presentation
    /// contract at device creation. `platformDefault` is Android WSI or Linux
    /// DRM import/scanout. `waylandSwapchain` is an out-of-process Wayland
    /// client whose Vulkan driver owns presentation and explicit synchronization
    /// through `VK_KHR_wayland_surface`.
    /// `headless` creates Graphite without any presentation or external-memory contract and
    /// is the mandatory software-device test architecture.
    public enum PresentationMode: Sendable, Equatable {
        case platformDefault
        case waylandSwapchain
        case headless
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
        public let requiresSynchronization2: Bool
        public let requiresSamplerYcbcrConversion: Bool
        public let requiresSwapchainMaintenance1: Bool
    }

    public static func contract(for mode: PresentationMode = .platformDefault) -> Contract {
        let presentationEntryPoints: [String]
        switch mode {
        case .waylandSwapchain:
            presentationEntryPoints = [
                "vkAcquireNextImageKHR", "vkCreateSwapchainKHR",
                "vkDestroySwapchainKHR", "vkGetSwapchainImagesKHR",
                "vkQueuePresentKHR", "vkReleaseSwapchainImagesKHR",
            ]
        case .platformDefault:
            #if os(Android)
            presentationEntryPoints = [
                "vkAcquireNextImageKHR", "vkCreateSwapchainKHR", "vkDestroySwapchainKHR",
                "vkGetSwapchainImagesKHR", "vkQueuePresentKHR", "vkReleaseSwapchainImagesKHR",
            ]
            #else
            presentationEntryPoints = [
                "vkGetMemoryFdPropertiesKHR", "vkGetSemaphoreFdKHR", "vkImportSemaphoreFdKHR",
            ]
            #endif
        case .headless:
            presentationEntryPoints = []
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
        let platformInstanceEntryPoints: [String]
        let requiresWSI: Bool
        switch mode {
        case .waylandSwapchain:
            requiresWSI = true
            platformInstanceEntryPoints = [
                "vkCreateWaylandSurfaceKHR",
                "vkGetPhysicalDeviceWaylandPresentationSupportKHR",
            ]
        case .platformDefault:
            #if os(Android)
            requiresWSI = true
            platformInstanceEntryPoints = [
                "vkCreateAndroidSurfaceKHR",
            ]
            #else
            requiresWSI = false
            platformInstanceEntryPoints = []
            #endif
        case .headless:
            requiresWSI = false
            platformInstanceEntryPoints = []
        }
        return Contract(
            presentation: mode,
            minimumApiVersion: minimumApiVersion,
            instanceExtensions: instanceExtensions(for: mode),
            deviceExtensions: deviceExtensions(for: mode),
            requiredInstanceEntryPoints: commonInstanceEntryPoints
                + (requiresWSI ? wsiInstanceEntryPoints : [])
                + platformInstanceEntryPoints,
            requiredDeviceEntryPoints: commonDeviceEntryPoints + presentationEntryPoints,
            requiresTimelineSemaphore: true,
            requiresSynchronization2: false,
            requiresSamplerYcbcrConversion: true,
            requiresSwapchainMaintenance1: requiresWSI)
    }

    /// Instance extensions required to create the Nucleus instance.
    public static func instanceExtensions(for mode: PresentationMode = .platformDefault) -> [String] {
        var exts = [
            VK.Ext.khrGetPhysicalDeviceProperties2,
            VK.Ext.khrExternalMemoryCapabilities,
            VK.Ext.khrExternalSemaphoreCapabilities,
        ]
        switch mode {
        case .waylandSwapchain:
            exts += [
                VK.Ext.khrSurface,
                VK.Ext.khrGetSurfaceCapabilities2,
                VK.Ext.khrSurfaceMaintenance1,
                VK.Ext.khrWaylandSurface,
            ]
        case .platformDefault:
            #if os(Android)
            exts += [
                VK.Ext.khrSurface,
                VK.Ext.khrGetSurfaceCapabilities2,
                VK.Ext.khrSurfaceMaintenance1,
                VK.Ext.khrAndroidSurface,
            ]
            #endif
        case .headless:
            return [VK.Ext.khrGetPhysicalDeviceProperties2]
        }
        return exts
    }

    /// Device extensions required for presentation + GPU resource sharing.
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
        case .waylandSwapchain:
            return swapchainSet
        case .platformDefault:
            #if os(Android)
            return swapchainSet
            #else
            return [
                VK.Ext.khrExternalMemoryFd,
                VK.Ext.extExternalMemoryDmaBuf,
                VK.Ext.extImageDrmFormatModifier,
                VK.Ext.extPhysicalDeviceDrm,
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
        case .headless:
            return [
                VK.Ext.khrTimelineSemaphore,
                VK.Ext.khrGetMemoryRequirements2,
                VK.Ext.khrSamplerYcbcrConversion,
                VK.Ext.khrBindMemory2,
                VK.Ext.khrMaintenance1,
                VK.Ext.khrMaintenance3,
            ]
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
