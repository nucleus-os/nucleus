import NucleusTypes
public import NucleusCompositorServerTypes
public import NucleusCompositorServer

public enum WindowInteraction {
    case idle
    case movePending(windowID: UInt64, startCursorX: Double, startCursorY: Double, startRect: WindowRect)
    case moveActive(windowID: UInt64, startCursorX: Double, startCursorY: Double, startRect: WindowRect)
    case resizePending(windowID: UInt64, startCursorX: Double, startCursorY: Double, startRect: WindowRect, edges: WireResizeEdges)
    case resizeActive(windowID: UInt64, startCursorX: Double, startCursorY: Double, startRect: WindowRect, edges: WireResizeEdges)

    public var windowID: UInt64? {
        switch self {
        case .idle:
            nil
        case .movePending(let windowID, _, _, _),
             .moveActive(let windowID, _, _, _),
             .resizePending(let windowID, _, _, _, _),
             .resizeActive(let windowID, _, _, _, _):
            windowID
        }
    }

    public var hasGrab: Bool {
        if case .idle = self { return false }
        return true
    }

    public mutating func activate() {
        switch self {
        case .movePending(let windowID, let startCursorX, let startCursorY, let startRect):
            self = .moveActive(windowID: windowID, startCursorX: startCursorX, startCursorY: startCursorY, startRect: startRect)
        case .resizePending(let windowID, let startCursorX, let startCursorY, let startRect, let edges):
            self = .resizeActive(windowID: windowID, startCursorX: startCursorX, startCursorY: startCursorY, startRect: startRect, edges: edges)
        case .idle, .moveActive, .resizeActive:
            break
        }
    }

    public mutating func clear(forWindow id: UInt64) {
        if windowID == id {
            self = .idle
        }
    }

    public func update(cursorX: Double, cursorY: Double) -> WireInteractionGrabUpdate {
        switch self {
        case .idle:
            return WireInteractionGrabUpdate()
        case .movePending(let windowID, let startCursorX, let startCursorY, let startRect),
             .moveActive(let windowID, let startCursorX, let startCursorY, let startRect):
            var update = WireInteractionGrabUpdate()
            update.hasUpdate = true
            update.mode = .move
            update.windowId = windowID
            update.needsResizeConfigure = false
            update.rect = WindowRect(
                x: startRect.x + (cursorX - startCursorX),
                y: startRect.y + (cursorY - startCursorY),
                width: startRect.width,
                height: startRect.height
            ).wireValue
            return update
        case .resizePending(let windowID, let startCursorX, let startCursorY, let startRect, let edges),
             .resizeActive(let windowID, let startCursorX, let startCursorY, let startRect, let edges):
            var update = WireInteractionGrabUpdate()
            update.hasUpdate = true
            update.mode = .resize
            update.windowId = windowID
            update.needsResizeConfigure = true
            update.rect = resizeRect(
                startCursorX: startCursorX,
                startCursorY: startCursorY,
                startRect: startRect,
                edges: edges,
                cursorX: cursorX,
                cursorY: cursorY
            ).wireValue
            return update
        }
    }

    private func resizeRect(
        startCursorX: Double,
        startCursorY: Double,
        startRect: WindowRect,
        edges: WireResizeEdges,
        cursorX: Double,
        cursorY: Double
    ) -> WindowRect {
        let minExtent = 64.0
        let dx = cursorX - startCursorX
        let dy = cursorY - startCursorY
        let startLeft = startRect.x
        let startTop = startRect.y
        let startRight = startRect.x + Double(startRect.width)
        let startBottom = startRect.y + Double(startRect.height)

        var left = startLeft
        var top = startTop
        var right = startRight
        var bottom = startBottom

        if edges.left { left = startLeft + dx }
        if edges.right { right = startRight + dx }
        if edges.top { top = startTop + dy }
        if edges.bottom { bottom = startBottom + dy }

        if right - left < minExtent {
            if edges.left && !edges.right {
                left = right - minExtent
            } else {
                right = left + minExtent
            }
        }
        if bottom - top < minExtent {
            if edges.top && !edges.bottom {
                top = bottom - minExtent
            } else {
                bottom = top + minExtent
            }
        }

        return WindowRect(
            x: left,
            y: top,
            width: UInt32(max(1.0, (right - left).rounded(.up))),
            height: UInt32(max(1.0, (bottom - top).rounded(.up)))
        )
    }
}

@MainActor
public struct InteractionState {
    public private(set) var windowInteraction: WindowInteraction = .idle
    private var nextLayoutTransitionID: UInt64 = 1

    public init() {}

    public mutating func allocLayoutTransitionID() -> UInt64 {
        let id = nextLayoutTransitionID
        nextLayoutTransitionID &+= 1
        if nextLayoutTransitionID == 0 { nextLayoutTransitionID = 1 }
        return id
    }

    public mutating func beginInteractiveMove(
        windowID: UInt64,
        cursorX: Double,
        cursorY: Double,
        startRect: WindowRect
    ) {
        windowInteraction = .movePending(windowID: windowID, startCursorX: cursorX, startCursorY: cursorY, startRect: startRect)
        windowInteraction.activate()
    }

    public mutating func beginInteractiveResize(
        windowID: UInt64,
        cursorX: Double,
        cursorY: Double,
        startRect: WindowRect,
        edges: WireResizeEdges
    ) {
        windowInteraction = .resizePending(
            windowID: windowID,
            startCursorX: cursorX,
            startCursorY: cursorY,
            startRect: startRect,
            edges: edges
        )
        windowInteraction.activate()
    }

    public var hasGrab: Bool {
        windowInteraction.hasGrab
    }

    public mutating func updateInteractiveGrab(cursorX: Double, cursorY: Double) -> WireInteractionGrabUpdate {
        windowInteraction.update(cursorX: cursorX, cursorY: cursorY)
    }

    public mutating func finishInteractiveGrab() {
        windowInteraction = .idle
    }

    public mutating func endInteractiveGrab() {
        windowInteraction = .idle
    }

    public mutating func cancelInteractiveGrab() {
        windowInteraction = .idle
    }

    public mutating func clearGrab(forWindow id: UInt64) {
        windowInteraction.clear(forWindow: id)
    }

    public mutating func reset() {
        windowInteraction = .idle
        nextLayoutTransitionID = 1
    }
}
