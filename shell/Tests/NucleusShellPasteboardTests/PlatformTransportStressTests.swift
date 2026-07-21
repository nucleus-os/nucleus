import Glibc
import NucleusShellLoop
import Testing
@testable import NucleusShellPasteboard

@MainActor
@Suite struct NucleusPlatformTransportStressTests {
    /// The bound is machine-independent: one installed read owns one descriptor,
    /// one poll entry, one completion, and exactly two poll-set publications
    /// (installation and terminal removal), regardless of payload size.
    @Test func transferBurstHasLinearBoundedOwnershipAndTeardown() throws {
        let transferCount = 128
        let payload = Array("nucleus-transport-stress-payload".utf8)
        var pollSetPublications = 0
        var completions = 0
        var copiedBytes = 0
        var writeDescriptors: [Int32] = []
        var readDescriptors: [Int32] = []
        let executor = DataTransferExecutor(
            pollSetDidChange: { pollSetPublications += 1 },
            failureHandler: { operation, failure in
                Issue.record("\(operation) failed: \(failure)")
            })

        for index in 0..<transferCount {
            let descriptors = try makePipe()
            readDescriptors.append(descriptors[0])
            writeDescriptors.append(descriptors[1])
            _ = executor.installRead(
                owning: TransferFileDescriptor(owning: descriptors[0]),
                operation: "stress-read-\(index)",
                byteLimit: payload.count,
                deadlineNanoseconds: 10_000
            ) { result in
                do {
                    let bytes = try result.get()
                    #expect(bytes == payload)
                    completions += 1
                    copiedBytes += bytes.count
                } catch {
                    Issue.record("stress read failed: \(error)")
                }
            }
        }

        #expect(executor.activeTransferCount == transferCount)
        #expect(executor.pollDescriptors.count == transferCount)
        #expect(Set(executor.pollDescriptors.map(\.token)).count == transferCount)
        #expect(Set(executor.pollDescriptors.map(\.fileDescriptor)).count == transferCount)
        #expect(pollSetPublications == transferCount)

        for descriptor in writeDescriptors {
            let count = payload.withUnsafeBytes {
                write(descriptor, $0.baseAddress, $0.count)
            }
            #expect(count == payload.count)
            #expect(close(descriptor) == 0)
        }
        for descriptor in executor.pollDescriptors {
            executor.processPollResult(
                token: descriptor.token,
                result: ShellPollResult(revents: Int16(POLLIN | POLLHUP)),
                nowNanoseconds: 1)
        }

        #expect(completions == transferCount)
        #expect(copiedBytes == transferCount * payload.count)
        #expect(executor.activeTransferCount == 0)
        #expect(executor.pollDescriptors.isEmpty)
        #expect(pollSetPublications == transferCount * 2)
        for descriptor in readDescriptors {
            #expect(fcntl(descriptor, F_GETFD) == -1)
            #expect(errno == EBADF)
        }

        executor.shutdown()
        #expect(pollSetPublications == transferCount * 2)
    }

    private func makePipe() throws -> [Int32] {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard pipe2(&descriptors, O_CLOEXEC | O_NONBLOCK) == 0 else {
            throw DataTransferFailure.transport(
                "pipe2 failed: "
                    + String(
                        decodingCString: UnsafeRawPointer(strerror(errno))
                            .assumingMemoryBound(to: UInt8.self),
                        as: UTF8.self))
        }
        return descriptors
    }
}
