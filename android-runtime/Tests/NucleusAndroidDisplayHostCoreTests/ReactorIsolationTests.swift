import Foundation
import Glibc
@testable import NucleusAndroidDisplayHostCore
import NucleusAndroidIPCC
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

@Test
@MainActor
func topologyHandshakeProgressesPastAnIdlePresentationConnection() async throws {
    let socketPath = "/tmp/ndh-\(UUID().uuidString)"
    let listener = socketPath.withCString {
        unsafe nucleus_android_ipc_listen($0, 0o600)
    }
    #expect(listener >= 0)
    guard listener >= 0 else { return }

    var descriptors = [listener]
    defer {
        for descriptor in descriptors where descriptor >= 0 {
            _ = close(descriptor)
        }
        _ = socketPath.withCString { unsafe unlink($0) }
    }

    let acceptReactor = try LinuxHostReactor()
    let presentationClient = socketPath.withCString {
        unsafe nucleus_android_ipc_connect($0)
    }
    #expect(presentationClient >= 0)
    guard presentationClient >= 0 else { return }
    descriptors.append(presentationClient)

    try await waitForDisplayHostReadable(
        listener,
        reactor: acceptReactor)
    let presentationHost = nucleus_android_ipc_accept(listener)
    #expect(presentationHost >= 0)
    guard presentationHost >= 0 else { return }
    descriptors.append(presentationHost)

    let presentationReactor = try LinuxHostReactor()
    async let presentationReady: Void = waitForDisplayHostReadable(
        presentationHost,
        reactor: presentationReactor)

    let topologyClient = socketPath.withCString {
        unsafe nucleus_android_ipc_connect($0)
    }
    #expect(topologyClient >= 0)
    guard topologyClient >= 0 else { return }
    descriptors.append(topologyClient)

    try await waitForDisplayHostReadable(
        listener,
        reactor: acceptReactor)
    let topologyHost = nucleus_android_ipc_accept(listener)
    #expect(topologyHost >= 0)
    guard topologyHost >= 0 else { return }
    descriptors.append(topologyHost)

    let topologyReactor = try LinuxHostReactor()
    async let topologyReady: Void = waitForDisplayHostReadable(
        topologyHost,
        reactor: topologyReactor)

    var topologyByte: UInt8 = 2
    #expect(unsafe write(topologyClient, &topologyByte, 1) == 1)
    try await topologyReady

    var presentationByte: UInt8 = 1
    #expect(unsafe write(presentationClient, &presentationByte, 1) == 1)
    try await presentationReady
}
