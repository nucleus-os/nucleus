import Glibc
import NucleusLinuxPrimitives
import NucleusLinuxPrimitivesC
import Testing

@Suite struct LinuxRuntimePrimitivesTests {
    @Test func ownedDescriptorClosesAtEndOfLifetime() {
        var descriptors = [Int32](repeating: -1, count: 2)
        let socketResult = descriptors.withUnsafeMutableBufferPointer {
            unsafe socketpair(
                AF_UNIX,
                Int32(SOCK_STREAM.rawValue | SOCK_CLOEXEC.rawValue),
                0,
                $0.baseAddress)
        }
        #expect(socketResult == 0)
        let observed = descriptors[0]
        let peer = descriptors[1]
        defer { close(peer) }

        do {
            let owned = LinuxOwnedFileDescriptor(adopting: observed)
            let borrowed = owned.withBorrowedDescriptor { $0.rawValue }
            #expect(borrowed == observed)
            #expect(fcntl(borrowed, F_GETFD) >= 0)
        }

        var byte: UInt8 = 0
        #expect(unsafe recv(peer, &byte, 1, Int32(MSG_DONTWAIT)) == 0)
    }

    @Test func duplicateHasIndependentOwnership() {
        var descriptors = [Int32](repeating: -1, count: 2)
        let pipeResult = descriptors.withUnsafeMutableBufferPointer {
            unsafe pipe($0.baseAddress)
        }
        #expect(pipeResult == 0)
        close(descriptors[1])

        let duplicateRaw: Int32
        do {
            let original = LinuxOwnedFileDescriptor(adopting: descriptors[0])
            guard let duplicate = original.duplicate() else {
                Issue.record("dup failed")
                return
            }
            duplicateRaw = duplicate.withBorrowedDescriptor { $0.rawValue }
        }

        errno = 0
        #expect(fcntl(duplicateRaw, F_GETFD) == -1)
        #expect(errno == EBADF)
    }

    @Test func sealedFilePublishesCompleteImmutableBytes() throws {
        let payload: [UInt8] = [1, 3, 5, 7, 9]
        let file = try LinuxSealedFile(
            name: "nucleus-primitives-test",
            bytes: payload)
        #expect(file.size == payload.count)

        file.withBorrowedDescriptor { borrowed in
            #expect(nucleus_linux_memfd_is_immutable(borrowed.rawValue) == 1)
            var result = [UInt8](repeating: 0, count: payload.count)
            let readCount = result.withUnsafeMutableBytes {
                unsafe pread(
                    borrowed.rawValue,
                    $0.baseAddress,
                    $0.count,
                    0)
            }
            #expect(readCount == payload.count)
            #expect(result == payload)
        }
    }
}
