import NucleusCompositorServer
import NucleusCompositorServerTypes
import NucleusCompositorWindowManager
import Glibc
@MainActor
extension InputDispatch {
    package func overlayScaleAtCursor() -> Double {
        for display in host.server.layout.displays {
            let r = display.logicalRect
            if cursorX >= r.x && cursorX < r.maxX && cursorY >= r.y && cursorY < r.maxY {
                return display.fractionalScale
            }
        }
        return 1
    }

    package func dispatchOverlayPointer(kind: UInt32, button: UInt32, timestampNs: UInt64) -> UInt32 {
        let scale = overlayScaleAtCursor()
        let result = host.server.shellPolicy?.overlayPointer(
            x: Float(cursorX * scale),
            y: Float(cursorY * scale),
            kind: kind,
            button: button,
            timestampNs: timestampNs) ?? 0
        let bits = UInt32(truncatingIfNeeded: result)
        applyOverlayResult(bits: bits)
        return bits
    }

    package func dispatchOverlayKey(
        keycode: UInt32, modifiers: UInt32, text: String?, kind: UInt32, timestampNs: UInt64
    ) -> UInt32 {
        let result = host.server.shellPolicy?.overlayKey(
            keycode: keycode, modifiers: modifiers, text: text,
            kind: kind, timestampNs: timestampNs) ?? 0
        let bits = UInt32(truncatingIfNeeded: result)
        applyOverlayResult(bits: bits)
        return bits
    }

    package func applyOverlayResult(bits: UInt32) {
        if bits & 4 != 0 {
            requestOverlayFrame()
        }
    }

    package func requestOverlayFrame() {
        let server = host.server
        RenderBridge.requestFrame(
            server: server,
            outputId: server.spaces.overlayDisplayID(
                layout: server.layout),
            reason: .shellOverlay)
    }

    package func workspaceTargetOutput() -> UInt64 {
        let surface = keyboardFocusID()
        if surface != 0 {
            let output = windowDriver?.windowOutput(forSurfaceId: UInt32(truncatingIfNeeded: surface)) ?? 0
            if output != 0 { return output }
        }
        let layout = host.server.layout
        return layout.primaryDisplayID() ?? layout.displays.first?.id ?? 0
    }

    package func raiseWindow(_ windowID: UInt64) {
        guard windowID != 0 else { return }
        if host.server.windows.raise(id: windowID) {
            RenderBridge.requestFrame(
                server: host.server,
                forWindowID: windowID)
        }
    }

    package func activateWorkspace(index: UInt32) {
        guard index != 0 else { return }
        let outputID = workspaceTargetOutput()
        guard outputID != 0 else { return }
        let server = host.server
        let spaceID = server.spaces.ensureWorkspace(onOutput: outputID, index: Int(index))
        guard spaceID != 0 else { return }
        if server.spaces.setActiveSpace(spaceID, forDisplay: outputID) {
            RenderBridge.requestFrame(server: server, outputId: outputID)
        }
    }

    package func moveFocusedWindowToWorkspace(index: UInt32) {
        guard index != 0 else { return }
        let surface = keyboardFocusID()
        guard surface != 0 else { return }
        let windowID = windowDriver?.windowId(forSurfaceId: UInt32(truncatingIfNeeded: surface)) ?? 0
        guard windowID != 0 else { return }
        var outputID = windowDriver?.windowOutput(forSurfaceId: UInt32(truncatingIfNeeded: surface)) ?? 0
        if outputID == 0 { outputID = workspaceTargetOutput() }
        guard outputID != 0 else { return }
        let server = host.server
        let spaceID = server.spaces.ensureWorkspace(onOutput: outputID, index: Int(index))
        guard spaceID != 0 else { return }
        if server.spaces.assign(window: windowID, toSpace: spaceID) {
            RenderBridge.requestFrame(server: server, outputId: outputID)
        }
    }

}
