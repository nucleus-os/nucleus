import FoundationEssentials

package let collectionReorderContentType =
    "application/x-nucleus-collection-item-v1"

package struct CollectionReorderPayload: Equatable {
    let collectionID: UInt64
    let snapshotGeneration: UInt64
    let itemToken: UInt64
    let sourceIndex: UInt64

    var data: Data {
        var result = Data()
        result.reserveCapacity(32)
        for value in [
            collectionID,
            snapshotGeneration,
            itemToken,
            sourceIndex,
        ] {
            for byte in 0..<8 {
                result.append(UInt8(truncatingIfNeeded: value >> (byte * 8)))
            }
        }
        return result
    }

    init(
        collectionID: UInt64,
        snapshotGeneration: UInt64,
        itemToken: UInt64,
        sourceIndex: Int
    ) {
        precondition(sourceIndex >= 0)
        self.collectionID = collectionID
        self.snapshotGeneration = snapshotGeneration
        self.itemToken = itemToken
        self.sourceIndex = UInt64(sourceIndex)
    }

    init?(data: Data) {
        guard data.count == 32 else { return nil }
        func value(at start: Int) -> UInt64 {
            var result: UInt64 = 0
            for byte in 0..<8 {
                result |= UInt64(data[start + byte]) << (byte * 8)
            }
            return result
        }
        collectionID = value(at: 0)
        snapshotGeneration = value(at: 8)
        itemToken = value(at: 16)
        sourceIndex = value(at: 24)
    }
}

@MainActor
package final class CollectionInsertionPreview: View {
    override init() {
        super.init()
        isAccessibilityElement = false
        isHitTestingEnabled = false
        isHidden = true
    }

    package override func draw(in context: GraphicsContext) {
        context.fillColor = resolve(.role(.primary))
        context.fill(bounds)
    }
}
