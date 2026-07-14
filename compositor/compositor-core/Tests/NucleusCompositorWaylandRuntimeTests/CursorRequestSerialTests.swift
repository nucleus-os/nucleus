// A7: wl_pointer.set_cursor serial/focus authorization (WlSeat.cursorRequestAuthorized).
// The request is honored only from the focused client with the matching enter serial.

import Testing
@testable import NucleusCompositorWaylandRuntime

@Suite struct CursorRequestSerialTests {
    // The focused client presenting the serial it was entered with is authorized.
    @Test func acceptsFocusedClientWithMatchingSerial() {
        #expect(WlSeat.cursorRequestAuthorized(
            requestClient: 42, requestSerial: 7, focusClient: 42, enterSerial: 7))
    }

    // A different client than the one holding focus is rejected, even with a valid serial.
    @Test func rejectsWrongClient() {
        #expect(!WlSeat.cursorRequestAuthorized(
            requestClient: 99, requestSerial: 7, focusClient: 42, enterSerial: 7))
    }

    // The focused client presenting a stale serial (an earlier enter) is rejected.
    @Test func rejectsStaleSerial() {
        #expect(!WlSeat.cursorRequestAuthorized(
            requestClient: 42, requestSerial: 5, focusClient: 42, enterSerial: 7))
    }

    // No client holds pointer focus (focusClient == 0): every request is rejected,
    // including one that happens to carry serial 0.
    @Test func rejectsWhenNoFocus() {
        #expect(!WlSeat.cursorRequestAuthorized(
            requestClient: 42, requestSerial: 7, focusClient: 0, enterSerial: 7))
        #expect(!WlSeat.cursorRequestAuthorized(
            requestClient: 0, requestSerial: 0, focusClient: 0, enterSerial: 0))
    }
}
