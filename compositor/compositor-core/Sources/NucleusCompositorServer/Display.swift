import Glibc
package import NucleusCompositorServerTypes
import NucleusTypes

package typealias DisplayID = UInt64
package typealias SpaceID = UInt32
package typealias WindowID = UInt64

// Pure-scalar geometry mirrors are the generated wire types themselves. The
// generator emits Wire-prefixed names, so these unprefixed aliases don't
// collide with the wire types. `LogicalRect`'s `maxX`/`maxY` are the only
// relocated conveniences.
package typealias LogicalRect = WireLogicalRect
package typealias RenderRect = WireRenderRect
package typealias PixelSize = WirePixelSize
package typealias UsableArea = WireUsableArea

extension WireLogicalRect {
    package var maxX: Double { x + width }
    package var maxY: Double { y + height }
}

package struct PhysicalRect: Sendable, Equatable {
    package var x: Int32
    package var y: Int32
    package var width: UInt32
    package var height: UInt32
}

// `DisplayMode` is the generated wire type itself. Its refresh field is the
// wire's `refreshMhz` (camelCase of `refresh_mhz`); the `Display` class keeps a
// separate `refreshMHz` property of its own.
package typealias DisplayMode = WireDisplayMode

package struct DisplayConfiguration: Sendable, Equatable {
    package var enabled: Bool
    package var primary: Bool
    package var logicalX: Double
    package var logicalY: Double
    package var logicalWidth: Double?
    package var logicalHeight: Double?
    package var scale: UInt32
    package var fractionalScale: Double
    package var mode: DisplayMode

    package init(
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

package struct DisplayConfigurationChanges: Sendable, Equatable {
    package var enabled: Bool?
    package var primary: Bool?
    package var logicalX: Double?
    package var logicalY: Double?
    package var logicalWidth: Double?
    package var logicalHeight: Double?
    package var scale: UInt32?
    package var fractionalScale: Double?
    package var mode: DisplayMode?

    package init() {}
}

package struct OutputRedrawMetrics: Sendable, Equatable {
    package var redrawRequests: UInt64 = 0
    package var coalescedRequests: UInt64 = 0
    /// One counter per `RedrawReasons` bit, indexed by its trailing-zero bit.
    package var coalescedByReason: [UInt64] =
        Array(repeating: 0, count: 8)
    package var sceneAuthorPasses: UInt64 = 0
    package var renderPassesWithoutSubmission: UInt64 = 0
    /// idle, queued, rendering, awaiting-presentation, deferred, suspended.
    package var stateResidenceNs: [UInt64] =
        Array(repeating: 0, count: 6)

    package init() {}
}

@MainActor
package final class Display {
    package let id: DisplayID
    package var logicalRect: LogicalRect
    package var pixelSize: PixelSize
    package var scale: UInt32
    package var fractionalScale: Double
    package var refreshMHz: Int32
    package var configuration: DisplayConfiguration
    /// Per-output frame scheduler (the native Swift owner; the reactor reaches it by
    /// output id through the display-link service).
    package var displayLink: DisplayLink
    package private(set) var redrawState: OutputRedrawState = .idle
    private var redrawStateSinceNs =
        Display.monotonicNowNs()
    private var redrawMetrics = OutputRedrawMetrics()
    package var physicalWidthMM: Int32
    package var physicalHeightMM: Int32
    package var name: String
    package var description: String
    package var drmOutputAddress: UInt = 0
    /// The predicted presentation time (ns, presentation clock domain) for this
    /// output's next frame, refreshed each frame by the render loop from the
    /// output's display-link timeline. The scene feeder reads `predictedPresentSeconds`
    /// to advance the tiling spring. Hardware frame-request arming stays in the reactor;
    /// only the predicted-present value crosses onto the model.
    package var predictedPresentNs: UInt64 = 0
    /// `predictedPresentNs` in seconds — the spring's per-frame sample clock.
    package var predictedPresentSeconds: Double { Double(predictedPresentNs) / 1_000_000_000 }

    /// The `DisplayLink` present id issued for this output's in-flight scanout
    /// (0 = none outstanding). Issued at submit (`noteFrameSubmitted`) and carried
    /// into the presentation report at page-flip completion (`noteFramePresented`),
    /// so the acked id reflects a frame submitted *after* — never before — a state
    /// change like a session-lock blank. The security-sensitive `locked` ack reads
    /// `displayLink.lastAckedPresentID` against a begin-time threshold.
    package var inFlightPresentID: UInt64 = 0

    /// A scanout frame was submitted for this output (KMS atomic commit accepted):
    /// open the submitted-frame range and issue the next present id, held until the
    /// page flip completes.
    package func noteFrameSubmitted() {
        displayLink.beginSubmittedFrame()
        inFlightPresentID = displayLink.nextPresentID()
    }

    /// This output's in-flight scanout page-flipped: fold the present id issued at
    /// submit into the display-link ack, advancing `lastAckedPresentID`.
    package func noteFramePresented(presentationNs: UInt64) {
        displayLink.presented(
            PresentReport(
                source: .drmPageFlip,
                presentationNs: presentationNs,
                presentID: inFlightPresentID == 0 ? nil : inFlightPresentID,
                refreshIntervalNs: displayLink.refreshIntervalNs))
        inFlightPresentID = 0
    }

    package func requestRedraw(_ reasons: RedrawReasons) {
        guard !reasons.isEmpty else { return }
        redrawMetrics.redrawRequests &+= 1
        if !isIdle(redrawState) {
            redrawMetrics.coalescedRequests &+= 1
            for bit in 0..<8
            where reasons.rawValue & (1 << bit) != 0 {
                redrawMetrics.coalescedByReason[bit] &+= 1
            }
        }
        switch redrawState {
        case .idle:
            transition(to: .queued(reasons))
        case .queued(let existing):
            transition(
                to: .queued(existing.union(reasons)))
        case .rendering(let frameBuildID, let pending):
            transition(
                to: .rendering(
                    frameBuildID: frameBuildID,
                    pending: pending.union(reasons)))
        case .awaitingPresentation(let submissionID, let pending):
            transition(
                to: .awaitingPresentation(
                    submissionID: submissionID,
                    pending: pending.union(reasons)))
        case .deferredUntil(let deadline, let existing):
            transition(
                to: .deferredUntil(
                    deadline, existing.union(reasons)))
        case .suspended(let existing):
            transition(
                to: .suspended(existing.union(reasons)))
        }
        displayLink.requestFrame()
    }

    @discardableResult
    package func beginRedraw(frameBuildID: UInt64) -> Bool {
        guard case .queued = redrawState else { return false }
        _ = displayLink.consumeFrameDemand()
        transition(
            to: .rendering(
                frameBuildID: frameBuildID, pending: []))
        return true
    }

    package func redrawSubmitted(submissionID: UInt64) {
        guard case .rendering(_, let pending) = redrawState else { return }
        transition(
            to: .awaitingPresentation(
                submissionID: submissionID, pending: pending))
    }

    package func redrawDidNotSubmit() {
        guard case .rendering(_, let pending) = redrawState else { return }
        redrawMetrics.renderPassesWithoutSubmission &+= 1
        transition(
            to:
                pending.isEmpty ? .idle : .queued(pending))
    }

    package func redrawPresented(submissionID: UInt64) {
        guard
            case .awaitingPresentation(
                let expectedSubmissionID, let pending) = redrawState,
            expectedSubmissionID == submissionID
        else { return }
        transition(
            to:
                pending.isEmpty ? .idle : .queued(pending))
    }

    package func suspendRedraws() {
        let retained: RedrawReasons
        switch redrawState {
        case .queued(let reasons),
            .deferredUntil(_, let reasons),
            .suspended(let reasons):
            retained = reasons
        case .rendering(_, let pending),
            .awaitingPresentation(_, let pending):
            retained = pending
        case .idle:
            retained = []
        }
        transition(to: .suspended(retained))
        displayLink.suspend()
    }

    package func resumeRedraws() {
        let retained: RedrawReasons
        if case .suspended(let reasons) = redrawState {
            retained = reasons
        } else {
            retained = []
        }
        transition(
            to:
                .queued(retained.union(.recovery)))
        displayLink.resetPresentationPhase()
        displayLink.requestFrame()
    }

    package func noteSceneAuthorPass() {
        redrawMetrics.sceneAuthorPasses &+= 1
    }

    package func sampleRedrawMetrics()
        -> OutputRedrawMetrics
    {
        var sample = redrawMetrics
        let now = Self.monotonicNowNs()
        let elapsed = now &- redrawStateSinceNs
        sample.stateResidenceNs[
            stateIndex(redrawState)] &+= elapsed
        return sample
    }

    private func transition(
        to state: OutputRedrawState
    ) {
        let now = Self.monotonicNowNs()
        redrawMetrics.stateResidenceNs[
            stateIndex(redrawState)] &+=
            now &- redrawStateSinceNs
        redrawState = state
        redrawStateSinceNs = now
    }

    private func isIdle(
        _ state: OutputRedrawState
    ) -> Bool {
        if case .idle = state { return true }
        return false
    }

    private func stateIndex(
        _ state: OutputRedrawState
    ) -> Int {
        switch state {
        case .idle: 0
        case .queued: 1
        case .rendering: 2
        case .awaitingPresentation: 3
        case .deferredUntil: 4
        case .suspended: 5
        }
    }

    private static func monotonicNowNs() -> UInt64 {
        var timestamp = timespec(tv_sec: 0, tv_nsec: 0)
        unsafe clock_gettime(
            CLOCK_MONOTONIC, &timestamp)
        return UInt64(timestamp.tv_sec)
            &* 1_000_000_000
            &+ UInt64(timestamp.tv_nsec)
    }

    package init(
        id: DisplayID, configuration: DisplayConfiguration, physicalWidthMM: Int32 = 0,
        physicalHeightMM: Int32 = 0, name: String = "", description: String = ""
    ) {
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
            refreshIntervalNs:
                Self.refreshIntervalNs(
                    forMode: configuration.mode),
            outputTag: name.isEmpty ? "bootstrap" : name
        )
        apply(configuration)
    }

    package func apply(_ configuration: DisplayConfiguration) {
        self.configuration = configuration
        logicalRect = LogicalRect(
            x: configuration.logicalX,
            y: configuration.logicalY,
            width: configuration.logicalWidth ?? Double(configuration.mode.pixelWidth)
                / configuration.fractionalScale,
            height: configuration.logicalHeight ?? Double(configuration.mode.pixelHeight)
                / configuration.fractionalScale
        )
        pixelSize = PixelSize(
            width: configuration.mode.pixelWidth, height: configuration.mode.pixelHeight)
        scale = max(1, configuration.scale)
        fractionalScale = max(0.01, configuration.fractionalScale)
        refreshMHz = configuration.mode.refreshMhz
        displayLink.updateRefreshInterval(Self.refreshIntervalNs(forMode: configuration.mode))
    }

    static func refreshIntervalNs(forMode mode: DisplayMode) -> UInt64 {
        let milliHz = UInt64(max(mode.refreshMhz, 1))
        return (1_000_000_000_000 &+ milliHz / 2) / milliHz
    }
}

@MainActor
package final class DesktopLayout {
    package private(set) var displays: [Display] = []
    package private(set) var primaryOutputID: DisplayID?
    private var nextOutputID: DisplayID = 1

    package init() {}

    @discardableResult
    package func addDisplay(
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
    package func removeDisplay(id: DisplayID) -> Display? {
        guard let index = displays.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = displays.remove(at: index)
        if primaryOutputID == id {
            primaryOutputID = displays.first?.id
        }
        syncPrimaryFlags()
        return removed
    }

    package func display(id: DisplayID) -> Display? {
        displays.first { $0.id == id }
    }

    package func primaryDisplayID() -> DisplayID? {
        primaryOutputID ?? displays.first?.id
    }

    package func fallbackDisplayIDForRemoval(_ removedID: DisplayID) -> DisplayID? {
        if let primaryOutputID, primaryOutputID != removedID, display(id: primaryOutputID) != nil {
            return primaryOutputID
        }
        return displays.first { $0.id != removedID }?.id
    }

    package func configureDisplay(id: DisplayID, changes: DisplayConfigurationChanges) -> Bool {
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
        if let fractionalScale = changes.fractionalScale {
            next.fractionalScale = max(0.01, fractionalScale)
        }
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

    package func desktopBounds() -> LogicalRect? {
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
