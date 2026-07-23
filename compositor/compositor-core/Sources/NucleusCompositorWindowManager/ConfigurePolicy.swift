import NucleusTypes
import NucleusCompositorServerTypes
public import NucleusCompositorServer
import Tracy

public enum ConfigureReason: UInt32, Sendable {
    case initialMap = 1
    case resize = 2
    case move = 3
    case tile = 4
    case restore = 5
    case fullscreen = 6
    case maximize = 7
    case outputMigration = 8
    case xwaylandStateRequest = 9
    case focusState = 10
}

public struct ConfigureRequest: Sendable, Equatable {
    public var windowID: UInt64
    public var reason: ConfigureReason
    public var targetRect: WindowRect?
    public var targetOutputID: DisplayID?
    public var activated: Bool
    public var resizing: Bool
    public var tileEdges: TileEdges

    public init(
        windowID: UInt64,
        reason: ConfigureReason,
        targetRect: WindowRect? = nil,
        targetOutputID: DisplayID? = nil,
        activated: Bool = false,
        resizing: Bool = false,
        tileEdges: TileEdges = TileEdges()
    ) {
        self.windowID = windowID
        self.reason = reason
        self.targetRect = targetRect
        self.targetOutputID = targetOutputID
        self.activated = activated
        self.resizing = resizing
        self.tileEdges = tileEdges
    }
}

public struct ConfigurePlan: Sendable, Equatable {
    public var shouldConfigure: Bool
    public var shouldPresent: Bool
    public var isRedundant: Bool
    public var targetRect: WindowRect
    public var stateMask: XdgStateMask
    public var activeMaximized: Bool
    public var activeFullscreen: Bool
    public var specialOutputID: DisplayID?
    public var layoutOutputID: DisplayID?
    public var layoutTransitionID: UInt64
    public var clearRequestedSpecial: Bool
}

public struct ConfigureCommitReport: Sendable, Equatable {
    public var windowID: UInt64
    public var ackedSerial: UInt32
    public var commitSequence: UInt64
    public var bufferAttached: Bool
    public var hasBuffer: Bool
    public var committedWidth: UInt32
    public var committedHeight: UInt32
}

@MainActor
extension WindowManager {
    public func planConfigure(_ request: ConfigureRequest) -> ConfigurePlan? {
        Trace.zone("window_manager.plan_configure", color: Trace.Color.blue) {
            Trace.plot("swift.window_manager.configure_reason", UInt64(request.reason.rawValue))
            guard let window = server.window(id: request.windowID) else { return nil }
            normalizeOutputState(window: window)

            if request.reason == .tile {
                return planTileConfigure(window: window, request: request)
            }

            if request.reason == .resize || request.reason == .move {
                return planDirectConfigure(window: window, request: request)
            }

            let requested = server.spaces.requestedSpecialMode(for: window)
            let wasSpecial = window.activeFullscreen || window.activeMaximized
            let specialOutputID = server.spaces.resolveSpecialOutputID(
                for: window,
                layout: server.layout,
                nextActiveFullscreen: requested.activeFullscreen,
                nextActiveMaximized: requested.activeMaximized
            )

            if requested.willSpecial && !wasSpecial {
                window.restoreRect = window.currentRect()
                window.restoreOutputID = server.spaces.fallbackOutput(for: window, layout: server.layout).id
            } else if !requested.willSpecial, let restore = window.restoreRect {
                let fallback = server.spaces.fallbackOutput(for: window, layout: server.layout)
                let restoreOutput = server.spaces.validOutputID(window.restoreOutputID, layout: server.layout)
                if restoreOutput == nil {
                    window.restoreRect = server.spaces.translateRectToOutput(
                        restore,
                        fromOutputID: window.restoreOutputID,
                        fromUsable: nil,
                        toOutput: fallback,
                        toUsable: usableArea(for: fallback),
                        layout: server.layout
                    )
                    window.restoreOutputID = fallback.id
                }
            }

            let targetRect = request.targetRect ?? desiredConfigureRect(for: window)
            let layoutOutputID = specialOutputID ?? window.currentOutputID ?? window.preferredOutputID
            let stateMask = xdgStateMask(
                requestedMaximized: requested.activeMaximized,
                requestedFullscreen: requested.activeFullscreen,
                tileEdges: window.tileEdges,
                activated: request.activated,
                resizing: request.resizing
            )
            return ConfigurePlan(
                shouldConfigure: true,
                shouldPresent: window.mapped,
                isRedundant: false,
                targetRect: targetRect,
                stateMask: stateMask,
                activeMaximized: requested.activeMaximized,
                activeFullscreen: requested.activeFullscreen,
                specialOutputID: requested.willSpecial ? specialOutputID : nil,
                layoutOutputID: layoutOutputID,
                layoutTransitionID: interaction.allocLayoutTransitionID(),
                clearRequestedSpecial: false
            )
        }
    }

