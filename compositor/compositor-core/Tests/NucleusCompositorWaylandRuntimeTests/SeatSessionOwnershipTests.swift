import Testing
import NucleusCompositorInputC
@testable import NucleusCompositorWaylandRuntime

@MainActor
@Suite(.serialized)
struct SeatSessionOwnershipTests {
    @Test
    func failedNativeOpenReleasesListenerExactlyOnce() {
        for _ in 0..<256 {
            let session = unsafe SeatSession.open(using: .init(
                open: { _, _ in nil },
                close: { _ in Issue.record("failed open attempted close"); return 0 },
                disable: { _ in Issue.record("failed open attempted disable"); return 0 }))
            #expect(session == nil)
        }
    }

    @Test
    func deferredDisableIsAcknowledgedExactlyOnceAndClosesExactlyOnce() {
        let fakeHandle = unsafe OpaquePointer(bitPattern: 1)!
        var listener: libseat_seat_listener?
        var userdata: UnsafeMutableRawPointer?
        var disableCalls = 0
        var closeCalls = 0
        var session: SeatSession? = unsafe SeatSession.open(using: .init(
            open: {
                unsafe listener = $0?.pointee
                unsafe userdata = $1
                return unsafe fakeHandle
            },
            close: { handle in
                #expect(unsafe handle == fakeHandle)
                closeCalls += 1
                return 0
            },
            disable: { handle in
                #expect(unsafe handle == fakeHandle)
                disableCalls += 1
                return 0
            }))
        #expect(session != nil)
        session?.onDisable = { false }

        unsafe listener?.disable_seat?(fakeHandle, userdata)
        #expect(disableCalls == 0)
        session?.completeDisableAcknowledgement()
        session?.completeDisableAcknowledgement()
        #expect(disableCalls == 1)

        // A repeated libseat request is a new obligation, while repeated
        // completion attempts for one request remain inert.
        unsafe listener?.disable_seat?(fakeHandle, userdata)
        session?.completeDisableAcknowledgement()
        session?.completeDisableAcknowledgement()
        #expect(disableCalls == 2)
        session = nil
        #expect(closeCalls == 1)
    }
}
