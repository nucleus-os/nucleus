import NucleusTypes
import NucleusCompositorServerTypes

public typealias DisplayID = UInt64
public typealias SpaceID = UInt32
public typealias WindowID = UInt64

// Pure-scalar geometry mirrors are the generated wire types themselves. The
// generator emits Wire-prefixed names, so these unprefixed aliases don't
// collide with the wire types. `LogicalRect`'s `maxX`/`maxY` are the only
// relocated conveniences.
public typealias LogicalRect = WireLogicalRect
public typealias RenderRect = WireRenderRect
public typealias PixelSize = WirePixelSize
public typealias UsableArea = WireUsableArea

extension WireLogicalRect {
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
}

public struct PhysicalRect: Sendable, Equatable {
    public var x: Int32
    public var y: Int32
    public var width: UInt32
    public var height: UInt32
}

// `DisplayMode` is the generated wire type itself. Its refresh field is the
// wire's `refreshMhz` (camelCase of `refresh_mhz`); the `Display` class keeps a
// separate `refreshMHz` property of its own.
public typealias DisplayMode = WireDisplayMode

public struct DisplayConfiguration: Sendable, Equatable {
    public var enabled: Bool
    public var primary: Bool
    public var logicalX: Double
    public var logicalY: Double
    public var logicalWidth: Double?
    public var logicalHeight: Double?
    public var scale: UInt32
    public var fractionalScale: Double
    public var mode: DisplayMode

    public init(
        enabled: Bool = true,
        primary: Bool = false,
        logicalX: Double = 0,
        logicalY: Double = 0,
        logicalWidth: Double? = nil,
        logicalHeight: Double? = nil,
        scale: UInt32 = 1,
        fractionalScale: Double = 1,
        mode: DisplayMode
    ) {
        self.enabled = enabled
        self.primary = primary
        self.logicalX = logicalX
        self.logicalY = logicalY
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.scale = max(1, scale)
        self.fractionalScale = max(0.01, fractionalScale)
        self.mode = mode
    }
}

public struct DisplayConfigurationChanges: Sendable, Equatable {
    public var enabled: Bool?
    public var primary: Bool?
    public var logicalX: Double?
    public var logicalY: Double?
    public var logicalWidth: Double?
    public var logicalHeight: Double?
    public var scale: UInt32?
    public var fractionalScale: Double?
    public var mode: DisplayMode?

    public init() {}
}

@MainActor
public final class Display {
    public let id: DisplayID
    public var logicalRect: LogicalRect
    public var pixelSize: PixelSize
    public var scale: UInt32
    public var fractionalScale: Double
    public var refreshMHz: Int32
    public var configuration: DisplayConfiguration
    /// Per-output frame scheduler (the native Swift owner; the reactor reaches it by
    /// output id through the `nucleus_display_link_*` `@_cdecl` accessors).
    public var displayLink: DisplayLink
    public var physicalWidthMM: Int32
    public var physicalHeightMM: Int32
    public var name: String
    public var description: String
    public var drmOutputAddress: UInt = 0
    /// The predicted presentation time (ns, presentation clock domain) for this
    /// output's next frame, refreshed each frame by the render loop from the
    /// output's display-link timeline. The scene feeder reads `predictedPresentSeconds`
    /// to advance the tiling spring. Hardware frame-request arming stays in the reactor;
    /// only the predicted-present value crosses onto the model.
    public var predictedPresentNs: UInt64 = 0
    /// `predictedPresentNs` in seconds — the spring's per-frame sample clock.
    public var predictedPresentSeconds: Double { Double(predictedPresentNs) / 1_000_000_000 }

    /// The `DisplayLink` present id issued for this output's in-flight scanout
    /// (0 = none outstanding). Issued at submit (`noteFrameSubmitted`) and carried
    /// into the presentation report at page-flip completion (`noteFramePresented`),
    /// so the acked id reflects a frame submitted *after* — never before — a state
    /// change like a session-lock blank. The security-sensitive `locked` ack reads
    /// `displayLink.lastAckedPresentID` against a begin-time threshold.
    public var inFlightPresentID: UInt64 = 0

    /// A scanout frame was submitted for this output (KMS atomic commit accepted):
    /// open the submitted-frame range and issue the next present id, held until the
    /// page flip completes.
    public func noteFrameSubmitted() {
        displayLink.beginSubmittedFrame()
        inFlightPresentID = displayLink.nextPresentID()
    }

    /// This output's in-flight scanout page-flipped: fold the present id issued at
    /// submit into the display-link ack, advancing `lastAckedPresentID`.
    public func noteFramePresented(presentationNs: UInt64) {
        displayLink.presented(PresentReport(
            source: .drmPageFlip,
            presentationNs: presentationNs,
            presentID: inFlightPresentID == 0 ? nil : inFlightPresentID,
            refreshIntervalNs: displayLink.refreshIntervalNs))
        inFlightPresentID = 0
    }

    public init(id: DisplayID, configuration: DisplayConfiguration, physicalWidthMM: Int32 = 0, physicalHeightMM: Int32 = 0, name: String = "", description: String = "") {
        self.id = id
        self.configuration = configuration
        self.physicalWidthMM = physicalWidthMM
        self.physicalHeightMM = physicalHeightMM
        self.name = name
        self.description = description
        self.logicalRect = .init()
        self.pixelSize = .init(width: 0, height: 0)
        self.scale = 1
        self.fractionalScale = 1
        self.refreshMHz = 0
        self.displayLink = DisplayLink(
            refreshHz: Self.refreshHz(forMode: configuration.mode),
            outputTag: name.isEmpty ? "bootstrap" : name
        )
        apply(configuration)
    }

