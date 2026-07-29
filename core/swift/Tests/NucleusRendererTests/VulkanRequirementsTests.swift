import Testing
@testable import NucleusRenderer
import Vulkan
import VulkanC

@Suite("Vulkan WSI requirements")
struct VulkanRequirementsTests {
    @Test("Graphite WSI render targets carry its complete Vulkan usage contract")
    @MainActor
    func graphiteSwapchainImageUsage() {
        let usage = SwapchainPresenter.requiredImageUsage
        #expect(usage.contains(.colorAttachmentBit))
        #expect(usage.contains(.inputAttachmentBit))
        #expect(usage.contains(.transferDstBit))
    }

    @Test("Wayland presentation uses the shared Vulkan WSI contract")
    func waylandSwapchainRequirements() {
        let contract = VkRequirements.contract(
            for: .waylandSwapchain)
        let instance = contract.instanceExtensions
        let device = contract.deviceExtensions

        #expect(contract.minimumApiVersion == VkVersion(major: 1, minor: 4))
        #expect(contract.requiresTimelineSemaphore)
        #expect(!contract.requiresSynchronization2)
        #expect(contract.requiresSamplerYcbcrConversion)
        #expect(contract.requiresSwapchainMaintenance1)
        #expect(instance.contains("VK_KHR_surface"))
        #expect(instance.contains("VK_KHR_wayland_surface"))
        #expect(device.contains("VK_KHR_swapchain"))
        #expect(!device.contains("VK_KHR_external_memory_fd"))
        #expect(!device.contains("VK_EXT_external_memory_dma_buf"))
        #expect(!device.contains("VK_EXT_image_drm_format_modifier"))
        #expect(!device.contains("VK_KHR_external_semaphore_fd"))
        #expect(contract.requiredInstanceEntryPoints.contains(
            "vkCreateWaylandSurfaceKHR"))
        #expect(contract.requiredInstanceEntryPoints.contains(
            "vkGetPhysicalDeviceWaylandPresentationSupportKHR"))
        #expect(contract.requiredDeviceEntryPoints.contains(
            "vkQueuePresentKHR"))
    }

    @Test("Headless Graphite excludes every presentation and external-memory requirement")
    func headlessRequirements() {
        let contract = VkRequirements.contract(for: .headless)

        #expect(contract.presentation == .headless)
        #expect(contract.minimumApiVersion == VkVersion(major: 1, minor: 4))
        #expect(contract.requiresTimelineSemaphore)
        #expect(!contract.requiresSynchronization2)
        #expect(contract.requiresSamplerYcbcrConversion)
        #expect(!contract.requiresSwapchainMaintenance1)
        #expect(contract.instanceExtensions == ["VK_KHR_get_physical_device_properties2"])
        #expect(!contract.deviceExtensions.contains("VK_KHR_swapchain"))
        #expect(!contract.deviceExtensions.contains("VK_KHR_external_memory_fd"))
        #expect(!contract.deviceExtensions.contains("VK_EXT_external_memory_dma_buf"))
        #expect(!contract.deviceExtensions.contains("VK_EXT_image_drm_format_modifier"))
        #expect(!contract.requiredInstanceEntryPoints.contains {
            $0.contains("Surface")
        })
        #expect(!contract.requiredDeviceEntryPoints.contains {
            $0.contains("Swapchain") || $0.contains("MemoryFd")
                || $0.contains("SemaphoreFd")
        })
    }

    @Test("The queried and enabled feature chains have identical structure")
    func featureContractChain() {
        let contract = VkRequirements.contract(
            for: .waylandSwapchain)
        let enabled: (Bool, Bool, Bool, Bool)? =
            unsafe withRequiredFeatureEnableChain(contract: contract) { head in
            guard let v13Raw = unsafe head.pointee.pNext else { return nil }
            let v13 = unsafe v13Raw.assumingMemoryBound(
                to: VkPhysicalDeviceVulkan13Features.self)
            guard let v12Raw = unsafe v13.pointee.pNext else { return nil }
            let v12 = unsafe v12Raw.assumingMemoryBound(
                to: VkPhysicalDeviceVulkan12Features.self)
            guard let v11Raw = unsafe v12.pointee.pNext else { return nil }
            let v11 = unsafe v11Raw.assumingMemoryBound(
                to: VkPhysicalDeviceVulkan11Features.self)
            return (
                unsafe v13.pointee.synchronization2 != 0,
                unsafe v12.pointee.timelineSemaphore != 0,
                unsafe v11.pointee.samplerYcbcrConversion != 0,
                unsafe v11.pointee.pNext == nil)
        }
        #expect(enabled?.0 == false)
        #expect(enabled?.1 == true)
        #expect(enabled?.2 == true)
        #expect(enabled?.3 == false)

        let queried: (Bool, Bool, Bool, Bool)? =
            unsafe withRequiredFeatureQueryChain(contract: contract) { head in
            guard let v13Raw = unsafe head.pointee.pNext else { return nil }
            let v13 = unsafe v13Raw.assumingMemoryBound(
                to: VkPhysicalDeviceVulkan13Features.self)
            guard let v12Raw = unsafe v13.pointee.pNext else { return nil }
            let v12 = unsafe v12Raw.assumingMemoryBound(
                to: VkPhysicalDeviceVulkan12Features.self)
            guard let v11Raw = unsafe v12.pointee.pNext else { return nil }
            let v11 = unsafe v11Raw.assumingMemoryBound(
                to: VkPhysicalDeviceVulkan11Features.self)
            return (
                unsafe v13.pointee.synchronization2 == 0,
                unsafe v12.pointee.timelineSemaphore == 0,
                unsafe v11.pointee.samplerYcbcrConversion == 0,
                unsafe v11.pointee.pNext == nil)
        }
        #expect(queried?.0 == true)
        #expect(queried?.1 == true)
        #expect(queried?.2 == true)
        #expect(queried?.3 == false)
    }
}
