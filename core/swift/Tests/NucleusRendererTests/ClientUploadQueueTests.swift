import Testing
@testable import NucleusRenderer

@Suite struct PendingShmUploadTests {
    private func upload(_ byte: UInt8, generation: UInt64, bytes: Int = 16) -> PendingShmUpload {
        PendingShmUpload(
            pixels: [UInt8](repeating: byte, count: bytes),
            width: 2, height: Int32(max(1, bytes / 8)), generation: generation)
    }

    @Test func coalescesToNewestGenerationPerSurface() {
        var queue = PendingShmUploadQueue()
        let firstReplaced = queue.enqueue(upload(1, generation: 1), for: 7)
        let secondReplaced = queue.enqueue(upload(2, generation: 2), for: 7)
        let thirdReplaced = queue.enqueue(upload(3, generation: 3), for: 7)
        #expect(!firstReplaced)
        #expect(secondReplaced)
        #expect(thirdReplaced)
        #expect(queue.count == 1)
        #expect(queue.byteCount == 16)

        let drained = queue.drain()
        #expect(drained[7]?.generation == 3)
        #expect(drained[7]?.pixels.first == 3)
        #expect(queue.isEmpty)
        #expect(queue.byteCount == 0)
    }

    @Test func boundsMemoryToOnePayloadPerSurface() {
        var queue = PendingShmUploadQueue()
        _ = queue.enqueue(upload(1, generation: 1, bytes: 64), for: 1)
        _ = queue.enqueue(upload(2, generation: 1, bytes: 32), for: 2)
        #expect(queue.byteCount == 96)
        _ = queue.enqueue(upload(3, generation: 2, bytes: 16), for: 1)
        #expect(queue.byteCount == 48)
        #expect(queue.count == 2)
    }

    @Test func removalUpdatesPendingMemory() {
        var queue = PendingShmUploadQueue()
        _ = queue.enqueue(upload(1, generation: 1, bytes: 20), for: 4)
        _ = queue.enqueue(upload(2, generation: 1, bytes: 12), for: 5)
        #expect(queue.remove(4)?.generation == 1)
        #expect(queue.byteCount == 12)
        #expect(queue.remove(99) == nil)
        queue.removeAll()
        #expect(queue.isEmpty)
        #expect(queue.byteCount == 0)
    }
}
