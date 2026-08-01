package import NucleusCompositorServer

@MainActor
package final class WindowManager {
    package struct InteractiveStartContext {
        package var cursorX: Double
        package var cursorY: Double
        package var startRect: WindowRect
    }

    package let server: NucleusCompositorServer
    package var interaction = InteractionState()
    package var layerShellPolicy = LayerShellPolicy()
    package let backdropResolver = BackdropResolver()
    private var pendingInteractionStarts: [UInt64: InteractiveStartContext] = [:]
    var xdgRolesByWindow: [UInt64: XdgRole] = [:]
    var xdgWindowByToplevel: [XdgToplevelID: UInt64] = [:]
    var xdgToplevelByWindow: [UInt64: XdgToplevelID] = [:]
    var xwaylandRolesByWindow: [UInt64: XwaylandRole] = [:]
    var xwaylandWindowByXID: [UInt64: UInt64] = [:]
    var xwaylandXIDByWindow: [UInt64: UInt64] = [:]
    var activeXwaylandWindowID: UInt64?

    package init(server: NucleusCompositorServer) {
        self.server = server
    }

    package func reset() {
        pendingInteractionStarts.removeAll(keepingCapacity: true)
        xdgRolesByWindow.removeAll(keepingCapacity: true)
        xdgWindowByToplevel.removeAll(keepingCapacity: true)
        xdgToplevelByWindow.removeAll(keepingCapacity: true)
        xwaylandRolesByWindow.removeAll(keepingCapacity: true)
        xwaylandWindowByXID.removeAll(keepingCapacity: true)
        xwaylandXIDByWindow.removeAll(keepingCapacity: true)
        activeXwaylandWindowID = nil
        layerShellPolicy.reset()
        interaction.reset()
    }

    package func seedInteractiveStartContext(
        windowID: UInt64, cursorX: Double, cursorY: Double, startRect: WindowRect
    ) {
        pendingInteractionStarts[windowID] = InteractiveStartContext(
            cursorX: cursorX, cursorY: cursorY, startRect: startRect)
    }

    package func takeInteractiveStartContext(windowID: UInt64) -> InteractiveStartContext {
        if let context = pendingInteractionStarts.removeValue(forKey: windowID) {
            return context
        }
        return InteractiveStartContext(cursorX: 0, cursorY: 0, startRect: WindowRect())
    }
}
