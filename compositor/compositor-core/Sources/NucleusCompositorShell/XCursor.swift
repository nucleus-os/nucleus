import FoundationEssentials

struct XCursorImage {
    var width: UInt32
    var height: UInt32
    var hotSpotX: UInt32
    var hotSpotY: UInt32
    var pixels: Data
}

enum XCursor {
    private static let magic: UInt32 = 0x72756358
    private static let imageType: UInt32 = 0xFFFD0002
    private static let fileHeaderByteCount = 16
    private static let tocEntryByteCount = 12
    private static let imageHeaderByteCount = 36

    @safe static func parse(_ data: Data, targetSize: UInt32) -> XCursorImage? {
        unsafe data.withUnsafeBytes { rawBytes in
            let bytes = unsafe Span<UInt8>(_unsafeBytes: rawBytes)
            return parse(bytes, targetSize: targetSize)
        }
    }

    private static func parse(_ bytes: Span<UInt8>, targetSize: UInt32) -> XCursorImage? {
        var reader = Reader()
        guard reader.u32(from: bytes) == magic else { return nil }
        guard
            let fileHeaderLength = reader.u32(from: bytes),
            fileHeaderLength >= UInt32(fileHeaderByteCount)
        else { return nil }
        _ = reader.u32(from: bytes)
        guard
            let count = reader.u32(from: bytes),
            count > 0,
            count <= 1024
        else { return nil }
        guard
            let tocOffset = Int(exactly: fileHeaderLength),
            reader.seek(to: tocOffset, in: bytes)
        else { return nil }
        let (tocByteCount, tocByteCountOverflow) =
            Int(count).multipliedReportingOverflow(by: tocEntryByteCount)
        guard
            !tocByteCountOverflow,
            tocByteCount <= reader.remainingCount(in: bytes)
        else { return nil }

        var best: (subtype: UInt32, position: UInt32)?
        var bestDiff = UInt32.max
        for _ in 0..<count {
            guard let chunkType = reader.u32(from: bytes),
                  let subtype = reader.u32(from: bytes),
                  let position = reader.u32(from: bytes) else { return nil }
            guard chunkType == imageType else { continue }
            let diff = subtype >= targetSize ? subtype - targetSize : targetSize - subtype
            if diff < bestDiff {
                bestDiff = diff
                best = (subtype, position)
            }
        }
        guard let best else { return nil }

        guard
            let chunkStart = Int(exactly: best.position),
            reader.seek(to: chunkStart, in: bytes),
            let chunkHeaderLength = reader.u32(from: bytes),
            chunkHeaderLength >= UInt32(imageHeaderByteCount)
        else { return nil }
        guard reader.u32(from: bytes) == imageType else { return nil }
        guard reader.u32(from: bytes) == best.subtype else { return nil }
        _ = reader.u32(from: bytes)
        guard let width = reader.u32(from: bytes),
              let height = reader.u32(from: bytes),
              let hotSpotX = reader.u32(from: bytes),
              let hotSpotY = reader.u32(from: bytes) else { return nil }
        _ = reader.u32(from: bytes)
        guard width > 0, height > 0, width <= 256, height <= 256 else { return nil }
        guard
            let headerByteCount = Int(exactly: chunkHeaderLength),
            headerByteCount <= Int.max - chunkStart,
            reader.seek(to: chunkStart + headerByteCount, in: bytes)
        else { return nil }
        let (pixelCount, pixelCountOverflow) =
            Int(width).multipliedReportingOverflow(by: Int(height))
        let (byteCount, byteCountOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard
            !pixelCountOverflow,
            !byteCountOverflow,
            let pixels = reader.data(byteCount, from: bytes)
        else { return nil }
        return XCursorImage(width: width, height: height, hotSpotX: hotSpotX, hotSpotY: hotSpotY, pixels: pixels)
    }

    private struct Reader {
        private(set) var offset = 0

        func remainingCount(in bytes: Span<UInt8>) -> Int {
            bytes.count - offset
        }

        mutating func seek(to newOffset: Int, in bytes: Span<UInt8>) -> Bool {
            guard newOffset >= 0, newOffset <= bytes.count else { return false }
            offset = newOffset
            return true
        }

        private mutating func takeRange(
            _ count: Int,
            in bytes: Span<UInt8>
        ) -> Range<Int>? {
            guard
                count >= 0,
                offset <= bytes.count,
                count <= bytes.count - offset
            else { return nil }
            let start = offset
            offset += count
            return start..<offset
        }

        mutating func u32(from bytes: Span<UInt8>) -> UInt32? {
            guard let range = takeRange(4, in: bytes) else { return nil }
            let start = range.lowerBound
            return UInt32(bytes[start])
                | (UInt32(bytes[start + 1]) << 8)
                | (UInt32(bytes[start + 2]) << 16)
                | (UInt32(bytes[start + 3]) << 24)
        }

        mutating func data(_ count: Int, from bytes: Span<UInt8>) -> Data? {
            guard let range = takeRange(count, in: bytes) else { return nil }
            var result = Data(count: count)
            for destinationIndex in 0..<count {
                result[destinationIndex] = bytes[range.lowerBound + destinationIndex]
            }
            return result
        }
    }
}
