import BinaryParsing
import Foundation

struct XCursorImage: Sendable {
    var width: UInt32
    var height: UInt32
    var hotSpotX: UInt32
    var hotSpotY: UInt32
    var pixels: Data
}

enum XCursor {
    private static let magic: UInt32 = 0x7275_6358
    private static let imageType: UInt32 = 0xFFFD_0002
    private static let fileHeaderByteCount = 16
    private static let tocEntryByteCount = 12
    private static let imageHeaderByteCount = 36

    @safe static func parse(_ data: Data, targetSize: UInt32) -> XCursorImage? {
        (try? data.withParserSpan { input in
            try parse(&input, targetSize: targetSize)
        }) ?? nil
    }

    private static func parse(
        _ input: inout ParserSpan,
        targetSize: UInt32
    ) throws -> XCursorImage? {
        guard try UInt32(parsingLittleEndian: &input) == magic else { return nil }
        guard
            let fileHeaderLength = try? UInt32(parsingLittleEndian: &input),
            fileHeaderLength >= UInt32(fileHeaderByteCount)
        else { return nil }
        _ = try UInt32(parsingLittleEndian: &input)
        guard
            let count = try? UInt32(parsingLittleEndian: &input),
            count > 0,
            count <= 1024
        else { return nil }
        try input.seek(toAbsoluteOffset: fileHeaderLength)
        var toc = try input.extract(objectStride: tocEntryByteCount, objectCount: count)

        var best: (subtype: UInt32, position: UInt32)?
        var bestDiff = UInt32.max
        for _ in 0..<count {
            let chunkType = try UInt32(parsingLittleEndian: &toc)
            let subtype = try UInt32(parsingLittleEndian: &toc)
            let position = try UInt32(parsingLittleEndian: &toc)
            guard chunkType == imageType else { continue }
            let diff = subtype >= targetSize ? subtype - targetSize : targetSize - subtype
            if diff < bestDiff {
                bestDiff = diff
                best = (subtype, position)
            }
        }
        guard let best else { return nil }

        try input.seek(toAbsoluteOffset: best.position)
        let chunkStart = input.startPosition
        let chunkHeaderLength = try UInt32(parsingLittleEndian: &input)
        guard chunkHeaderLength >= UInt32(imageHeaderByteCount) else { return nil }
        guard try UInt32(parsingLittleEndian: &input) == imageType else { return nil }
        guard try UInt32(parsingLittleEndian: &input) == best.subtype else { return nil }
        _ = try UInt32(parsingLittleEndian: &input)
        let width = try UInt32(parsingLittleEndian: &input)
        let height = try UInt32(parsingLittleEndian: &input)
        let hotSpotX = try UInt32(parsingLittleEndian: &input)
        let hotSpotY = try UInt32(parsingLittleEndian: &input)
        _ = try UInt32(parsingLittleEndian: &input)
        guard width > 0, height > 0, width <= 256, height <= 256 else { return nil }
        let (pixelCount, overflow) = UInt64(width).multipliedReportingOverflow(by: UInt64(height))
        guard !overflow else { return nil }
        try input.seek(toAbsoluteOffset: UInt64(chunkStart) + UInt64(chunkHeaderLength))
        var pixelSpan = try input.extract(objectStride: 4, objectCount: pixelCount)
        let pixels = Data(parsingRemainingBytes: &pixelSpan)
        return XCursorImage(
            width: width, height: height, hotSpotX: hotSpotX, hotSpotY: hotSpotY, pixels: pixels)
    }
}
