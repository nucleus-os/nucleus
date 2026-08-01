import Dispatch
import Foundation
import NucleusCompositorServer
import Testing

@testable import NucleusCompositorPolicy

@Suite
@MainActor
struct ServerCursorThemeServiceTests {
    @Test func aMissAppliesFallbackWithoutWaitingForFilesystemWork() async {
        let gate = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let server = NucleusCompositorServer()
        let service = ServerCursorThemeService(
            server: server,
            fallback: cursorImage(byte: 1)
        ) { _, _ in
            started.signal()
            gate.wait()
            return cursorImage(byte: 2)
        }

        service.applyNamed("busy")
        #expect(server.cursor.themeName == "busy")
        #expect(server.cursor.pixels.first == 1)
        await Task.detached { started.wait() }.value
        #expect(server.cursor.pixels.first == 1)
        gate.signal()
        await waitForCursorByte(2, on: server)
        #expect(server.cursor.pixels.first == 2)
    }

    @Test func aStaleCompletionCannotReplaceTheNewestCursor() async {
        let slowGate = DispatchSemaphore(value: 0)
        let slowStarted = DispatchSemaphore(value: 0)
        let server = NucleusCompositorServer()
        let service = ServerCursorThemeService(
            server: server,
            fallback: cursorImage(byte: 1)
        ) { name, _ in
            if name == "slow" {
                slowStarted.signal()
                slowGate.wait()
                return cursorImage(byte: 2)
            }
            return cursorImage(byte: 3)
        }
        service.applyNamed("slow")
        await Task.detached { slowStarted.wait() }.value
        service.applyNamed("fast")
        await waitForCursorByte(3, on: server)
        #expect(server.cursor.themeName == "fast")
        #expect(server.cursor.pixels.first == 3)
        slowGate.signal()
        try? await Task.sleep(for: .milliseconds(10))
        #expect(server.cursor.themeName == "fast")
        #expect(server.cursor.pixels.first == 3)
    }
}

@MainActor
private func waitForCursorByte(
    _ byte: UInt8,
    on server: NucleusCompositorServer
) async {
    let deadline = ContinuousClock.now + .seconds(2)
    while server.cursor.pixels.first != byte, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(1))
    }
}

private func cursorImage(byte: UInt8) -> XCursorImage {
    XCursorImage(
        width: 1,
        height: 1,
        hotSpotX: 0,
        hotSpotY: 0,
        pixels: Data([byte, byte, byte, byte]))
}
