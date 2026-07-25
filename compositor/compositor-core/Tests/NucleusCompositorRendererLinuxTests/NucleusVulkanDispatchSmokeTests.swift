import Testing
@testable import NucleusRenderer
import VulkanC
import Vulkan

// Converted from NucleusVulkanDispatchSmoke: bootstrap the base dispatch table
// from the linked loader, call typed global commands, drive the checked
// enumeration helper, and confirm the extension/feature inventories + that the
// instance/device dispatch table types compile. All hardware-independent —
// exercised against the real loader with no instance + no GPU.
@Suite struct NucleusVulkanDispatchSmokeTests {
    @Test func gpuLoader_baseDispatchAndGlobals() throws {
        // Base dispatch table loads from the linked loader; core globals resolve.
        let base = VK.loadBaseDispatch()
        let enumerateVersion = try requireValue(
            base.vkEnumerateInstanceVersion,
            "Vulkan loader is missing vkEnumerateInstanceVersion")
        _ = try requireValue(
            base.vkCreateInstance,
            "Vulkan loader is missing vkCreateInstance")
        let enumerateExtensions = try requireValue(
            base.vkEnumerateInstanceExtensionProperties,
            "Vulkan loader is missing vkEnumerateInstanceExtensionProperties")
        let enumerateLayers = try requireValue(
            base.vkEnumerateInstanceLayerProperties,
            "Vulkan loader is missing vkEnumerateInstanceLayerProperties")

        // Typed call through the dispatch table.
        var version: UInt32 = 0
        let vr = enumerateVersion(&version)
        #expect(vr == VK_SUCCESS, "enumerate-version-result")
        #expect(version != 0, "enumerate-version-nonzero")
        let major = (version >> 22) & 0x7F
        #expect(major >= 1, "version-major-ge-1")

        // Checked enumeration helper over the two-call protocol.
        let exts = VkEnumerate.array { count, out in
            enumerateExtensions(nil, count, out)
        }
        let extensions = try requireValue(
            exts, "Vulkan instance-extension enumeration failed")
        // Each VkExtensionProperties carries a NUL-terminated C name array.
        for ext in extensions.prefix(1) {
            let name = withUnsafeBytes(of: ext.extensionName) { raw -> String in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            #expect(!name.isEmpty && name.hasPrefix("VK_"), "ext-name-shape")
        }

        // Layer enumeration via the same helper (commonly empty).
        let layers = VkEnumerate.array { count, out in
            enumerateLayers(count, out)
        }
        _ = try requireValue(layers, "Vulkan layer enumeration failed")

        #expect(throws: VulkanLaneTestFailure.self) {
            _ = try requireValue(
                vkGetInstanceProcAddr(
                    nil, "vkNucleusDeliberatelyMissingLoaderSymbol"),
                "Vulkan loader did not resolve the deliberately missing symbol")
        }
    }

    @Test func inventoriesAndDispatchTypes() {
        // Extension + feature inventories.
        #expect(VK.Ext.khrSwapchain == "VK_KHR_swapchain", "inventory-ext-swapchain")
        #expect(VK.Ext.khrExternalMemoryFd == "VK_KHR_external_memory_fd", "inventory-ext-extmem-fd")
        #expect(VK.featureLevels.contains { $0.major == 1 && $0.minor == 0 }, "inventory-feature-1-0")
        #expect(VK.featureLevels.contains { $0.major == 1 && $0.minor == 3 }, "inventory-feature-1-3")
        #expect(VK.featureLevels.count >= 4, "inventory-feature-count")

        // Instance/device dispatch tables are well-formed Swift types.
        #expect(MemoryLayout<VK.InstanceDispatch>.size > 0, "instance-dispatch-type")
        #expect(MemoryLayout<VK.DeviceDispatch>.size > 0, "device-dispatch-type")
    }
}
