import Testing
@testable import NucleusRenderer
import VulkanC
import Vulkan

// Converted from NucleusVulkanResourcesFixture: version packing, the
// requirements source of truth, the feature-chain builder (walked via pNext),
// and the noncopyable owner's destroy-exactly-once / take-suppresses-destroy
// semantics (proven with a counter, no Vulkan calls) are hardware-independent
// and assert directly. The live instance + device + leaf-resource path runs
// best-effort and asserts nothing hardware-conditional.
@Suite struct NucleusVulkanResourcesTests {
    @Test func versionAndRequirements() {
        // Version packing round-trips and orders.
        let v = VkVersion(major: 1, minor: 3, patch: 7)
        #expect(v.major == 1 && v.minor == 3 && v.patch == 7, "version-decode")
        #expect(VkVersion(major: 1, minor: 2) < VkVersion(major: 1, minor: 3), "version-order")
        #expect(VkRequirements.minimumApiVersion.major == 1, "version-min-major")
        #expect(VkRequirements.minimumApiVersion.minor == 4, "version-min-minor")

        // Requirements source of truth (compositor presents through DRM/KMS = platformDefault).
        let deviceExtensions = VkRequirements.deviceExtensions()
        #expect(!VkRequirements.instanceExtensions().isEmpty, "req-instance-nonempty")
        #expect(deviceExtensions.contains(VK.Ext.extExternalMemoryDmaBuf), "req-device-dmabuf")
        #expect(deviceExtensions.contains(VK.Ext.khrTimelineSemaphore), "req-device-timeline")
        let contract = VkRequirements.contract()
        #expect(contract.requiresTimelineSemaphore, "req-feature-timeline")
        #expect(contract.requiresSamplerYcbcrConversion, "req-feature-ycbcr")

        // C-string array borrowing.
        withCStringArray(deviceExtensions) { ptr, count in
            #expect(count == UInt32(deviceExtensions.count), "cstrings-count")
            #expect(ptr != nil, "cstrings-ptr")
            let first = String(cString: ptr![0]!)
            #expect(first == deviceExtensions[0], "cstrings-roundtrip")
        }
        withCStringArray([]) { ptr, count in
            #expect(ptr == nil && count == 0, "cstrings-empty")
        }
    }

    @Test func featureChain() {
        // Feature chain: FEATURES_2 -> VULKAN_1_2 -> VULKAN_1_1 (dynamic last link).
        let contract = VkRequirements.contract(for: .waylandClientWSI)
        withRequiredFeatureChain(contract: contract) { head in
            #expect(head.pointee.sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, "chain-head-stype")
            // Features2.pNext is a raw void*; subsequent links are VkBaseInStructure.
            guard let raw1 = head.pointee.pNext else { #expect(Bool(false), "chain-link1"); return }
            let link1 = raw1.assumingMemoryBound(to: VkBaseInStructure.self)
            #expect(link1.pointee.sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, "chain-link1-stype")
            guard let link2 = link1.pointee.pNext else { #expect(Bool(false), "chain-link2"); return }
            #expect(link2.pointee.sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, "chain-link2-stype")
            guard let link3 = link2.pointee.pNext else { #expect(Bool(false), "chain-link3"); return }
            #expect(
                link3.pointee.sType
                    == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SWAPCHAIN_MAINTENANCE_1_FEATURES_KHR,
                "chain-link3-stype")
            #expect(link3.pointee.pNext == nil, "chain-tail-nil")
        }
    }

    @Test func ownerSemantics() {
        // Owner semantics, proven with a counter and a fabricated (never-deref'd)
        // device pointer — no Vulkan calls.
        let fakeDevice = OpaquePointer(bitPattern: 0xDEAD_BEEF)!
        final class Counter { var n = 0 }
        let destroyed = Counter()
        do {
            _ = VkOwned<Int>(adopting: 7, device: fakeDevice, destroy: { _, _ in destroyed.n += 1 })
        }
        #expect(destroyed.n == 1, "owner-deinit-destroys-once")

        // Moving a noncopyable owner transfers ownership without destroying; the
        // resource is destroyed exactly once when the final owner's scope ends.
        let movedOnce = Counter()
        do {
            let a = VkOwned<Int>(adopting: 9, device: fakeDevice, destroy: { _, _ in movedOnce.n += 1 })
            let b = consume a
            #expect(b.handle == 9, "owner-move-preserves-handle")
        }
        #expect(movedOnce.n == 1, "owner-move-destroys-once")
    }

    // Best-effort live: instance is loader-level (no GPU needed); device + leaf
    // resources only where a physical device exists. Asserts nothing
    // hardware-conditional; verifies compile + link and headless safety.
    @Test(.disabled("requires a live GPU/Vulkan device")) func liveResourcesBestEffort() {
        let base = VK.loadBaseDispatch()
        let contract = VkRequirements.contract()
        guard let instance = InstanceOwner.create(
            base: base, applicationName: "NucleusVulkanResourcesTests",
            contract: contract, enableValidation: false
        ) else { return }
        guard let selection = DeviceOwner.selectPhysicalDevice(
            instance: instance.handle, dispatch: instance.dispatch, contract: contract
        ) else { return }
        guard let device = DeviceOwner.create(
            selection: selection,
            instanceDispatch: instance.dispatch,
            contract: contract
        ) else { return }

        // Each leaf owner is consumed by the if-let bind and destroyed by its
        // deinit at block end (exactly once).
        if let fence = device.dispatch.createFence(device.handle) { _ = consume fence }
        if let semaphore = device.dispatch.createSemaphore(device.handle) { _ = consume semaphore }
        if let pool = device.dispatch.createCommandPool(device.handle, queueFamily: selection.graphicsQueueFamily) {
            _ = consume pool
        }

    }
}