    public func apply(_ configuration: DisplayConfiguration) {
        self.configuration = configuration
        logicalRect = LogicalRect(
            x: configuration.logicalX,
            y: configuration.logicalY,
            width: configuration.logicalWidth ?? Double(configuration.mode.pixelWidth) / configuration.fractionalScale,
            height: configuration.logicalHeight ?? Double(configuration.mode.pixelHeight) / configuration.fractionalScale
        )
        pixelSize = PixelSize(width: configuration.mode.pixelWidth, height: configuration.mode.pixelHeight)
        scale = max(1, configuration.scale)
        fractionalScale = max(0.01, configuration.fractionalScale)
        refreshMHz = configuration.mode.refreshMhz
        displayLink.updateRefreshInterval(Self.refreshIntervalNs(forMode: configuration.mode))
    }

    static func refreshHz(forMode mode: DisplayMode) -> UInt32 {
        UInt32(max(mode.refreshMhz / 1000, 1))
    }

    static func refreshIntervalNs(forMode mode: DisplayMode) -> UInt64 {
        1_000_000_000 / UInt64(refreshHz(forMode: mode))
    }
}

@MainActor
public final class DesktopLayout {
    public private(set) var displays: [Display] = []
    public private(set) var primaryOutputID: DisplayID?
    private var nextOutputID: DisplayID = 1

    public init() {}

    @discardableResult
    public func addDisplay(
        id requestedID: DisplayID = 0,
        configuration: DisplayConfiguration,
        name: String = "",
        description: String = "",
        physicalWidthMM: Int32 = 0,
        physicalHeightMM: Int32 = 0,
        logicalXSpecified: Bool = true,
        logicalYSpecified: Bool = true
    ) -> Display {
        let id = requestedID == 0 ? nextOutputID : requestedID
        nextOutputID = max(nextOutputID, id + 1)
        var config = configuration
        let placement = defaultPlacementForNewDisplay()
        if !logicalXSpecified {
            config.logicalX = placement.x
        }
        if !logicalYSpecified {
            config.logicalY = placement.y
        }
        if config.primary || primaryOutputID == nil {
            primaryOutputID = id
            config.primary = true
        }
        let display = Display(
            id: id,
            configuration: config,
            physicalWidthMM: physicalWidthMM,
            physicalHeightMM: physicalHeightMM,
            name: name.isEmpty ? "Nucleus-\(id)" : name,
            description: description.isEmpty ? "Nucleus output \(id)" : description
        )
        displays.append(display)
        syncPrimaryFlags()
        return display
    }

    @discardableResult
    public func removeDisplay(id: DisplayID) -> Display? {
        guard let index = displays.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = displays.remove(at: index)
        if primaryOutputID == id {
            primaryOutputID = displays.first?.id
        }
        syncPrimaryFlags()
        return removed
    }

    public func display(id: DisplayID) -> Display? {
        displays.first { $0.id == id }
    }

    public func primaryDisplayID() -> DisplayID? {
        primaryOutputID ?? displays.first?.id
    }

    public func fallbackDisplayIDForRemoval(_ removedID: DisplayID) -> DisplayID? {
        if let primaryOutputID, primaryOutputID != removedID, display(id: primaryOutputID) != nil {
            return primaryOutputID
        }
        return displays.first { $0.id != removedID }?.id
    }

    public func configureDisplay(id: DisplayID, changes: DisplayConfigurationChanges) -> Bool {
        guard let display = display(id: id) else { return false }
        let before = display.configuration
        var next = before
        if let enabled = changes.enabled { next.enabled = enabled }
        if let primary = changes.primary { next.primary = primary }
        if let logicalX = changes.logicalX { next.logicalX = logicalX }
        if let logicalY = changes.logicalY { next.logicalY = logicalY }
        if let logicalWidth = changes.logicalWidth { next.logicalWidth = logicalWidth }
        if let logicalHeight = changes.logicalHeight { next.logicalHeight = logicalHeight }
        if let scale = changes.scale { next.scale = max(1, scale) }
        if let fractionalScale = changes.fractionalScale { next.fractionalScale = max(0.01, fractionalScale) }
        if let mode = changes.mode { next.mode = mode }
        display.apply(next)
        if changes.primary == true {
            primaryOutputID = id
        } else if changes.primary == false, primaryOutputID == id {
            primaryOutputID = displays.first(where: { $0.id != id })?.id ?? id
        }
        syncPrimaryFlags()
        return before != display.configuration
    }

    public func desktopBounds() -> LogicalRect? {
        guard let first = displays.first else { return nil }
        var minX = first.logicalRect.x
        var minY = first.logicalRect.y
        var maxX = first.logicalRect.maxX
        var maxY = first.logicalRect.maxY
        for display in displays.dropFirst() {
            minX = min(minX, display.logicalRect.x)
            minY = min(minY, display.logicalRect.y)
            maxX = max(maxX, display.logicalRect.maxX)
            maxY = max(maxY, display.logicalRect.maxY)
        }
        return LogicalRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func defaultPlacementForNewDisplay() -> (x: Double, y: Double) {
        guard let bounds = desktopBounds() else { return (0, 0) }
        let anchorY = primaryDisplayID().flatMap { display(id: $0)?.logicalRect.y } ?? bounds.y
        return (bounds.maxX, anchorY)
    }

    private func syncPrimaryFlags() {
        for display in displays {
            display.configuration.primary = primaryOutputID == display.id
        }
    }
}
