import Glibc
import NucleusBenchmarkSupport
import Testing

@Test
func resourceSnapshotCountsLiveFileDescriptors() throws {
    let before = try BenchmarkResourceSnapshot.capture()
    var descriptors = [Int32](repeating: -1, count: 2)
    let result = descriptors.withUnsafeMutableBufferPointer { buffer in
        pipe(buffer.baseAddress!)
    }
    #expect(result == 0)
    guard result == 0 else { return }
    defer {
        close(descriptors[0])
        close(descriptors[1])
    }

    let whilePipeIsOpen = try BenchmarkResourceSnapshot.capture()
    #expect(
        whilePipeIsOpen.openFileDescriptors
            >= before.openFileDescriptors + UInt64(descriptors.count))
    #expect(whilePipeIsOpen.maximumResidentBytes > 0)
    #expect(whilePipeIsOpen.allocatorMappedBytes >= whilePipeIsOpen.heapLiveBytes)
}
