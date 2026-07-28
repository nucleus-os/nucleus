import Testing
@testable import NucleusRenderer
import VulkanC
import Vulkan

// Converted from NucleusVulkanResourcesFixture: version packing, the
// requirements source of truth, the feature-chain builder (walked via pNext),
// and the noncopyable owner's destroy-exactly-once / take-suppresses-destroy
// semantics (proven with a counter, no Vulkan calls) are hardware-independent
// and assert directly. The live instance + device + leaf-resource path runs
// mandatory in the headless Vulkan lane.
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
        unsafe withCStringArray(deviceExtensions) { ptr, count in
            let pointerExists = unsafe ptr != nil
            let first = unsafe String(cString: ptr![0]!)
            #expect(count == UInt32(deviceExtensions.count), "cstrings-count")
            #expect(pointerExists, "cstrings-ptr")
            #expect(first == deviceExtensions[0], "cstrings-roundtrip")
        }
        unsafe withCStringArray([]) { ptr, count in
            let isEmpty = unsafe ptr == nil && count == 0
            #expect(isEmpty, "cstrings-empty")
        }
    }

    @Test func featureChain() {
        // Feature chain: FEATURES_2 -> VULKAN_1_2 -> VULKAN_1_1 (dynamic last link).
        let contract = VkRequirements.contract(
            for: .waylandClientBackingStore)
        unsafe withRequiredFeatureEnableChain(contract: contract) { head in
            let headSType = unsafe head.pointee.sType
            #expect(
                headSType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
                "chain-head-stype")
            // Features2.pNext is a raw void*; subsequent links are VkBaseInStructure.
            guard let raw1 = unsafe head.pointee.pNext else {
                #expect(Bool(false), "chain-link1")
                return
            }
            let link1 = unsafe raw1.assumingMemoryBound(to: VkBaseInStructure.self)
            let link1SType = unsafe link1.pointee.sType
            #expect(
                link1SType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
                "chain-link1-stype")
            guard let link2 = unsafe link1.pointee.pNext else {
                #expect(Bool(false), "chain-link2")
                return
            }
            let link2SType = unsafe link2.pointee.sType
            #expect(
                link2SType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
                "chain-link2-stype")
            let tailIsNil = unsafe link2.pointee.pNext == nil
            #expect(tailIsNil, "chain-tail-nil")
        }
    }

    @Test func ownerSemantics() {
        // Owner semantics, proven with a counter and a fabricated (never-deref'd)
        // device pointer — no Vulkan calls.
        let fakeDevice = unsafe OpaquePointer(bitPattern: 0xDEAD_BEEF)!
        final class Counter { var n = 0 }
        let destroyed = Counter()
        do {
            _ = unsafe VkOwned<Int>(
                adopting: 7,
                device: fakeDevice,
                destroy: { _, _ in destroyed.n += 1 })
        }
        #expect(destroyed.n == 1, "owner-deinit-destroys-once")

        // Moving a noncopyable owner transfers ownership without destroying; the
        // resource is destroyed exactly once when the final owner's scope ends.
        let movedOnce = Counter()
        do {
            let a = unsafe VkOwned<Int>(
                adopting: 9,
                device: fakeDevice,
                destroy: { _, _ in movedOnce.n += 1 })
            let b = consume a
            #expect(b.handle == 9, "owner-move-preserves-handle")
        }
        #expect(movedOnce.n == 1, "owner-move-destroys-once")
    }

    @Test func gpuHeadless_liveResources() throws {
        try unsafe withRequiredVulkanGraphite(
            presentation: .headless,
            applicationName: "NucleusVulkanResourcesTests"
        ) { device, selection, context, recorder in
            // Each leaf owner is consumed by the binding and destroyed by its
            // deinit at block end (exactly once).
            guard let fence = unsafe device.dispatch.createFence(device.handle) else {
                throw VulkanLaneTestFailure.requirement(
                    "could not create the required Vulkan fence")
            }
            guard let semaphore = unsafe device.dispatch.createSemaphore(device.handle) else {
                throw VulkanLaneTestFailure.requirement(
                    "could not create the required Vulkan semaphore")
            }
            guard let pool = unsafe device.dispatch.createCommandPool(
                device.handle,
                queueFamily: selection.graphicsQueueFamily
            ) else {
                throw VulkanLaneTestFailure.requirement(
                    "could not create the required Vulkan command pool")
            }
            let surface = unsafe recorder.makeOffscreenSurface(4, 4)
            let surfaceIsValid = unsafe surface.isValid()
            try requireTrue(
                surfaceIsValid, "headless Graphite surface creation failed")
            let recording = unsafe recorder.snapRecording()
            let submissionCompleted = unsafe submitGraphiteAndWait(
                context: context, recording: recording, serial: 1)
            try requireTrue(
                submissionCompleted,
                "headless resource submission did not complete")
            unsafe keepAlive(fence)
            unsafe keepAlive(semaphore)
            unsafe keepAlive(pool)
        }
    }
}
