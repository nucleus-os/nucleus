internal import NucleusCompositorServer
import NucleusCompositorServerTypes
internal import NucleusCompositorWindowManager
import Glibc
@MainActor
extension InputDispatch {
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
