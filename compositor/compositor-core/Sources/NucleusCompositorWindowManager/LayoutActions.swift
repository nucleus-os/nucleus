package import NucleusCompositorServer
import Tracy

package import struct NucleusCompositorServerTypes.WireLogicalRect

package enum TileCommand: UInt32 {
    case left = 1
    case right = 2
    case top = 3
    case bottom = 4
    case topLeft = 5
    case topRight = 6
    case bottomLeft = 7
    case bottomRight = 8
    case maximize = 9
}

package struct TileRegionPlan: Equatable {
    package enum Action: UInt32 {
        case none = 0
        case tile = 1
        case maximize = 2
    }

    package var action: Action
    package var rect: WindowRect
    package var edges: TileEdges
}

package struct XdgStateMask: OptionSet, Sendable {
    package let rawValue: UInt32

    package init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    package static let activated = XdgStateMask(rawValue: 1 << 0)
    package static let resizing = XdgStateMask(rawValue: 1 << 1)
    package static let fullscreen = XdgStateMask(rawValue: 1 << 2)
    package static let maximized = XdgStateMask(rawValue: 1 << 3)
    package static let tiledLeft = XdgStateMask(rawValue: 1 << 4)
    package static let tiledRight = XdgStateMask(rawValue: 1 << 5)
    package static let tiledTop = XdgStateMask(rawValue: 1 << 6)
    package static let tiledBottom = XdgStateMask(rawValue: 1 << 7)
}

package struct RestoreTranslation: Equatable, Sendable {
    package var rect: WindowRect
    package var outputID: DisplayID
}

package struct OutputMigrationPlan: Equatable, Sendable {
    package var removedOutputID: DisplayID
    package var fallbackOutputID: DisplayID?
    package var removedUsable: UsableArea?
    package var fallbackUsable: UsableArea?
    package var fullscreenRect: WindowRect?
    package var maximizedRect: WindowRect?
}

package struct OutputMigrationResult: Equatable, Sendable {
    package var managed: Bool
    package var changed: Bool
    package var specialChanged: Bool
}

extension UsableArea {
    package func applying(layerZones zones: LayerExclusiveZones) -> UsableArea {
        UsableArea(
            x: zones.left,
            y: zones.top,
            w: w - zones.left - zones.right,
            h: h - zones.top - zones.bottom
        )
    }
}

extension WindowManager {
    package func xdgStateMask(
        requestedMaximized: Bool,
        requestedFullscreen: Bool,
        tileEdges: TileEdges,
        activated: Bool,
        resizing: Bool
    ) -> XdgStateMask {
        var mask: XdgStateMask = []
        if activated {
            mask.insert(.activated)
        }
        if requestedFullscreen {
            mask.insert(.fullscreen)
            return mask
        }
        if requestedMaximized {
            mask.insert(.maximized)
        } else {
            if tileEdges.left { mask.insert(.tiledLeft) }
            if tileEdges.right { mask.insert(.tiledRight) }
            if tileEdges.top { mask.insert(.tiledTop) }
            if tileEdges.bottom { mask.insert(.tiledBottom) }
        }
        if resizing {
            mask.insert(.resizing)
        }
        return mask
    }

    package func normalizeOutputState(
        windowID: UInt64,
        fallbackOutputID: DisplayID,
        translatedRestore: RestoreTranslation?
    ) -> Bool {
        guard let window = server.window(id: windowID) else { return false }
        if server.spaces.validOutputID(window.currentOutputID, layout: server.layout) == nil {
            window.currentOutputID = fallbackOutputID
        }
        if server.spaces.validOutputID(window.preferredOutputID, layout: server.layout) == nil {
            window.preferredOutputID = fallbackOutputID
        }
        if window.isManagedAppWindow(),
            window.restoreRect != nil,
            server.spaces.validOutputID(window.restoreOutputID, layout: server.layout) == nil,
            let translatedRestore
        {
            window.restoreRect = translatedRestore.rect
            window.restoreOutputID = translatedRestore.outputID
        }
        if window.isManagedAppWindow(),
            server.spaces.validOutputID(window.specialOutputID, layout: server.layout) == nil,
            window.activeFullscreen || window.requestedFullscreen || window.activeMaximized
                || window.requestedMaximized
        {
            window.specialOutputID = fallbackOutputID
        }
        if case .output(let outputID) = window.fullscreenTarget,
            server.spaces.validOutputID(outputID, layout: server.layout) == nil
        {
            window.fullscreenTarget = .output(fallbackOutputID)
        }
        return true
    }

