import Foundation

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

    static func parse(_ data: Data, targetSize: UInt32) -> XCursorImage? {
        var reader = Reader(data)
        guard reader.u32() == magic else { return nil }
        _ = reader.u32()
        _ = reader.u32()
        guard let count = reader.u32(), count > 0, count <= 1024 else { return nil }

        var best: (subtype: UInt32, position: UInt32)?
        var bestDiff = UInt32.max
        for _ in 0..<count {
            guard let chunkType = reader.u32(),
                  let subtype = reader.u32(),
                  let position = reader.u32() else { return nil }
            guard chunkType == imageType else { continue }
            let diff = subtype >= targetSize ? subtype - targetSize : targetSize - subtype
            if diff < bestDiff {
                bestDiff = diff
                best = (subtype, position)
            }
        }
        guard let best else { return nil }

        reader.offset = Int(best.position)
        _ = reader.u32()
        guard reader.u32() == imageType else { return nil }
        _ = reader.u32()
        _ = reader.u32()
        guard let width = reader.u32(),
              let height = reader.u32(),
              let hotSpotX = reader.u32(),
              let hotSpotY = reader.u32() else { return nil }
        _ = reader.u32()
        guard width > 0, height > 0, width <= 256, height <= 256 else { return nil }
        let byteCount = Int(width) * Int(height) * 4
        guard let pixels = reader.bytes(byteCount) else { return nil }
        return XCursorImage(width: width, height: height, hotSpotX: hotSpotX, hotSpotY: hotSpotY, pixels: pixels)
    }

    private struct Reader {
        let data: Data
        var offset = 0

        init(_ data: Data) {
            self.data = data
        }

        mutating func u32() -> UInt32? {
            guard offset + 4 <= data.count else { return nil }
            let value = data[offset..<offset + 4].withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self)
            }
            offset += 4
            return UInt32(littleEndian: value)
        }

        mutating func bytes(_ count: Int) -> Data? {
            guard count >= 0, offset + count <= data.count else { return nil }
            let slice = data[offset..<offset + count]
            offset += count
            return Data(slice)
        }
    }
}
