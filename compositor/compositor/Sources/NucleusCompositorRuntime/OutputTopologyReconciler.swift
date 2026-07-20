import NucleusCompositorRenderRuntime
import NucleusCompositorOverlayScene
import NucleusCompositorOverlayTypes
import NucleusCompositorServer
import NucleusCompositorWaylandRuntime
import NucleusCompositorWindowManager

struct PlannedOutput: Equatable {
    let renderer: RenderRuntime.OutputInfo

    var id: DisplayID { renderer.id }
}

struct AppliedOutput: Equatable {
    let renderer: RenderRuntime.OutputInfo
    let configuration: DisplayConfiguration
    let name: String
    let description: String

    var id: DisplayID { renderer.id }

    var topologyFingerprint: OutputTopologyFingerprint {
        Self.fingerprint(renderer)
    }

    static func fingerprint(
        _ renderer: RenderRuntime.OutputInfo
    ) -> OutputTopologyFingerprint {
        OutputTopologyFingerprint(
            outputID: renderer.id,
            pixelWidth: renderer.pixelWidth,
            pixelHeight: renderer.pixelHeight,
            refreshMilliHz: renderer.refreshMhz,
            crtcID: renderer.crtcID,
            primaryPlaneID: renderer.primaryPlaneID,
            cursorPlaneID: renderer.cursorPlaneID)
    }
}

struct OutputTopologyChangeSet {
    let removed: [AppliedOutput]
    let changed: [(old: AppliedOutput, new: PlannedOutput)]
    let added: [PlannedOutput]
    let unchanged: [(old: AppliedOutput, new: PlannedOutput)]

    static func compute(
        current: [DisplayID: AppliedOutput],
        proposed: [RenderRuntime.OutputInfo],
        forceReattach: Bool = false
    ) -> Self {
        let planned = Dictionary(
            uniqueKeysWithValues: proposed.map { ($0.id, PlannedOutput(renderer: $0)) })
        let diff = OutputTopologyDiff.compute(
            current: current.values.map(\.topologyFingerprint),
            proposed: proposed.map(AppliedOutput.fingerprint),
            forceChanged: forceReattach)
        return Self(
            removed: diff.removed.compactMap { current[$0] },
            changed: diff.changed.compactMap { id in
                guard let old = current[id], let new = planned[id]
                else { return nil }
                return (old, new)
            },
            added: diff.added.compactMap { planned[$0] },
            unchanged: diff.unchanged.compactMap { id in
                guard let old = current[id], let new = planned[id]
                else { return nil }
                return (old, new)
            })
    }
}

/// The sole owner of physical-output topology transitions. One invocation
/// reconciles renderer bindings, the desktop model, and Wayland advertisements
/// on the main actor.
@MainActor
final class OutputTopologyReconciler {
    private var applied: [DisplayID: AppliedOutput] = [:]
    private var rememberedPlacements: [DisplayID: (x: Double, y: Double)] = [:]
    private let defaultScale: Double

    init(defaultScale: Double) {
        self.defaultScale = max(0.01, defaultScale)
    }

    @discardableResult
    func reconcile(forceReattach: Bool = false) -> Bool {
        guard let proposal = RenderRuntime.proposeOutputTopology() else {
            logRuntime("output topology: discovery failed; preserving applied outputs")
            return false
        }
        let changes = OutputTopologyChangeSet.compute(
            current: applied, proposed: proposal.outputs,
            forceReattach: forceReattach)

        let retiring = Set(
            changes.removed.map(\.id)
                + changes.changed.map { $0.old.id })
        guard RenderRuntime.retireOutputs(retiring) else {
            logRuntime(
                "output topology: atomic retirement failed; preserving applied topology")
            return false
        }
        for output in changes.removed {
            rememberPlacement(output)
        }
        for change in changes.changed {
            rememberPlacement(change.old)
        }

        for output in changes.removed {
            withdraw(output)
        }

        for change in changes.changed {
            if let replacement = attach(
                change.new, preserving: change.old.configuration,
                name: change.old.name, description: change.old.description)
            {
                applied[replacement.id] = replacement
                advertise(replacement)
            } else {
                withdraw(change.old)
            }
        }

        for output in changes.added {
            guard let attached = attach(output) else { continue }
            applied[attached.id] = attached
            advertise(attached)
        }

        for pair in changes.unchanged {
            let refreshed = AppliedOutput(
                renderer: pair.new.renderer,
                configuration: pair.old.configuration,
                name: pair.old.name,
                description: pair.old.description)
            applied[refreshed.id] = refreshed
            refreshServerDisplay(refreshed)
            advertise(refreshed)
        }

        RenderRuntime.commitProposedTopology(
            generation: proposal.generation,
            appliedOutputIDs: Set(applied.keys))
        refreshDerivedOutputState()
        return true
    }

    private func rememberPlacement(_ output: AppliedOutput) {
        rememberedPlacements[output.id] = (
            output.configuration.logicalX, output.configuration.logicalY)
    }

    private func withdraw(_ output: AppliedOutput) {
        _ = WaylandRuntime.prepareOutputRemoval(output.id)
        _ = WindowManager.shared.removeOutput(output.id)
        WaylandRuntime.finishOutputRemoval(output.id)
        applied[output.id] = nil
    }

