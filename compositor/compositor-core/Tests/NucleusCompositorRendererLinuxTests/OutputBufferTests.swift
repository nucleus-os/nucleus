import Testing
import VulkanC
import Vulkan
@testable import NucleusRenderer

// owner's three-lifetime destroy-once/ordering contract, the mailbox ring, the
// SHM→RGBA conversion, and the DMA-BUF import VkImageCreateInfo chain
// (external-memory + explicit DRM modifier plane layouts), walked via pNext. All
// hardware-independent — the live cross-device import binds in the renderer where
// a matched GBM/Vulkan device exists.
@Suite struct OutputBufferTests {
    @Test func destroyOrderAndMailbox() {
        // Output-buffer owner: destroys all three lifetimes once, fb → image → BO.
        final class Order { var events: [String] = [] }
        let order = Order()
        do {
            let _ = OutputBufferOwner(
                width: 256, height: 128,
                destroyFramebuffer: { order.events.append("fb") },
                destroyImage: { order.events.append("image") },
                destroyBuffer: { order.events.append("bo") })
        }
        #expect(order.events == ["fb", "image", "bo"], "output-buffer-destroy-order")

        // Mailbox ring rotates round-robin.
        var ring = MailboxRing(capacity: 3)
        #expect(ring.acquireSlot() == 0, "mailbox-slot-0")
        #expect(ring.acquireSlot() == 1, "mailbox-slot-1")
        #expect(ring.acquireSlot() == 2, "mailbox-slot-2")
        #expect(ring.acquireSlot() == 0, "mailbox-wrap")

        #expect(ScanoutCopy(sourceGeneration: 4, targetGeneration: 7) == ScanoutCopy(sourceGeneration: 4, targetGeneration: 7), "scanout-copy-eq")
        #expect(vulkanFormatForDrm(DrmFourcc.xrgb8888) == VK_FORMAT_B8G8R8A8_UNORM, "drm-format-map")
    }

    @Test func dmaBufImportChain() {
        // DMA-BUF import chain: VkImageCreateInfo → external-memory → modifier.
        let descriptor = DmaBufImageDescriptor(
            fd: -1, width: 256, height: 128, drmFormat: DrmFourcc.xrgb8888,
            modifier: 0x0100_0000_0000_0001,
            planes: [
                DmaBufPlane(offset: 0, rowPitch: 1024),
                DmaBufPlane(offset: 131_072, rowPitch: 512),
            ])

        unsafe withDmaBufImportImageInfo(descriptor) { head in
            let headSType = unsafe head.pointee.sType
            let headFlags = unsafe head.pointee.flags
            let headTiling = unsafe head.pointee.tiling
            let headFormat = unsafe head.pointee.format
            let headWidth = unsafe head.pointee.extent.width
            let headHeight = unsafe head.pointee.extent.height
            let headUsage = unsafe head.pointee.usage
            #expect(headSType == VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, "chain-head-stype")
            #expect(headFlags == 0, "chain-same-fd-not-disjoint")
            #expect(headTiling == VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT, "chain-tiling")
            #expect(headFormat == VK_FORMAT_B8G8R8A8_UNORM, "chain-format")
            #expect(headWidth == 256 && headHeight == 128, "chain-extent")
            #expect(
                headUsage == (VK.ImageUsageFlags.sampledBit.rawValue
                    | VK.ImageUsageFlags.colorAttachmentBit.rawValue),
                "chain-usage")

            guard let raw1 = unsafe head.pointee.pNext else {
                #expect(Bool(false), "chain-link1")
                return
            }
            let external = unsafe raw1.assumingMemoryBound(
                to: VkExternalMemoryImageCreateInfo.self)
            let externalSType = unsafe external.pointee.sType
            let externalHandleTypes = unsafe external.pointee.handleTypes
            #expect(
                externalSType == VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
                "chain-ext-stype")
            #expect(
                externalHandleTypes == VK.ExternalMemoryHandleTypeFlags.dmaBufBitEXT.rawValue,
                "chain-ext-handletype")

            guard let raw2 = unsafe external.pointee.pNext else {
                #expect(Bool(false), "chain-link2")
                return
            }
            let modifier = unsafe raw2.assumingMemoryBound(
                to: VkImageDrmFormatModifierExplicitCreateInfoEXT.self)
            let modifierSType = unsafe modifier.pointee.sType
            let modifierValue = unsafe modifier.pointee.drmFormatModifier
            let planeCount = unsafe modifier.pointee.drmFormatModifierPlaneCount
            #expect(
                modifierSType
                    == VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_EXPLICIT_CREATE_INFO_EXT,
                "chain-mod-stype")
            #expect(modifierValue == 0x0100_0000_0000_0001, "chain-mod-value")
            #expect(planeCount == 2, "chain-mod-plane-count")
            if let layouts = unsafe modifier.pointee.pPlaneLayouts {
                let plane0RowPitch = unsafe layouts[0].rowPitch
                let plane0Offset = unsafe layouts[0].offset
                let plane1RowPitch = unsafe layouts[1].rowPitch
                let plane1Offset = unsafe layouts[1].offset
                #expect(
                    plane0RowPitch == 1024 && plane0Offset == 0,
                    "chain-plane0-layout")
                #expect(
                    plane1RowPitch == 512 && plane1Offset == 131_072,
                    "chain-plane1-layout")
            } else {
                #expect(Bool(false), "chain-plane-layouts")
            }
            let tailIsNil = unsafe modifier.pointee.pNext == nil
            #expect(tailIsNil, "chain-tail-nil")
        }

        let separateFdDescriptor = DmaBufImageDescriptor(
            fd: 10, width: 256, height: 128, drmFormat: DrmFourcc.xrgb8888,
            modifier: 0x0100_0000_0000_0001,
            planes: [
                DmaBufPlane(fd: 10, offset: 0, rowPitch: 1024),
                DmaBufPlane(fd: 11, offset: 131_072, rowPitch: 512),
            ])
        unsafe withDmaBufImportImageInfo(separateFdDescriptor) { head in
            let flags = unsafe head.pointee.flags
            #expect(flags == VK.ImageCreateFlags.disjointBit.rawValue,
                    "chain-separate-fd-disjoint")
        }
    }
}
