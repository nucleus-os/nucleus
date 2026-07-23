import FoundationEssentials
import Testing
@testable import NucleusCompositorShell

@Suite struct XCursorTests {
    @Test func selectsTheClosestImageAndOwnsItsPixels() {
        var data = cursorFile([
            .init(size: 16, width: 1, height: 1, hotSpotX: 0, hotSpotY: 0,
                  pixels: [1, 2, 3, 4]),
            .init(size: 32, width: 2, height: 1, hotSpotX: 1, hotSpotY: 0,
                  pixels: [10, 20, 30, 40, 50, 60, 70, 80]),
        ])

        let image = XCursor.parse(data, targetSize: 28)
        data = Data(repeating: 0xff, count: data.count)

        #expect(image?.width == 2)
        #expect(image?.height == 1)
        #expect(image?.hotSpotX == 1)
        #expect(image?.hotSpotY == 0)
        #expect(image?.pixels == Data([10, 20, 30, 40, 50, 60, 70, 80]))
    }

    @Test func rejectsTruncatedHeadersTablesAndPayloads() {
        let valid = cursorFile([
            .init(size: 24, width: 1, height: 1, hotSpotX: 0, hotSpotY: 0,
                  pixels: [1, 2, 3, 4])
        ])

        #expect(XCursor.parse(Data(valid.prefix(15)), targetSize: 24) == nil)
        #expect(XCursor.parse(Data(valid.prefix(27)), targetSize: 24) == nil)
        #expect(XCursor.parse(Data(valid.dropLast()), targetSize: 24) == nil)
    }

    @Test func rejectsOffsetsOutsideTheInput() {
        var data = cursorFile([
            .init(size: 24, width: 1, height: 1, hotSpotX: 0, hotSpotY: 0,
                  pixels: [1, 2, 3, 4])
        ])
        replaceUInt32(at: 24, with: .max, in: &data)
        #expect(XCursor.parse(data, targetSize: 24) == nil)
    }

    @Test func rejectsInvalidHeaderLengthsAndEmptyImages() {
        let shortFileHeader = cursorFile([
            .init(size: 24, width: 1, height: 1, hotSpotX: 0, hotSpotY: 0,
                  pixels: [1, 2, 3, 4])
        ], fileHeaderLength: 12)
        let shortChunkHeader = cursorFile([
            .init(size: 24, width: 1, height: 1, hotSpotX: 0, hotSpotY: 0,
                  pixels: [1, 2, 3, 4], headerLength: 35)
        ])
        let emptyImage = cursorFile([
            .init(size: 24, width: 0, height: 1, hotSpotX: 0, hotSpotY: 0,
                  pixels: [])
        ])

        #expect(XCursor.parse(shortFileHeader, targetSize: 24) == nil)
        #expect(XCursor.parse(shortChunkHeader, targetSize: 24) == nil)
        #expect(XCursor.parse(emptyImage, targetSize: 24) == nil)
    }
}

private struct CursorFixtureImage {
    var size: UInt32
    var width: UInt32
    var height: UInt32
    var hotSpotX: UInt32
    var hotSpotY: UInt32
    var pixels: [UInt8]
    var headerLength: UInt32 = 36
}

private func cursorFile(
    _ images: [CursorFixtureImage],
    fileHeaderLength: UInt32 = 16
) -> Data {
    let tocEnd = 16 + images.count * 12
    var positions: [UInt32] = []
    var nextPosition = tocEnd
    for image in images {
        positions.append(UInt32(nextPosition))
        nextPosition += max(Int(image.headerLength), 36) + image.pixels.count
    }

    var data = Data()
    appendUInt32(0x7275_6358, to: &data)
    appendUInt32(fileHeaderLength, to: &data)
    appendUInt32(0x0001_0000, to: &data)
    appendUInt32(UInt32(images.count), to: &data)
    for (image, position) in zip(images, positions) {
        appendUInt32(0xFFFD_0002, to: &data)
        appendUInt32(image.size, to: &data)
        appendUInt32(position, to: &data)
    }
    for image in images {
        appendUInt32(image.headerLength, to: &data)
        appendUInt32(0xFFFD_0002, to: &data)
        appendUInt32(image.size, to: &data)
        appendUInt32(1, to: &data)
        appendUInt32(image.width, to: &data)
        appendUInt32(image.height, to: &data)
        appendUInt32(image.hotSpotX, to: &data)
        appendUInt32(image.hotSpotY, to: &data)
        appendUInt32(0, to: &data)
        if image.headerLength > 36 {
            data.append(contentsOf: repeatElement(0, count: Int(image.headerLength - 36)))
        }
        data.append(contentsOf: image.pixels)
    }
    return data
}

private func appendUInt32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(truncatingIfNeeded: value))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
    data.append(UInt8(truncatingIfNeeded: value >> 16))
    data.append(UInt8(truncatingIfNeeded: value >> 24))
}

private func replaceUInt32(at offset: Int, with value: UInt32, in data: inout Data) {
    data[offset] = UInt8(truncatingIfNeeded: value)
    data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    data[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
    data[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
}
