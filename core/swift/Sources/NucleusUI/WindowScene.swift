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

    public func orderFront(_ window: Window) throws(UIError) {
        addWindow(window)
        windows.removeAll { $0 === window }
        windows.append(window)
        try window.setVisible(true)
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

    package func ensureRootAttached() throws(UIError) -> Layer {
        try publisher.ensureRootAttached()
    }

    package func attachHostedSurface<Result>(
        _ surface: HostedSurface,
        using attach: (View, Int, Layer) throws -> Result
    ) throws -> Result {
        try attachHostedSurface(surface) { rootView, surfaceID, parentLayer, _ in
            try attach(rootView, surfaceID, parentLayer)
        }
    }

    @_spi(NucleusCompositor) public func attachHostedSurface<Result>(
        _ surface: HostedSurface,
        using attach: (View, Int, Layer, UInt32) throws -> Result
    ) throws -> Result {
        let parentLayer = try ensureRootAttached()
        let index = hostedSurfaceInsertionIndex(for: surface)
        let result = try attach(surface.rootView, surface.surfaceID, parentLayer, index)
        surface.markCommittedContent()
        surface.beginCommittedFrameUpdates()
        return result
    }

    @discardableResult
    package func attachHostedSurfaces(
        _ surfaces: [HostedSurface],
        where shouldAttach: (HostedSurface) -> Bool,
        using attach: (View, Int, Layer) throws -> Void
    ) throws -> Bool {
        try attachHostedSurfaces(surfaces, where: shouldAttach) { rootView, surfaceID, parentLayer, _ in
            try attach(rootView, surfaceID, parentLayer)
        }
    }

    @discardableResult
    @_spi(NucleusCompositor) public func attachHostedSurfaces(
        _ surfaces: [HostedSurface],
        where shouldAttach: (HostedSurface) -> Bool,
        using attach: (View, Int, Layer, UInt32) throws -> Void
    ) throws -> Bool {
        var didAttach = false
        var parentLayer: Layer?
        var attachedAtLevel: [WindowLevel: UInt32] = [:]
        for surface in surfaces where shouldAttach(surface) {
            let resolvedParent = try parentLayer ?? ensureRootAttached()
            parentLayer = resolvedParent
            let baseIndex = hostedSurfaceInsertionIndex(for: surface)
            let levelOffset = attachedAtLevel[surface.level] ?? 0
            try attach(surface.rootView, surface.surfaceID, resolvedParent, baseIndex + levelOffset)
            attachedAtLevel[surface.level] = levelOffset + 1
            surface.markCommittedContent()
            surface.beginCommittedFrameUpdates()
            didAttach = true
        }
        return didAttach
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
        hostedSurfaces: [HostedVisualContent]
    ) throws(UIError) -> PublishedScene {
        try publish(hostedSurfaces: hostedSurfaces) { _ in true }
    }

    @_spi(NucleusCompositor) public func publish(
        hostedSurfaces: [HostedVisualContent],
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
        let visibleHostedSurfaces = hostedSurfaces.filter(\.visible)
        let hostedRecords = visibleHostedSurfaces.enumerated().map { index, surface in
            PublicationRecord(
                level: surface.level,
                sequence: index * 2 + 1,
                content: PublishedVisualContent.hostedSurface(
                    id: surface.id,
                    rootLayerID: surface.rootLayerID,
                    orderIndex: 0,
                    visible: surface.visible
                )
            )
        }
        let ordered = (windowRecords + hostedRecords).sorted { lhs, rhs in
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

    public func hitTest(at point: Point) throws(UIError) -> WindowHitTestResult? {
        for window in windowsForDisplay().reversed() where window.isVisible && window.participatesInHitTesting {
            guard let root = window.root, let view = try root.hitTest(point) else {
                continue
            }
            return .init(window: window, view: view)
        }
        return nil
    }

    public func hitTestWindow(at point: Point) throws(UIError) -> Window? {
        try hitTest(at: point)?.window
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

    private func hostedSurfaceInsertionIndex(for surface: HostedSurface) -> UInt32 {
        let precedingWindowCount = windowsForDisplay().filter { window in
            window.isVisible &&
                window.root != nil &&
                window.level.rawValue <= surface.level.rawValue
        }.count
        return UInt32(precedingWindowCount)
    }
}
