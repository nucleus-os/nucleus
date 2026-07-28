import Glibc
import NucleusWindowClientRuntime
import NucleusUI
import Testing
@testable import NucleusWindowClientPasteboard

@MainActor
@Suite struct PasteboardTransferExecutorTests {
    @Test func MIMEPreferenceDoesNotDependOnOfferOrder() {
        #expect(NucleusDesktopPasteboardAdapter.preferredPlainTextMIMEType(
            in: ["text/plain", "UTF8_STRING"])
            == "UTF8_STRING")
        #expect(NucleusDesktopPasteboardAdapter.preferredPlainTextMIMEType(
            in: ["application/json"]) == nil)
    }

    @Test func readWaitsForReadinessAndCombinesPartialPayload() throws {
        let descriptors = try makePipe()
        let readFD = descriptors[0]
        let writeFD = descriptors[1]
        var result: Result<[UInt8], DataTransferFailure>?
        let executor = DataTransferExecutor { _, _ in }
        let token = executor.installRead(
            owning: TransferFileDescriptor(owning: readFD),
            operation: "test-read",
            byteLimit: 128,
            deadlineNanoseconds: 1_000
        ) {
            result = $0
        }

        let firstWrite = unsafe write(writeFD, "hel", 3)
        #expect(firstWrite == 3)
        #expect(result == nil)
        executor.processPollResult(
            token: token,
            result: NucleusWindowClientPollResult(revents: Int16(POLLIN)),
            nowNanoseconds: 1)
        #expect(result == nil)

        let secondWrite = unsafe write(writeFD, "lo", 2)
        #expect(secondWrite == 2)
        close(writeFD)
        executor.processPollResult(
            token: token,
            result: NucleusWindowClientPollResult(revents: Int16(POLLIN | POLLHUP)),
            nowNanoseconds: 2)
        #expect(try result?.get() == Array("hello".utf8))
        #expect(executor.activeTransferCount == 0)
        #expect(fcntl(readFD, F_GETFD) == -1)
        #expect(errno == EBADF)
    }

    @Test func readRejectsPayloadBeforeAppendingPastLimit() throws {
        let descriptors = try makePipe()
        let readFD = descriptors[0]
        let writeFD = descriptors[1]
        var result: Result<[UInt8], DataTransferFailure>?
        let executor = DataTransferExecutor { _, _ in }
        let token = executor.installRead(
            owning: TransferFileDescriptor(owning: readFD),
            operation: "test-read",
            byteLimit: 4,
            deadlineNanoseconds: 1_000
        ) {
            result = $0
        }
        let oversizedWrite = unsafe write(writeFD, "12345", 5)
        #expect(oversizedWrite == 5)
        close(writeFD)

        executor.processPollResult(
            token: token,
            result: NucleusWindowClientPollResult(revents: Int16(POLLIN | POLLHUP)),
            nowNanoseconds: 1)

        do {
            _ = try result?.get()
            Issue.record("oversized selection unexpectedly succeeded")
        } catch let failure {
            #expect(failure == .transport("transfer exceeded 4 byte limit"))
        }
        #expect(executor.activeTransferCount == 0)
    }

    @Test func cancellationCompletesReadAndClosesDescriptorOnce() throws {
        let descriptors = try makePipe()
        let readFD = descriptors[0]
        defer { close(descriptors[1]) }
        var result: Result<[UInt8], DataTransferFailure>?
        let executor = DataTransferExecutor { _, _ in }
        let token = executor.installRead(
            owning: TransferFileDescriptor(owning: readFD),
            operation: "test-read",
            byteLimit: 4,
            deadlineNanoseconds: 1_000
        ) {
            result = $0
        }

        executor.cancelRead(token: token)
        executor.cancelRead(token: token)

        do {
            _ = try result?.get()
            Issue.record("cancelled selection unexpectedly succeeded")
        } catch let failure {
            #expect(failure == .cancelled)
        }
        #expect(fcntl(readFD, F_GETFD) == -1)
        #expect(errno == EBADF)
    }

    @Test func timeoutClosesPendingRead() throws {
        let descriptors = try makePipe()
        let readFD = descriptors[0]
        defer { close(descriptors[1]) }
        var result: Result<[UInt8], DataTransferFailure>?
        let executor = DataTransferExecutor { _, _ in }
        _ = executor.installRead(
            owning: TransferFileDescriptor(owning: readFD),
            operation: "test-read",
            byteLimit: 4,
            deadlineNanoseconds: 10
        ) {
            result = $0
        }

        #expect(executor.nanosecondsUntilDeadline(nowNanoseconds: 4) == 6)
        executor.expireTransfers(nowNanoseconds: 10)

        do {
            _ = try result?.get()
            Issue.record("expired selection unexpectedly succeeded")
        } catch let failure {
            #expect(failure == .transport("transfer timed out"))
        }
        #expect(executor.activeTransferCount == 0)
    }

    @Test func writeHandlesBackpressureAndPartialProgress() throws {
        let descriptors = try makePipe()
        let readFD = descriptors[0]
        let writeFD = descriptors[1]
        defer { close(readFD) }
        _ = fcntl(writeFD, F_SETPIPE_SZ, 4_096)

        let payload = [UInt8](repeating: 0x61, count: 32 * 1024)
        let executor = DataTransferExecutor { _, failure in
            Issue.record("write failed: \(failure)")
        }
        guard let token = executor.installWrite(
            owning: TransferFileDescriptor(owning: writeFD),
            operation: "test-write",
            payload: payload,
            deadlineNanoseconds: 1_000)
        else {
            Issue.record("non-empty write did not install")
            return
        }

        executor.processPollResult(
            token: token,
            result: NucleusWindowClientPollResult(revents: Int16(POLLOUT)),
            nowNanoseconds: 1)
        #expect(executor.activeTransferCount == 1)

        var received = [UInt8]()
        var scratch = [UInt8](repeating: 0, count: 8 * 1024)
        while executor.activeTransferCount > 0 {
            let count = unsafe read(readFD, &scratch, scratch.count)
            if count > 0 {
                received.append(contentsOf: scratch.prefix(Int(count)))
            }
            executor.processPollResult(
                token: token,
                result: NucleusWindowClientPollResult(revents: Int16(POLLOUT)),
                nowNanoseconds: 2)
        }
        while true {
            let count = unsafe read(readFD, &scratch, scratch.count)
            guard count > 0 else { break }
            received.append(contentsOf: scratch.prefix(Int(count)))
        }
        #expect(received == payload)
        #expect(fcntl(writeFD, F_GETFD) == -1)
        #expect(errno == EBADF)
    }

    private func makePipe() throws -> [Int32] {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard unsafe pipe2(&descriptors, O_CLOEXEC | O_NONBLOCK) == 0 else {
            throw PasteboardFailure.transport(
                "pipe2 failed: \(unsafe String(cString: strerror(errno)))")
        }
        return descriptors
    }
}
