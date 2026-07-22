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

    @Test("Wayland WSI hard-requires swapchain maintenance")
    func waylandMaintenanceRequirements() {
        let contract = VkRequirements.contract(for: .waylandClientWSI)
        let instance = contract.instanceExtensions
        let device = contract.deviceExtensions

        #expect(contract.minimumApiVersion == VkVersion(major: 1, minor: 4))
        #expect(contract.requiresTimelineSemaphore)
        #expect(contract.requiresSamplerYcbcrConversion)
        #expect(contract.requiresSwapchainMaintenance1)
        #expect(instance.contains("VK_KHR_surface"))
        #expect(instance.contains("VK_KHR_surface_maintenance1"))
        #expect(instance.contains("VK_KHR_wayland_surface"))
        #expect(device.contains("VK_KHR_swapchain"))
        #expect(device.contains("VK_KHR_swapchain_maintenance1"))
        #expect(contract.requiredDeviceEntryPoints.contains("vkReleaseSwapchainImagesKHR"))
    }

    @Test("The queried and enabled feature chains have identical structure")
    func featureContractChain() {
        let contract = VkRequirements.contract(for: .waylandClientWSI)
        withRequiredFeatureChain(contract: contract) { head in
            guard let v12Raw = head.pointee.pNext else {
                Issue.record("missing Vulkan 1.2 feature link")
                return
            }
            let v12 = v12Raw.assumingMemoryBound(to: VkPhysicalDeviceVulkan12Features.self)
            #expect(v12.pointee.timelineSemaphore != 0)
            guard let v11Raw = v12.pointee.pNext else {
                Issue.record("missing Vulkan 1.1 feature link")
                return
            }
            let v11 = v11Raw.assumingMemoryBound(to: VkPhysicalDeviceVulkan11Features.self)
            #expect(v11.pointee.samplerYcbcrConversion != 0)
            guard let maintenanceRaw = v11.pointee.pNext else {
                Issue.record("missing swapchain-maintenance feature link")
                return
            }
            let maintenance = maintenanceRaw.assumingMemoryBound(
                to: VkPhysicalDeviceSwapchainMaintenance1FeaturesKHR.self)
            #expect(maintenance.pointee.swapchainMaintenance1 != 0)
        }
        withRequiredFeatureChain(
            contract: contract, enableRequiredFeatures: false
        ) { head in
            let v12 = head.pointee.pNext!.assumingMemoryBound(
                to: VkPhysicalDeviceVulkan12Features.self)
            #expect(v12.pointee.timelineSemaphore == 0)
            let v11 = v12.pointee.pNext!.assumingMemoryBound(
                to: VkPhysicalDeviceVulkan11Features.self)
            #expect(v11.pointee.samplerYcbcrConversion == 0)
            let maintenance = v11.pointee.pNext!.assumingMemoryBound(
                to: VkPhysicalDeviceSwapchainMaintenance1FeaturesKHR.self)
            #expect(maintenance.pointee.swapchainMaintenance1 == 0)
        }
    }
}
