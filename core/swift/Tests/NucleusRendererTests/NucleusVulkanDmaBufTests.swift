import Testing
@testable import NucleusRenderer

@Suite struct NucleusVulkanDmaBufTests {
    private func convert(
        _ pixels: [UInt8],
        width: UInt32,
        height: UInt32,
        format: UInt32,
        stride: UInt32
    ) -> [UInt8]? {
        pixels.withUnsafeBytes {
            convertClientShmToRGBA(
                pixels: $0,
                width: width,
                height: height,
                drmFormat: format,
                stride: stride)
        }
    }

    @Test func convertsPaddedARGBRowsToTightRGBA() {
        let pixels: [UInt8] = [
            0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0xee, 0xee, 0xee, 0xee,
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0xee, 0xee, 0xee, 0xee,
        ]
        #expect(
            convert(
                pixels,
                width: 2,
                height: 2,
                format: DrmFourcc.argb8888,
                stride: 12
            ) == [
                0x30, 0x20, 0x10, 0x40, 0x70, 0x60, 0x50, 0x80,
                0x03, 0x02, 0x01, 0x04, 0x07, 0x06, 0x05, 0x08,
            ])
    }

    @Test func convertsTightXRGBToOpaqueRGBA() {
        #expect(
            convert(
                [0x10, 0x20, 0x30, 0x00],
                width: 1,
                height: 1,
                format: DrmFourcc.xrgb8888,
                stride: 4
            ) == [0x30, 0x20, 0x10, 0xff])
    }

    @Test func rejectsInvalidLayoutsBeforeReading() {
        #expect(
            convert(
                [],
                width: 0,
                height: 1,
                format: DrmFourcc.argb8888,
                stride: 4
            ) == nil)
        #expect(
            convert(
                [0, 0, 0, 0],
                width: 2,
                height: 1,
                format: DrmFourcc.argb8888,
                stride: 4
            ) == nil)
        #expect(
            convert(
                [0, 0, 0],
                width: 1,
                height: 1,
                format: DrmFourcc.argb8888,
                stride: 4
            ) == nil)
        #expect(
            convert(
                [0, 0, 0, 0],
                width: 1,
                height: 1,
                format: 0xffff_ffff,
                stride: 4
            ) == nil)
        #expect(
            convert(
                [],
                width: .max,
                height: .max,
                format: DrmFourcc.argb8888,
                stride: .max
            ) == nil)
    }

    @Test func returnedPixelsDoNotBorrowSourceStorage() {
        var source = [UInt8]([0x10, 0x20, 0x30, 0x40])
        let converted = source.withUnsafeBytes {
            convertClientShmToRGBA(
                pixels: $0,
                width: 1,
                height: 1,
                drmFormat: DrmFourcc.argb8888,
                stride: 4)
        }
        _ = source.withUnsafeMutableBytes {
            $0.initializeMemory(as: UInt8.self, repeating: 0xff)
        }
        #expect(converted == [0x30, 0x20, 0x10, 0x40])
    }

    @Test func fullResolutionDestinationSizesAreTightlyPacked() {
        for (width, height) in [(UInt32(1_920), UInt32(1_080)), (UInt32(3_840), UInt32(2_160))] {
            let byteCount = Int(width) * Int(height) * 4
            let source = UnsafeMutableRawBufferPointer.allocate(
                byteCount: byteCount,
                alignment: MemoryLayout<UInt32>.alignment)
            defer { source.deallocate() }
            source.initializeMemory(as: UInt8.self, repeating: 0)
            let converted = convertClientShmToRGBAWithMetrics(
                pixels: UnsafeRawBufferPointer(source),
                width: width,
                height: height,
                drmFormat: DrmFourcc.xrgb8888,
                stride: width * 4)
            #expect(converted?.pixels.count == byteCount)
            #expect(converted?.metrics == ClientShmConversionMetrics(
                fullSizeOwnedAllocations: 1,
                ownedAllocationBytes: UInt64(byteCount),
                bytesCopied: UInt64(byteCount)))
        }
    }
}