    public func recordConfigureSent(windowID: UInt64, serial: UInt32, plan: ConfigurePlan) -> WindowPendingConfigure? {
        guard let window = server.window(id: windowID) else { return nil }
        let slotGeneration = window.protocolState.queueConfigure(
            rect: plan.targetRect,
            activeMaximized: plan.activeMaximized,
            activeFullscreen: plan.activeFullscreen,
            specialOutputID: plan.specialOutputID,
            layoutTransitionID: plan.layoutTransitionID,
            serial: serial
        )
        return WindowPendingConfigure(
            serial: serial,
            rect: plan.targetRect,
            activeMaximized: plan.activeMaximized,
            activeFullscreen: plan.activeFullscreen,
            specialOutputID: plan.specialOutputID,
            layoutTransitionID: plan.layoutTransitionID,
            slotGeneration: slotGeneration
        )
    }

    public func reportConfigureAck(windowID: UInt64, ackedSerial: UInt32) -> WindowPendingConfigure? {
        server.window(id: windowID)?.consumeAckedConfigure(serial: ackedSerial)
    }

    public func reportConfigureCommit(_ report: ConfigureCommitReport) -> Bool {
        guard let window = server.window(id: report.windowID) else { return false }
        if !window.activeFullscreen && !window.activeMaximized {
            window.restoreRect = window.currentRect()
            window.restoreOutputID = window.currentOutputID ?? window.preferredOutputID
        }
        return true
    }

    private func planTileConfigure(window: Window, request: ConfigureRequest) -> ConfigurePlan? {
        guard let targetRect = request.targetRect else { return nil }
        let samePending = window.protocolState.latest.map {
            $0.rect == targetRect && !$0.activeMaximized && !$0.activeFullscreen && $0.specialOutputID == nil
        } ?? false
        let sameSettled = !window.protocolState.hasPending && window.currentRect() == targetRect
        let noRequestedSpecial =
            !window.requestedMaximized &&
            !window.requestedFullscreen &&
            !window.activeMaximized &&
            !window.activeFullscreen
        let redundant = window.tileEdges == request.tileEdges && noRequestedSpecial && (samePending || sameSettled)
        if redundant {
            return ConfigurePlan(
                shouldConfigure: false,
                shouldPresent: false,
                isRedundant: true,
                targetRect: targetRect,
                stateMask: xdgStateMask(
                    requestedMaximized: false,
                    requestedFullscreen: false,
                    tileEdges: request.tileEdges,
                    activated: request.activated,
                    resizing: request.resizing
                ),
                activeMaximized: false,
                activeFullscreen: false,
                specialOutputID: nil,
                layoutOutputID: request.targetOutputID ?? window.currentOutputID ?? window.preferredOutputID,
                layoutTransitionID: 0,
                clearRequestedSpecial: true
            )
        }

        window.tileEdges = request.tileEdges
        window.requestedMaximized = false
        window.requestedFullscreen = false
        window.fullscreenTarget = .automatic
        if let outputID = request.targetOutputID {
            window.currentOutputID = outputID
            window.preferredOutputID = outputID
        }
        return ConfigurePlan(
            shouldConfigure: true,
            shouldPresent: window.mapped,
            isRedundant: false,
            targetRect: targetRect,
            stateMask: xdgStateMask(
                requestedMaximized: false,
                requestedFullscreen: false,
                tileEdges: request.tileEdges,
                activated: request.activated,
                resizing: request.resizing
            ),
            activeMaximized: false,
            activeFullscreen: false,
            specialOutputID: nil,
            layoutOutputID: request.targetOutputID ?? window.currentOutputID ?? window.preferredOutputID,
            layoutTransitionID: interaction.allocLayoutTransitionID(),
            clearRequestedSpecial: true
        )
    }

