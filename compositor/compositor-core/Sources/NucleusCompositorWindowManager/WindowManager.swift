public import NucleusCompositorServer

@MainActor
public final class WindowManager {
    public struct InteractiveStartContext {
        public var cursorX: Double
        public var cursorY: Double
        public var startRect: WindowRect
    }

    public let server: NucleusCompositorServer
    public var interaction = InteractionState()
    public var layerShellPolicy = LayerShellPolicy()
    public let backdropResolver = BackdropResolver()
    private var pendingInteractionStarts: [UInt64: InteractiveStartContext] = [:]
    var xdgRolesByWindow: [UInt64: XdgRole] = [:]
    var xdgWindowByToplevel: [UInt64: UInt64] = [:]
    var xdgToplevelByWindow: [UInt64: UInt64] = [:]
    var xwaylandRolesByWindow: [UInt64: XwaylandRole] = [:]
    var xwaylandWindowByXID: [UInt64: UInt64] = [:]
    var xwaylandXIDByWindow: [UInt64: UInt64] = [:]
    var activeXwaylandWindowID: UInt64?

    public init(server: NucleusCompositorServer) {
        self.server = server
    }

    public func reset() {
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

    public func seedInteractiveStartContext(windowID: UInt64, cursorX: Double, cursorY: Double, startRect: WindowRect) {
        pendingInteractionStarts[windowID] = InteractiveStartContext(cursorX: cursorX, cursorY: cursorY, startRect: startRect)
    }

    public func takeInteractiveStartContext(windowID: UInt64) -> InteractiveStartContext {
        if let context = pendingInteractionStarts.removeValue(forKey: windowID) {
            return context
        }
        return InteractiveStartContext(cursorX: 0, cursorY: 0, startRect: WindowRect())
    }
}
