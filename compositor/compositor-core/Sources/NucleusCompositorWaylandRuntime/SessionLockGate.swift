import NucleusCompositorServer

@MainActor
private struct AwaitingLockedFrame {
    var outputID: UInt64
    var threshold: UInt64
}

@MainActor
final class SessionLockGate {
    private unowned let host: RouterHost
    private var active = false
    private var lockedSent = false
    private var awaiting: [AwaitingLockedFrame] = []
    private var keyboardFocusSurfaceID: UInt64 = 0

    init(host: RouterHost) {
        self.host = host
    }

    func begin() {
        // Retained pre-lock client pixels are forbidden once the security gate
        // activates, even though render-time context filtering would hide them.
        host.feeder?.cancelTransitionsForSessionLock()
        active = true
        lockedSent = false
        keyboardFocusSurfaceID = 0
        awaiting.removeAll(keepingCapacity: true)

        for display in host.server.layout.displays {
            awaiting.append(AwaitingLockedFrame(
                outputID: display.id,
                threshold: display.displayLink.peekNextPresentID()
            ))
            RenderBridge.requestFrame(
                server: host.server,
                outputId: display.id,
                reason: .lockTransition)
        }

        host.inputHost?.dispatch.clearKeyboardFocus()
        host.inputHost?.dispatch.clearPointerFocus()
    }

    func end() {
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

    func surfaceMapped(surfaceID: UInt64) {
        guard active, surfaceID != 0, isLockSurface(surfaceID: surfaceID) else { return }
        if keyboardFocusSurfaceID == 0 {
            keyboardEnter(surfaceID: surfaceID)
            keyboardFocusSurfaceID = surfaceID
        }
        requestFrameOnEveryOutput()
    }

    func noteOutputPresented(outputID: UInt64) {
        guard active, !lockedSent else { return }
        guard let display = host.server.layout.display(id: outputID) else { return }
        let acked = display.displayLink.lastAckedPresentID
        let live = Set(host.server.layout.displays.map(\.id))

        awaiting.removeAll { entry in
            (entry.outputID == outputID && acked >= entry.threshold) || !live.contains(entry.outputID)
        }

        if awaiting.isEmpty {
            lockedSent = true
            host.runtime?.sessionLock.currentLock?.emitLocked()
        }
    }

    func blocksSurface(surfaceID: UInt64) -> Bool {
        guard active else { return false }
        guard surfaceID != 0 else { return true }
        return !isLockSurface(surfaceID: surfaceID)
    }

    func isActive() -> Bool { active }

    private func requestFrameOnEveryOutput() {
        RenderBridge.requestFrame(
            server: host.server,
            outputId: 0, reason: .lockTransition)
    }

    private func isLockSurface(surfaceID: UInt64) -> Bool {
        host.runtime?.windowDriver.windowSource(
            forSurfaceId: UInt32(truncatingIfNeeded: surfaceID)) == WindowSource.lock.rawValue
    }

    private func keyboardEnter(surfaceID: UInt64) {
        guard let runtime = host.runtime,
            let surface = runtime.compositor.surface(id: UInt32(truncatingIfNeeded: surfaceID))
        else { return }
        let seat = runtime.seat
        seat.keyboardEnter(surface)
    }

    private func keyboardLeave(surfaceID: UInt64) {
        guard let runtime = host.runtime,
            let surface = runtime.compositor.surface(id: UInt32(truncatingIfNeeded: surfaceID))
        else { return }
        let seat = runtime.seat
        seat.keyboardLeave(surface)
    }
}