    private func planDirectConfigure(window: Window, request: ConfigureRequest) -> ConfigurePlan? {
        guard let targetRect = request.targetRect else { return nil }
        if request.reason == .move || request.reason == .resize {
            window.tileEdges = TileEdges()
        }
        if let outputID = request.targetOutputID {
            window.currentOutputID = outputID
            window.preferredOutputID = outputID
        }
        let samePending = window.protocolState.latest?.rect == targetRect
        return ConfigurePlan(
            shouldConfigure: !samePending,
            shouldPresent: false,
            isRedundant: samePending,
            targetRect: targetRect,
            stateMask: xdgStateMask(
                requestedMaximized: false,
                requestedFullscreen: false,
                tileEdges: window.tileEdges,
                activated: request.activated,
                resizing: request.resizing
            ),
            activeMaximized: false,
            activeFullscreen: false,
            specialOutputID: nil,
            layoutOutputID: request.targetOutputID ?? window.currentOutputID ?? window.preferredOutputID,
            layoutTransitionID: 0,
            clearRequestedSpecial: false
        )
    }

    private func normalizeOutputState(window: Window) {
        let fallback = server.spaces.fallbackOutput(for: window, layout: server.layout)
        if server.spaces.validOutputID(window.currentOutputID, layout: server.layout) == nil {
            window.currentOutputID = fallback.id
        }
        if server.spaces.validOutputID(window.preferredOutputID, layout: server.layout) == nil {
            window.preferredOutputID = fallback.id
        }
        if window.isManagedAppWindow(),
           let restore = window.restoreRect,
           server.spaces.validOutputID(window.restoreOutputID, layout: server.layout) == nil
        {
            window.restoreRect = server.spaces.translateRectToOutput(
                restore,
                fromOutputID: window.restoreOutputID,
                fromUsable: nil,
                toOutput: fallback,
                toUsable: usableArea(for: fallback),
                layout: server.layout
            )
            window.restoreOutputID = fallback.id
        }
        if window.isManagedAppWindow(),
           server.spaces.validOutputID(window.specialOutputID, layout: server.layout) == nil,
           (window.activeFullscreen || window.requestedFullscreen || window.activeMaximized || window.requestedMaximized)
        {
            window.specialOutputID = fallback.id
        }
        if case .output(let outputID) = window.fullscreenTarget,
           server.spaces.validOutputID(outputID, layout: server.layout) == nil
        {
            window.fullscreenTarget = .output(fallback.id)
        }
    }

    private func desiredConfigureRect(for window: Window) -> WindowRect {
        let placement = server.spaces.placementOutput(for: window, layout: server.layout, fullscreen: false)
        let fullscreenOutput = server.spaces.placementOutput(for: window, layout: server.layout, fullscreen: true)
        return server.spaces.desiredLayoutRect(
            for: window,
            rects: LayoutRects(
                fullscreen: server.spaces.fullscreenLayoutRect(for: fullscreenOutput),
                maximized: server.spaces.maximizedLayoutRect(for: placement, usable: usableArea(for: placement)),
                default: server.spaces.defaultWindowRect(for: placement, usable: usableArea(for: placement))
            )
        )
    }

