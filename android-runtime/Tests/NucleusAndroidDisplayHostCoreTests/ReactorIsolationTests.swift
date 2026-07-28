import Glibc
@testable import NucleusAndroidDisplayHostCore
import NucleusLinuxReactor
import Testing

@Test
@MainActor
func displayHostSocketWaitsUseIndependentReactors() async throws {
    var listenerPipe = [Int32](repeating: -1, count: 2)
    var handshakePipe = [Int32](repeating: -1, count: 2)
    #expect(unsafe pipe(&listenerPipe) == 0)
    #expect(unsafe pipe(&handshakePipe) == 0)
    defer {
        for descriptor in listenerPipe + handshakePipe {
            if descriptor >= 0 {
                _ = close(descriptor)
            }
        }
    }

    let acceptReactor = try LinuxHostReactor()
    let handshakeReactor = try LinuxHostReactor()
    let listenerRead = listenerPipe[0]
    let listenerWrite = listenerPipe[1]
    let handshakeRead = handshakePipe[0]
    let handshakeWrite = handshakePipe[1]
    async let listenerReady: Void = waitForDisplayHostReadable(
        listenerRead,
        reactor: acceptReactor)
    async let handshakeReady: Void = waitForDisplayHostReadable(
        handshakeRead,
        reactor: handshakeReactor)

    var byte: UInt8 = 1
    #expect(unsafe write(listenerWrite, &byte, 1) == 1)
    #expect(unsafe write(handshakeWrite, &byte, 1) == 1)
    try await listenerReady
    try await handshakeReady
}