    package func migrateOffOutput(windowID: UInt64, plan: OutputMigrationPlan)
        -> OutputMigrationResult?
    {
        Trace.zone("window_manager.migrate_off_output", color: Trace.Color.yellow) {
            guard let window = server.window(id: windowID) else { return nil }
            var changed = false
            var specialChanged = false

            func fallbackID() -> DisplayID? { plan.fallbackOutputID }
            func migrateOptionalOutput(_ outputID: inout DisplayID?) {
                if outputID == plan.removedOutputID {
                    outputID = fallbackID()
                    changed = true
                }
            }

            migrateOptionalOutput(&window.currentOutputID)
            migrateOptionalOutput(&window.preferredOutputID)

            if !window.isManagedAppWindow() {
                return OutputMigrationResult(
                    managed: false, changed: changed, specialChanged: false)
            }

            if window.restoreOutputID == plan.removedOutputID {
                if let fallbackOutputID = plan.fallbackOutputID,
                    let fallback = server.layout.display(id: fallbackOutputID),
                    let fallbackUsable = plan.fallbackUsable,
                    let restore = window.restoreRect
                {
                    window.restoreRect = server.spaces.translateRectToOutput(
                        restore,
                        fromOutputID: plan.removedOutputID,
                        fromUsable: plan.removedUsable,
                        toOutput: fallback,
                        toUsable: fallbackUsable,
                        layout: server.layout
                    )
                    window.restoreOutputID = fallbackOutputID
                } else {
                    window.restoreOutputID = nil
                }
                changed = true
            }

            if window.specialOutputID == plan.removedOutputID {
                window.specialOutputID = fallbackID()
                changed = true
                specialChanged = true
            }

            if case .output(let targetOutputID) = window.fullscreenTarget,
                targetOutputID == plan.removedOutputID
            {
                if let fallbackOutputID = plan.fallbackOutputID {
                    window.fullscreenTarget = .output(fallbackOutputID)
                } else {
                    window.fullscreenTarget = .automatic
                }
                changed = true
                specialChanged = true
            }

            window.protocolState.mutatePendingConfigures { pending in
                guard pending.specialOutputID == plan.removedOutputID else { return }
                pending.specialOutputID = fallbackID()
                if let fallbackOutputID = plan.fallbackOutputID,
                    let fallback = server.layout.display(id: fallbackOutputID),
                    let fallbackUsable = plan.fallbackUsable
                {
                    if pending.activeFullscreen, let rect = plan.fullscreenRect {
                        pending.rect = rect
                    } else if pending.activeMaximized, let rect = plan.maximizedRect {
                        pending.rect = rect
                    } else {
                        pending.rect = server.spaces.translateRectToOutput(
                            pending.rect,
                            fromOutputID: plan.removedOutputID,
                            fromUsable: plan.removedUsable,
                            toOutput: fallback,
                            toUsable: fallbackUsable,
                            layout: server.layout
                        )
                    }
                }
                changed = true
                specialChanged = true
            }

            return OutputMigrationResult(
                managed: true, changed: changed, specialChanged: specialChanged)
        }
    }

    package func tileRegion(command: TileCommand, output: LogicalRect) -> TileRegionPlan {
        if command == .maximize {
            return TileRegionPlan(
                action: .maximize,
                rect: WindowRect(
                    x: output.x,
                    y: output.y,
                    width: UInt32(max(1, output.width.rounded(.down))),
                    height: UInt32(max(1, output.height.rounded(.down)))
                ),
                edges: tileEdges(left: true, right: true, top: true, bottom: true)
            )
        }

        let halfWidth = output.width / 2.0
        let halfHeight = output.height / 2.0
        let region: (x: Double, y: Double, width: Double, height: Double)
        switch command {
        case .left:
            region = (output.x, output.y, halfWidth, output.height)
        case .right:
            region = (output.x + halfWidth, output.y, halfWidth, output.height)
        case .top:
            region = (output.x, output.y, output.width, halfHeight)
        case .bottom:
            region = (output.x, output.y + halfHeight, output.width, halfHeight)
        case .topLeft:
            region = (output.x, output.y, halfWidth, halfHeight)
        case .topRight:
            region = (output.x + halfWidth, output.y, halfWidth, halfHeight)
        case .bottomLeft:
            region = (output.x, output.y + halfHeight, halfWidth, halfHeight)
        case .bottomRight:
            region = (output.x + halfWidth, output.y + halfHeight, halfWidth, halfHeight)
        case .maximize:
            preconditionFailure("maximize handled before region switch")
        }

        let edgeEpsilon = 0.5
        let outputMaxX = output.x + output.width
        let outputMaxY = output.y + output.height
        return TileRegionPlan(
            action: .tile,
            rect: WindowRect(
                x: region.x,
                y: region.y,
                width: UInt32(max(1, region.width.rounded(.down))),
                height: UInt32(max(1, region.height.rounded(.down)))
            ),
            edges: tileEdges(
                left: region.x <= output.x + edgeEpsilon,
                right: region.x + region.width >= outputMaxX - edgeEpsilon,
                top: region.y <= output.y + edgeEpsilon,
                bottom: region.y + region.height >= outputMaxY - edgeEpsilon
            )
        )
    }

    private func tileEdges(left: Bool, right: Bool, top: Bool, bottom: Bool) -> TileEdges {
        var edges = TileEdges()
        edges.left = left
        edges.right = right
        edges.top = top
        edges.bottom = bottom
        return edges
    }
}
