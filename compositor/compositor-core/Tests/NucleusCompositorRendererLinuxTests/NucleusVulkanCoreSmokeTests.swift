import Testing
@testable import NucleusRenderer
import VulkanC
import Vulkan

// Converted from NucleusVulkanCoreSmoke: the generated NucleusVulkan binding
// core (scoped enums carry canonical codes, option sets compose, typed handles
// default null, Result classifies) plus the raw Vulkan loader link. All
// hardware-independent: vkEnumerateInstanceVersion is a loader-trampoline global
// that succeeds against the host Vulkan loader without any ICD/device.
@Suite struct NucleusVulkanCoreSmokeTests {
    @Test func bindingCore() {
        // Scoped enums carry the canonical Vulkan codes.
        #expect(VK.Result.success.rawValue == 0, "result-success")
        #expect(VK.Result.errorOutOfHostMemory.rawValue == -1, "result-error")
        #expect(VK.Result.success.isSuccess && !VK.Result.success.isError, "result-classify-success")
        #expect(VK.Result.errorDeviceLost.isError && !VK.Result.errorDeviceLost.isSuccess, "result-classify-error")
        #expect(VK.Result.suboptimalKHR.isSuccess, "result-classify-positive-khr")
        #expect(VK.Format.r8g8b8a8Unorm.rawValue == 37, "format-rgba")

        // Digit-leading enum cases are sanitized to legal Swift identifiers.
        #expect(VK.ImageType._2D.rawValue == 1, "imagetype-digit")
        #expect(VK.ImageViewType._2D.rawValue == 1, "imageviewtype-digit")

        // Option sets compose like Vulkan flag words.
        let usage: VK.ImageUsageFlags = [.colorAttachmentBit, .sampledBit]
        #expect(usage.contains(.sampledBit) && usage.contains(.colorAttachmentBit), "optionset-contains")
        #expect(!usage.contains(.transferSrcBit), "optionset-excludes")
        #expect(VK.QueueFlags.graphicsBit.rawValue == 0x1, "optionset-bit")
        #expect(VK.ImageUsageFlags(rawValue: 0x14) == usage, "optionset-rawvalue-eq")

        // Typed handles: dispatchable wrap a pointer, non-dispatchable a u64;
        // both default null.
        #expect(VK.Device.null.isNull && VK.Device.null.raw == nil, "handle-dispatch-null")
        #expect(VK.Buffer.null.isNull && VK.Buffer.null.raw == 0, "handle-nondispatch-null")
        #expect(VK.Buffer(7) == VK.Buffer(7) && VK.Buffer(7) != VK.Buffer.null, "handle-equatable")
    }

    @Test(.disabled("invokes the real Vulkan loader (flaky on partial-ICD hosts)")) func loaderLinks() {
        // The Vulkan loader links: a global command runs with no instance.
        var apiVersion: UInt32 = 0
        let r = vkEnumerateInstanceVersion(&apiVersion)
        #expect(r == VK_SUCCESS, "loader-enumerate-version")
        #expect(apiVersion != 0, "loader-version-nonzero")
    }
}
