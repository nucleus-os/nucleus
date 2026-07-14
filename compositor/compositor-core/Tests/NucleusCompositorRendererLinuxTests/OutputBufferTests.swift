import Testing
import VulkanC
import Vulkan
@testable import NucleusRenderer

// Converted from OutputBufferFixture (Phase 10b.5): the output-buffer
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

    @Test func clientShmConversion() {
        // Client SHM conversion: DRM AR24/XR24 memory is little-endian BGRA/BGRX,
        // while the Skia raster façade consumes RGBA bytes.
        let argbWithPadding: [UInt8] = [
            0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0xee, 0xee, 0xee, 0xee,
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0xee, 0xee, 0xee, 0xee,
        ]
        #expect(
            convertClientShmToRGBA(
                pixels: argbWithPadding, width: 2, height: 2,
                drmFormat: DrmFourcc.argb8888, stride: 12
            ) == [
                0x30, 0x20, 0x10, 0x40, 0x70, 0x60, 0x50, 0x80,
                0x03, 0x02, 0x01, 0x04, 0x07, 0x06, 0x05, 0x08,
            ],
            "shm-argb-to-rgba")
        #expect(
            convertClientShmToRGBA(
                pixels: [0x10, 0x20, 0x30, 0x00], width: 1, height: 1,
                drmFormat: DrmFourcc.xrgb8888, stride: 4
            ) == [0x30, 0x20, 0x10, 0xff],
            "shm-xrgb-opaque")
        #expect(
            convertClientShmToRGBA(
                pixels: [0, 0, 0], width: 1, height: 1,
                drmFormat: DrmFourcc.argb8888, stride: 4
            ) == nil,
            "shm-truncated-fails")
        #expect(
            convertClientShmToRGBA(
                pixels: [0, 0, 0, 0], width: 1, height: 1,
                drmFormat: 0xffff_ffff, stride: 4
            ) == nil,
            "shm-unsupported-format-fails")
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

        withDmaBufImportImageInfo(descriptor) { head in
            #expect(head.pointee.sType == VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, "chain-head-stype")
            #expect(head.pointee.flags == 0, "chain-same-fd-not-disjoint")
            #expect(head.pointee.tiling == VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT, "chain-tiling")
            #expect(head.pointee.format == VK_FORMAT_B8G8R8A8_UNORM, "chain-format")
            #expect(head.pointee.extent.width == 256 && head.pointee.extent.height == 128, "chain-extent")
            #expect(head.pointee.usage == (VK.ImageUsageFlags.sampledBit.rawValue | VK.ImageUsageFlags.colorAttachmentBit.rawValue), "chain-usage")

            guard let raw1 = head.pointee.pNext else { #expect(Bool(false), "chain-link1"); return }
            let external = raw1.assumingMemoryBound(to: VkExternalMemoryImageCreateInfo.self)
            #expect(external.pointee.sType == VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO, "chain-ext-stype")
            #expect(external.pointee.handleTypes == VK.ExternalMemoryHandleTypeFlags.dmaBufBitEXT.rawValue, "chain-ext-handletype")

            guard let raw2 = external.pointee.pNext else { #expect(Bool(false), "chain-link2"); return }
            let modifier = raw2.assumingMemoryBound(to: VkImageDrmFormatModifierExplicitCreateInfoEXT.self)
            #expect(modifier.pointee.sType == VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_EXPLICIT_CREATE_INFO_EXT, "chain-mod-stype")
            #expect(modifier.pointee.drmFormatModifier == 0x0100_0000_0000_0001, "chain-mod-value")
            #expect(modifier.pointee.drmFormatModifierPlaneCount == 2, "chain-mod-plane-count")
            if let layouts = modifier.pointee.pPlaneLayouts {
                #expect(layouts[0].rowPitch == 1024 && layouts[0].offset == 0, "chain-plane0-layout")
                #expect(layouts[1].rowPitch == 512 && layouts[1].offset == 131_072, "chain-plane1-layout")
            } else {
                #expect(Bool(false), "chain-plane-layouts")
            }
            #expect(modifier.pointee.pNext == nil, "chain-tail-nil")
        }

        let separateFdDescriptor = DmaBufImageDescriptor(
            fd: 10, width: 256, height: 128, drmFormat: DrmFourcc.xrgb8888,
            modifier: 0x0100_0000_0000_0001,
            planes: [
                DmaBufPlane(fd: 10, offset: 0, rowPitch: 1024),
                DmaBufPlane(fd: 11, offset: 131_072, rowPitch: 512),
            ])
        withDmaBufImportImageInfo(separateFdDescriptor) { head in
            #expect(
                head.pointee.flags == VK.ImageCreateFlags.disjointBit.rawValue,
                "chain-separate-fd-disjoint")
        }
    }
}
