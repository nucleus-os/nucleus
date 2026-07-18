import NucleusLayers
import Tracy

@MainActor
public struct WindowHitTestResult {
    public let window: Window
    public let view: View
}

@MainActor
public final class WindowScene: ~Sendable {
    private let publisher: WindowLayerPublisher
    private struct PublicationRecord {
        var level: WindowLevel
        var sequence: Int
        var content: PublishedVisualContent
    }

    package let visualContext: Context
    public private(set) var windows: [Window] = []
    public private(set) var keyWindow: Window?

    public init(
        windows: [Window] = []
    ) {
        self.publisher = WindowLayerPublisher(context: Application.currentContext)
        self.visualContext = Application.currentContext
        for window in windows {
            addWindow(window)
        }
    }

    package init(
        windows: [Window] = [],
        visualContext: Context
    ) {
        self.visualContext = visualContext
        self.publisher = WindowLayerPublisher(context: visualContext)
        for window in windows {
            addWindow(window)
        }
    }

    public func addWindow(_ window: Window) {
        guard !windows.contains(where: { $0 === window }) else {
            return
        }
        windows.append(window)
        window.windowScene = self
    }

    @discardableResult
    public func removeWindow(_ window: Window) -> Bool {
        let oldCount = windows.count
        windows.removeAll { $0 === window }
        if window.windowScene === self {
            window.windowScene = nil
        }
        if keyWindow === window {
            keyWindow = nil
            window.setKey(false)
        }
        return windows.count != oldCount
    }

    public func orderFront(_ window: Window) {
        addWindow(window)
        windows.removeAll { $0 === window }
        windows.append(window)
        window.setVisible(true)
    }

    public func orderOut(_ window: Window) {
        window.setOrderedOut()
        if keyWindow === window {
            keyWindow = nil
        }
    }

    public func makeKey(_ window: Window) {
        addWindow(window)
        keyWindow?.setKey(false)
        keyWindow = window
        window.setKey(true)
    }

    /// The scene's root layer, created and attached on first use. An embedder
    /// attaching its own content parents it here.
    @_spi(NucleusCompositor) public func ensureRootAttached() throws(UIError) -> Layer {
        try publisher.ensureRootAttached()
    }

    /// The sublayer index at which embedder-owned content at `level` should be
    /// inserted under the scene's root, so it lands above the scene's own
    /// windows at or below that level.
    ///
    /// The scene answers *where*; the embedder does the attaching, because what
    /// it is attaching is its own concept.
    @_spi(NucleusCompositor) public func insertionIndex(forLevel level: WindowLevel) -> UInt32 {
        let precedingWindowCount = windowsForDisplay().filter { window in
            window.isVisible &&
                window.root != nil &&
                window.level.rawValue <= level.rawValue
        }.count
        return UInt32(precedingWindowCount)
    }

    package func publish() throws(UIError) -> PublishedScene {
        try publish { _ in true }
    }

    package func publish(
        includes windowIncluded: @MainActor (Window) -> Bool
    ) throws(UIError) -> PublishedScene {
        let traceZone = Trace.beginZone("nucleus.window_scene.publish", color: Trace.Color.blue)
        defer {
            traceZone.end()
        }
        let displayWindows = windowsForDisplay()
        Trace.plot("swift.nucleus.window_scene.windows", UInt64(displayWindows.count))
        let visualContent = try publisher.publish(
            windows: displayWindows,
            includes: windowIncluded
        )
        return PublishedScene(visualContent: visualContent)
    }

    package func publish(
        placing placements: [ScenePlacement]
    ) throws(UIError) -> PublishedScene {
        try publish(placing: placements) { _ in true }
    }

    /// Publish this scene's windows interleaved with embedder-owned content by
    /// window level. The scene does not know what a placement *is* — only where
    /// it sorts — which is what keeps compositor concepts like hosted client
    /// surfaces out of the UI framework.
    @_spi(NucleusCompositor) public func publish(
        placing placements: [ScenePlacement],
        includes windowIncluded: @MainActor (Window) -> Bool
    ) throws(UIError) -> PublishedScene {
        let displayWindows = windowsForDisplay().filter { window in
            windowIncluded(window) && window.isVisible && window.root != nil
        }
        Trace.plot("swift.nucleus.window_scene.windows", UInt64(displayWindows.count))
        let windowContent = try publisher.publish(windows: displayWindows)
        let windowRecords = zip(displayWindows, windowContent).enumerated().map { index, pair in
            PublicationRecord(level: pair.0.level, sequence: index * 2, content: pair.1)
        }
        let placedRecords = placements.filter(\.visible).enumerated().map { index, placement in
            PublicationRecord(
                level: placement.level,
                sequence: index * 2 + 1,
                content: PublishedVisualContent(
                    id: placement.id,
                    rootLayerID: placement.rootLayerID,
                    orderIndex: 0,
                    visible: placement.visible
                )
            )
        }
        let ordered = (windowRecords + placedRecords).sorted { lhs, rhs in
            if lhs.level.rawValue != rhs.level.rawValue {
                return lhs.level.rawValue < rhs.level.rawValue
            }
            return lhs.sequence < rhs.sequence
        }
        let visualContent = ordered.enumerated().map { index, record in
            var content = record.content
            content.orderIndex = UInt32(index)
            return content
        }
        return PublishedScene(visualContent: visualContent)
    }

    public func hitTest(at point: Point) -> WindowHitTestResult? {
        for window in windowsForDisplay().reversed() where window.isVisible && window.participatesInHitTesting {
            guard let root = window.root, let view = root.hitTest(point) else {
                continue
            }
            return .init(window: window, view: view)
        }
        return nil
    }

    public func hitTestWindow(at point: Point) -> Window? {
        hitTest(at: point)?.window
    }

    private func windowsForDisplay() -> [Window] {
        windows.enumerated().sorted { lhs, rhs in
            let lhsLevel = lhs.element.level.rawValue
            let rhsLevel = rhs.element.level.rawValue
            if lhsLevel != rhsLevel {
                return lhsLevel < rhsLevel
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

}
