import Testing
@testable import NucleusShellAuthWire
#if canImport(Glibc)
import Glibc
#endif

/// The wire format between the shell and its authentication helper, and a real
/// round trip through the helper binary itself.
///
/// The format crosses a process boundary that exists for isolation, so the
/// framing has to hold against a truncated, oversized, or absent peer — every
/// one of which must read as "the machinery failed", never as success.
@Suite struct PamHelperWireTests {
    /// A pipe pair for exercising the framing without a process.
    private func makePipe() -> (read: Int32, write: Int32) {
        var fds: [Int32] = [-1, -1]
        _ = pipe(&fds)
        return (fds[0], fds[1])
    }

    @Test func aFieldRoundTripsThroughAPipe() {
        let (readFD, writeFD) = makePipe()
        defer { close(readFD) }

        var buffer: [UInt8] = []
        PamHelperWire.encodeField(Array("login".utf8), into: &buffer)
        #expect(PamHelperWire.writeAll(buffer, to: writeFD))
        close(writeFD)

        let length = PamHelperWire.readLength(from: readFD, limit: 128)
        #expect(length == 5)
        let bytes = PamHelperWire.readExactly(5, from: readFD)
        #expect(bytes.map { String(decoding: $0, as: UTF8.self) } == "login")
    }

    @Test func anEmptyFieldRoundTrips() {
        let (readFD, writeFD) = makePipe()
        defer { close(readFD) }

        var buffer: [UInt8] = []
        PamHelperWire.encodeField([], into: &buffer)
        #expect(PamHelperWire.writeAll(buffer, to: writeFD))
        close(writeFD)

        #expect(PamHelperWire.readLength(from: readFD, limit: 128) == 0)
        #expect(PamHelperWire.readExactly(0, from: readFD) == [])
    }

    /// A length past the cap is refused rather than allocated. A hostile or
    /// broken peer must not be able to make the shell reserve arbitrary memory.
    @Test func anOversizedLengthIsRefused() {
        let (readFD, writeFD) = makePipe()
        defer { close(readFD) }

        var buffer: [UInt8] = []
        withUnsafeBytes(of: UInt32(1_000_000).littleEndian) { buffer.append(contentsOf: $0) }
        #expect(PamHelperWire.writeAll(buffer, to: writeFD))
        close(writeFD)

        #expect(PamHelperWire.readLength(from: readFD, limit: 4096) == nil)
    }

    /// A truncated payload is a failure, not a short success.
    @Test func aTruncatedPayloadIsRefused() {
        let (readFD, writeFD) = makePipe()
        defer { close(readFD) }

        #expect(PamHelperWire.writeAll([1, 2, 3], to: writeFD))
        close(writeFD)

        #expect(PamHelperWire.readExactly(16, from: readFD) == nil)
    }

    @Test func readingFromAClosedPipeFails() {
        let (readFD, writeFD) = makePipe()
        defer { close(readFD) }
        close(writeFD)

        #expect(PamHelperWire.readExactly(1, from: readFD) == nil)
        #expect(PamHelperWire.readLength(from: readFD, limit: 16) == nil)
    }

    @Test func outcomesHaveStableWireValues() {
        // The helper and the shell are separate binaries; these numbers are the
        // contract between them.
        #expect(PamHelperWire.Outcome.rejected.rawValue == 0)
        #expect(PamHelperWire.Outcome.accepted.rawValue == 1)
        #expect(PamHelperWire.Outcome.unavailable.rawValue == 2)
        #expect(PamHelperWire.Outcome(rawValue: 3) == nil)
    }

    // MARK: - The helper binary

    /// Run the built helper with a deliberately malformed request. It must
    /// answer `unavailable` and exit non-zero rather than hanging, crashing, or
    /// reporting success.
    ///
    /// This is the one test that exercises the real binary. It does not attempt
    /// a real authentication — that needs a PAM stack and a live password — but
    /// it does prove the process starts, speaks the protocol, and fails closed.
    @Test func theHelperFailsClosedOnAMalformedRequest() throws {
        let helper = try #require(helperPath(), "helper binary not built")

        var toHelper: [Int32] = [-1, -1]
        var fromHelper: [Int32] = [-1, -1]
        #expect(pipe(&toHelper) == 0)
        #expect(pipe(&fromHelper) == 0)

        var actions = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, toHelper[0], 0)
        posix_spawn_file_actions_adddup2(&actions, fromHelper[1], 1)
        // The parent's own ends must not survive into the child. Without this
        // the child inherits the request pipe's *write* end, so closing the
        // parent's copy never produces EOF and the helper blocks on `read`
        // forever. `PamAuthenticator.spawnHelper` closes them for the same
        // reason; leaving them out here deadlocked this test.
        posix_spawn_file_actions_addclose(&actions, toHelper[1])
        posix_spawn_file_actions_addclose(&actions, fromHelper[0])
        defer { posix_spawn_file_actions_destroy(&actions) }

        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(helper), nil]
        defer { argv.forEach { free($0) } }
        let spawned = argv.withUnsafeBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return posix_spawn(
                &pid, helper, &actions, nil, UnsafeMutablePointer(mutating: base), environ)
        }
        #expect(spawned == 0)

        close(toHelper[0])
        close(fromHelper[1])
        // Truncated request: a length header promising more than follows.
        var truncated: [UInt8] = []
        withUnsafeBytes(of: UInt32(64).littleEndian) { truncated.append(contentsOf: $0) }
        _ = PamHelperWire.writeAll(truncated, to: toHelper[1])
        close(toHelper[1])

        let header = PamHelperWire.readExactly(1, from: fromHelper[0])
        close(fromHelper[0])

        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}

        #expect(header?.first == PamHelperWire.Outcome.unavailable.rawValue)
        let exited = status & 0x7f == 0
        #expect(exited, "exited normally rather than crashing")
        #expect((status >> 8) & 0xff != PamHelperWire.exitAccepted,
                "and never reports success")
    }

    /// The helper sits beside the test bundle in the build directory.
    private func helperPath() -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBufferPointer { pointer -> Int in
            guard let base = pointer.baseAddress else { return -1 }
            return readlink("/proc/self/exe", base, pointer.count - 1)
        }
        guard count > 0 else { return nil }
        let executable = String(
            decoding: buffer[..<count].map { UInt8(bitPattern: $0) },
            as: UTF8.self)
        guard let slash = executable.lastIndex(of: "/") else { return nil }
        let candidate = String(executable[..<slash]) + "/NucleusShellPamHelper"
        return access(candidate, X_OK) == 0 ? candidate : nil
    }
}
