import NucleusCompositorServer

@MainActor
private struct AwaitingLockedFrame {
    var outputID: UInt64
    var threshold: UInt64
}

@MainActor
enum SessionLockGate {
    private static var active = false
    private static var lockedSent = false
    private static var awaiting: [AwaitingLockedFrame] = []
    private static var keyboardFocusSurfaceID: UInt64 = 0

    static func begin() {
        active = true
        lockedSent = false
        keyboardFocusSurfaceID = 0
        awaiting.removeAll(keepingCapacity: true)

        for display in NucleusCompositorServer.shared.layout.displays {
            awaiting.append(AwaitingLockedFrame(
                outputID: display.id,
                threshold: display.displayLink.peekNextPresentID()
            ))
            display.displayLink.requestFrame()
        }

        RouterHost.shared.inputHost?.dispatch.clearKeyboardFocus()
        RouterHost.shared.inputHost?.dispatch.clearPointerFocus()
    }

    static func end() {
        guard active else { return }
        if keyboardFocusSurfaceID != 0 {
            keyboardLeave(surfaceID: keyboardFocusSurfaceID)
        }
        active = false
        lockedSent = false
        keyboardFocusSurfaceID = 0
        awaiting.removeAll(keepingCapacity: true)
        requestFrameOnEveryOutput()
    }

    static func surfaceMapped(surfaceID: UInt64) {
        guard active, surfaceID != 0, isLockSurface(surfaceID: surfaceID) else { return }
        if keyboardFocusSurfaceID == 0 {
            keyboardEnter(surfaceID: surfaceID)
            keyboardFocusSurfaceID = surfaceID
        }
        requestFrameOnEveryOutput()
    }

    static func noteOutputPresented(outputID: UInt64) {
        guard active, !lockedSent else { return }
        guard let display = NucleusCompositorServer.shared.layout.display(id: outputID) else { return }
        let acked = display.displayLink.lastAckedPresentID
        let live = Set(NucleusCompositorServer.shared.layout.displays.map(\.id))

        awaiting.removeAll { entry in
            (entry.outputID == outputID && acked >= entry.threshold) || !live.contains(entry.outputID)
        }

        if awaiting.isEmpty {
            lockedSent = true
            RouterHost.shared.runtime?.sessionLock.currentLock?.emitLocked()
        }
    }

    static func blocksSurface(surfaceID: UInt64) -> Bool {
        guard active else { return false }
        guard surfaceID != 0 else { return true }
        return !isLockSurface(surfaceID: surfaceID)
    }

    static func isActive() -> Bool { active }

    private static func requestFrameOnEveryOutput() {
        for display in NucleusCompositorServer.shared.layout.displays {
            display.displayLink.requestFrame()
        }
    }

    private static func isLockSurface(surfaceID: UInt64) -> Bool {
        RouterHost.shared.runtime?.windowDriver.windowSource(
            forSurfaceId: UInt32(truncatingIfNeeded: surfaceID)) == WindowSource.lock.rawValue
    }

    private static func keyboardEnter(surfaceID: UInt64) {
        guard let runtime = RouterHost.shared.runtime,
            let surface = runtime.compositor.surface(id: UInt32(truncatingIfNeeded: surfaceID))
        else { return }
        let seat = runtime.seat
        seat.keyboardEnter(surface)
    }

    private static func keyboardLeave(surfaceID: UInt64) {
        guard let runtime = RouterHost.shared.runtime,
            let surface = runtime.compositor.surface(id: UInt32(truncatingIfNeeded: surfaceID))
        else { return }
        let seat = runtime.seat
        seat.keyboardLeave(surface)
    }
}