    func usableArea(for display: Display) -> UsableArea {
        let full = UsableArea(
            x: 0,
            y: 0,
            w: Int32(max(1, display.logicalRect.width)),
            h: Int32(max(1, display.logicalRect.height))
        )
        // Subtract the output's layer-shell exclusive zones (shell topbar/dock)
        // so maximize, default placement, and centering land in the real work
        // area — the same zones the Xwayland `_NET_WORKAREA` and overlay bounds
        // already reserve.
        let zones = layerShellPolicy.recalcZones(outputID: display.id) ?? LayerExclusiveZones()
        return full.applying(layerZones: zones)
    }

    /// Apply the complete server/window-policy side of output removal. Migration
    /// runs while both the departing and fallback geometries are still queryable;
    /// only then are the display and its workspaces removed.
    @discardableResult
    public func removeOutput(_ outputID: DisplayID) -> Bool {
        guard let removed = server.layout.display(id: outputID) else { return false }
        let fallbackID = server.layout.fallbackDisplayIDForRemoval(outputID)
        let fallback = fallbackID.flatMap { server.layout.display(id: $0) }
        let plan = OutputMigrationPlan(
            removedOutputID: outputID,
            fallbackOutputID: fallbackID,
            removedUsable: usableArea(for: removed),
            fallbackUsable: fallback.map(usableArea(for:)),
            fullscreenRect: fallback.map {
                server.spaces.fullscreenLayoutRect(for: $0)
            },
            maximizedRect: fallback.map {
                server.spaces.maximizedLayoutRect(
                    for: $0, usable: usableArea(for: $0))
            })
        server.inputControl?.displayWillRemove(hasFallbackDisplay: fallback != nil)
        for window in server.windows.windows {
            _ = migrateOffOutput(windowID: window.id, plan: plan)
        }
        _ = server.layout.removeDisplay(id: outputID)
        server.spaces.removeDisplay(outputID, layout: server.layout)
        return true
    }

    /// Center a floating window's committed size for its first placement: over
    /// its parent for a dialog/transient with a mapped parent, otherwise on its
    /// output's usable area. Returns nil when the window owns its placement
    /// (fullscreen / maximized), so the caller keeps the configured rect.
    public func centeredFirstMapRect(windowID: UInt64, contentWidth: UInt32, contentHeight: UInt32) -> WindowRect? {
        guard let window = server.window(id: windowID) else { return nil }
        if window.requestedFullscreen || window.requestedMaximized ||
            window.activeFullscreen || window.activeMaximized { return nil }
        let w = max(1, contentWidth)
        let h = max(1, contentHeight)
        // Center the frame (content + chrome insets), not the bare content, so a
        // decorated window sits centered including its titlebar/border. Only the
        // origin is consumed; the returned size is the content extent.
        let insets = window.chromeInsets
        let frameW = UInt32(max(1, Double(w) + insets.horizontal))
        let frameH = UInt32(max(1, Double(h) + insets.vertical))
        if let parentID = window.parentWindowID,
            let parent = server.window(id: parentID),
            parent.mapped {
            let p = parent.currentRect()
            return WindowRect(
                x: p.x + (Double(p.width) - Double(frameW)) / 2,
                y: p.y + (Double(p.height) - Double(frameH)) / 2,
                width: w,
                height: h
            )
        }
        let output = server.spaces.placementOutput(for: window, layout: server.layout, fullscreen: false)
        let usable = usableArea(for: output)
        let maxX = max(0, usable.w - Int32(frameW))
        let maxY = max(0, usable.h - Int32(frameH))
        return WindowRect(
            x: output.logicalRect.x + Double(usable.x) + Double(maxX) / 2,
            y: output.logicalRect.y + Double(usable.y) + Double(maxY) / 2,
            width: w,
            height: h
        )
    }
}