    private func attach(
        _ planned: PlannedOutput,
        preserving previous: DisplayConfiguration? = nil,
        name: String? = nil,
        description: String? = nil
    ) -> AppliedOutput? {
        let scale = previous?.fractionalScale ?? defaultScale
        let integerScale = previous?.scale
            ?? UInt32(max(1.0, scale.rounded(.up)))
        let placement = previous.map { ($0.logicalX, $0.logicalY) }
            ?? rememberedPlacements[planned.id].map { ($0.x, $0.y) }
            ?? nextPlacement()
        let mode = DisplayMode(
            pixelWidth: planned.renderer.pixelWidth,
            pixelHeight: planned.renderer.pixelHeight,
            refreshMhz: planned.renderer.refreshMhz)
        let configuration = DisplayConfiguration(
            enabled: true,
            primary: previous?.primary
                ?? NucleusCompositorServer.shared.layout.displays.isEmpty,
            logicalX: placement.0,
            logicalY: placement.1,
            logicalWidth: Double(planned.renderer.pixelWidth) / scale,
            logicalHeight: Double(planned.renderer.pixelHeight) / scale,
            scale: integerScale,
            fractionalScale: scale,
            mode: mode)
        guard RenderRuntime.applyProposedOutput(
            planned.renderer,
            logicalX: configuration.logicalX,
            logicalY: configuration.logicalY,
            logicalWidth: configuration.logicalWidth
                ?? Double(planned.renderer.pixelWidth) / scale,
            logicalHeight: configuration.logicalHeight
                ?? Double(planned.renderer.pixelHeight) / scale,
            fractionalScale: scale)
        else {
            logRuntime("output topology: failed to attach output \(planned.id)")
            return nil
        }

        let outputName = name ?? "DRM-\(planned.id)"
        let outputDescription = description ?? "Nucleus DRM output"
        if let display = NucleusCompositorServer.shared.layout.display(id: planned.id) {
            display.apply(configuration)
            display.physicalWidthMM = planned.renderer.physicalWidthMM
            display.physicalHeightMM = planned.renderer.physicalHeightMM
            display.name = outputName
            display.description = outputDescription
        } else {
            NucleusCompositorServer.shared.layout.addDisplay(
                id: planned.id,
                configuration: configuration,
                name: outputName,
                description: outputDescription,
                physicalWidthMM: planned.renderer.physicalWidthMM,
                physicalHeightMM: planned.renderer.physicalHeightMM)
            NucleusCompositorServer.shared.spaces.ensureDisplay(planned.id)
        }
        rememberedPlacements[planned.id] = nil
        return AppliedOutput(
            renderer: planned.renderer,
            configuration: configuration,
            name: outputName,
            description: outputDescription)
    }

    private func advertise(_ output: AppliedOutput) {
        guard let display = NucleusCompositorServer.shared.layout.display(id: output.id)
        else { return }
        display.name.withCString { name in
            display.description.withCString { description in
                WaylandRuntime.addOutput(
                    display.id,
                    Int32(clamping: Int(display.logicalRect.x.rounded())),
                    Int32(clamping: Int(display.logicalRect.y.rounded())),
                    display.physicalWidthMM,
                    display.physicalHeightMM,
                    Int32(bitPattern: display.pixelSize.width),
                    Int32(bitPattern: display.pixelSize.height),
                    display.refreshMHz,
                    Int32(bitPattern: display.scale),
                    Int32(clamping: Int(display.logicalRect.width.rounded())),
                    Int32(clamping: Int(display.logicalRect.height.rounded())),
                    display.fractionalScale,
                    name,
                    description)
            }
        }
    }

    private func refreshServerDisplay(
        _ output: AppliedOutput
    ) {
        guard let display =
            NucleusCompositorServer.shared.layout.display(
                id: output.id)
        else { return }
        display.apply(output.configuration)
        display.physicalWidthMM =
            output.renderer.physicalWidthMM
        display.physicalHeightMM =
            output.renderer.physicalHeightMM
        display.name = output.name
        display.description = output.description
    }

    private func nextPlacement() -> (Double, Double) {
        let layout = NucleusCompositorServer.shared.layout
        guard let bounds = layout.desktopBounds() else { return (0, 0) }
        let primaryY = layout.primaryDisplayID()
            .flatMap { layout.display(id: $0)?.logicalRect.y }
            ?? bounds.y
        return (bounds.maxX, primaryY)
    }

    private func refreshDerivedOutputState() {
        guard let primary = NucleusCompositorServer.shared.layout.primaryDisplayID()
            .flatMap({ NucleusCompositorServer.shared.layout.display(id: $0) })
        else { return }
        DisplayFrameDemand.requestFrame(reason: .outputChange)
        OverlaySceneRuntime.shared.frameUpdated(FrameInfo(
            outputWidth: UInt32(max(1, primary.logicalRect.width.rounded())),
            outputHeight: UInt32(max(1, primary.logicalRect.height.rounded())),
            devicePixelRatio: Float(primary.fractionalScale),
            overlayRegionX: 0,
            overlayRegionY: 0,
            overlayRegionW: Float(primary.logicalRect.width),
            overlayRegionH: Float(primary.logicalRect.height)))
    }
}
