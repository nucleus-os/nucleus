import Glibc
import NucleusIPCTransport
import Testing

private func temporaryDirectory() throws -> String {
    var template = Array(
        "/tmp/nucleus-ipc-listener-XXXXXX".utf8) + [UInt8(0)]
    return try template.withUnsafeMutableBytes { bytes in
        let characters = unsafe bytes.baseAddress!
            .assumingMemoryBound(to: CChar.self)
        guard unsafe (Glibc.mkdtemp(characters) != nil) else {
            throw IPCTransportError.systemCall(
                operation: "mkdtemp",
                errno: errno)
        }
        return unsafe String(cString: characters)
    }
}

@Suite struct PacketTransportTests {
    @Test func socketPairPreservesOnePacketBoundary() throws {
        let (sender, receiver) = try PacketConnection.socketPair()
        try sender.send([1, 2, 3, 4])
        let packet = try receiver.receive(maximumBytes: 16)
        #expect(packet.bytes == [1, 2, 3, 4])
        #expect(packet.descriptors.isEmpty)
    }

    @Test func socketPairTransfersOwnedDescriptors() throws {
        let (sender, receiver) = try PacketConnection.socketPair()
        var pipeDescriptors = [Int32](repeating: -1, count: 2)
        let pipeResult = unsafe Glibc.pipe(&pipeDescriptors)
        #expect(pipeResult == 0)
        defer {
            _ = Glibc.close(pipeDescriptors[0])
            _ = Glibc.close(pipeDescriptors[1])
        }

        try sender.send([7], descriptors: [pipeDescriptors[0]])
        let packet = try receiver.receive(
            maximumBytes: 16,
            maximumDescriptors: 1)
        #expect(packet.bytes == [7])
        #expect(packet.descriptors.count == 1)
        #expect(packet.descriptors[0].rawValue >= 0)
    }

    @Test func peerCredentialsDescribeThisProcess() throws {
        let (first, _) = try PacketConnection.socketPair()
        let credentials = try #require(first.peerCredentials)
        #expect(credentials.processID == Glibc.getpid())
        #expect(credentials.userID == Glibc.geteuid())
        #expect(credentials.groupID == Glibc.getegid())
    }

    @Test func listenerUsesOwnerOnlyModeAndRetainsAReplacementPath()
        throws
    {
        let directoryPath = try temporaryDirectory()
        defer { _ = directoryPath.withCString { unsafe Glibc.rmdir($0) } }
        let path = directoryPath + "/control.sock"

        var original: PacketListener? = try PacketListener(path: path)
        var metadata = stat()
        #expect(path.withCString {
            unsafe Glibc.lstat($0, &metadata)
        } == 0)
        #expect(metadata.st_mode & 0o777 == 0o600)

        let replacement = try PacketListener(path: path)
        original = nil
        #expect(path.withCString {
            unsafe Glibc.lstat($0, &metadata)
        } == 0)
        let client = try PacketConnection.connect(path: path)
        let server = try replacement.accept()
        try client.send([7])
        #expect(try server.receive(maximumBytes: 1).bytes == [7])
        _ = original
    }

    @Test func listenerDoesNotReplaceANonSocketEntry() throws {
        let directoryPath = try temporaryDirectory()
        let path = directoryPath + "/control.sock"
        defer {
            _ = path.withCString { unsafe Glibc.unlink($0) }
            _ = directoryPath.withCString { unsafe Glibc.rmdir($0) }
        }
        let descriptor = path.withCString {
            unsafe Glibc.open($0, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        }
        #expect(descriptor >= 0)
        if descriptor >= 0 { _ = Glibc.close(descriptor) }

        #expect(throws: IPCTransportError.self) {
            _ = try PacketListener(path: path)
        }
        var metadata = stat()
        #expect(path.withCString {
            unsafe Glibc.lstat($0, &metadata)
        } == 0)
        #expect(metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG))
    }
}
