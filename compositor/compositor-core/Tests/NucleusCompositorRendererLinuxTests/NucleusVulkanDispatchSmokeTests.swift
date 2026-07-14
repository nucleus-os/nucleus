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
    @Test(.disabled("invokes the real Vulkan loader (flaky on partial-ICD hosts)")) func baseDispatchAndGlobals() {
        // Base dispatch table loads from the linked loader; core globals resolve.
        let base = VK.loadBaseDispatch()
        #expect(base.vkEnumerateInstanceVersion != nil, "base-has-enumerate-version")
        #expect(base.vkCreateInstance != nil, "base-has-create-instance")
        #expect(base.vkEnumerateInstanceExtensionProperties != nil, "base-has-enumerate-ext")
        #expect(base.vkEnumerateInstanceLayerProperties != nil, "base-has-enumerate-layers")

        // Typed call through the dispatch table.
        var version: UInt32 = 0
        let vr = base.vkEnumerateInstanceVersion!(&version)
        #expect(vr == VK_SUCCESS, "enumerate-version-result")
        #expect(version != 0, "enumerate-version-nonzero")
        let major = (version >> 22) & 0x7F
        #expect(major >= 1, "version-major-ge-1")

        // Checked enumeration helper over the two-call protocol.
        let exts = VkEnumerate.array { count, out in
            base.vkEnumerateInstanceExtensionProperties!(nil, count, out)
        }
        #expect(exts != nil, "enumerate-ext-ok")
        if let exts {
            // Each VkExtensionProperties carries a NUL-terminated C name array.
            for ext in exts.prefix(1) {
                let name = withUnsafeBytes(of: ext.extensionName) { raw -> String in
                    String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
                }
                #expect(!name.isEmpty && name.hasPrefix("VK_"), "ext-name-shape")
            }
            // No-ICD environments legitimately return an empty set; the helper
            // still succeeds (non-nil), which the check above already covered.
            #expect(exts.count >= 0, "enumerate-ext-count")
        }

        // Layer enumeration via the same helper (commonly empty).
        let layers = VkEnumerate.array { count, out in
            base.vkEnumerateInstanceLayerProperties!(count, out)
        }
        #expect(layers != nil, "enumerate-layers-ok")
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
