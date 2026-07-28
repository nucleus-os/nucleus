import NucleusConfig
import NucleusSessionProtocol
import NucleusShellProduct
import NucleusShellServices
@_spi(NucleusWindowClientImplementation)
import NucleusWindowClientWayland
import NucleusUI
import NucleusUIEmbedder

@MainActor
struct NativeFeedbackSurface {
    let layerSurface: NucleusDesktopLayerSurface
    let surfaceID: UInt
    let outputID: UInt32
    let logicalOrigin: Point
}

@MainActor
extension ShellHost {
    func reconcileFeedbackSurface(_ state: ShellFeedbackState) {
        destroyFeedbackSurface()
        guard state != .hidden,
              let nativePublicationContext,
              let surfaceRegistry,
              let output = feedbackOutput(for: state)
        else { return }

        let width: UInt32
        let height: UInt32
        let localX: Int32
        let localY: Int32
        switch state {
        case .hidden:
            return
        case .hotkey:
            width = 420
            height = UInt32(min(
                640,
                max(160, 72 + liveConfiguration.displayedBinds.count * 20)))
            localX = max(0, (output.logicalWidth - Int32(width)) / 2)
            localY = 60
        case .windowMenu(_, let x, let y, _):
            width = 240
            height = 252
            localX = max(
                0,
                min(
                    max(0, output.logicalWidth - Int32(width)),
                    Int32(x.rounded()) - output.logicalX))
            localY = max(
                0,
                min(
                    max(0, output.logicalHeight - Int32(height)),
                    Int32(y.rounded()) - output.logicalY))
        }

        let (view, window) = nativePublicationContext
            .withSemanticContext {
                let view = ShellFeedbackView()
                switch state {
                case .hidden:
                    break
                case .hotkey:
                    view.showHotkeys(
                        liveConfiguration.displayedBinds.map {
                            "\($0.keys.text) — \($0.action.name)"
                        })
                case .windowMenu(
                    let windowID, _, _, let capabilities):
                    view.showWindowMenu(
                        capabilities: capabilities,
                        perform: { [weak self] verb in
                            self?.selectWindowMenuItem(
                                windowID: windowID,
                                verb: verb)
                        })
                }
                let window = Window(
                    title: "Nucleus Shell Feedback",
                    role: .layer,
                    level: .criticalOverlay)
                window.setContentView(view)
                return (view, window)
            }
        _ = view
        let layerSurface = NucleusDesktopLayerSurface(
            client: client,
            config: .shellFeedback(
                width: width,
                height: height,
                marginTop: localY,
                marginLeft: localX,
                namespace: "nucleus-shell.feedback"),
            output: output)
        guard let layerSurface else { return }
        let surfaceID = surfaceRegistry.register(
            window: window,
            waylandSurface: layerSurface.wlSurface,
            refreshMillihertz: output.refreshMillihertz)
        let origin = Point(
            x: Double(output.logicalX + localX),
            y: Double(output.logicalY + localY))
        feedbackSurface = NativeFeedbackSurface(
            layerSurface: layerSurface,
            surfaceID: surfaceID,
            outputID: output.registryName,
            logicalOrigin: origin)
        layerSurface.onConfigure = { [weak self] configuredWidth,
            configuredHeight in
            guard let self,
                  let record = feedbackSurface,
                  let output = client.outputs[record.outputID]
            else { return }
            _ = surfaceRegistry.configure(
                surfaceID: record.surfaceID,
                logicalOrigin: record.logicalOrigin,
                logicalWidth: Double(
                    configuredWidth == 0 ? width : configuredWidth),
                logicalHeight: Double(
                    configuredHeight == 0 ? height : configuredHeight),
                scale: Double(max(1, output.scale)),
                refreshMillihertz: output.refreshMillihertz)
        }
        layerSurface.onClosed = { [weak self] in
            self?.actionDispatcher.dismissFeedback()
        }
        _ = client.flush()
    }

    func destroyFeedbackSurface() {
        guard let record = feedbackSurface else { return }
        feedbackSurface = nil
        surfaceRegistry?.unregister(surfaceID: record.surfaceID)
        record.layerSurface.destroy()
    }

    private func feedbackOutput(
        for state: ShellFeedbackState
    ) -> NucleusDesktopOutput? {
        let ordered = client.outputs.values.sorted {
            $0.registryName < $1.registryName
        }
        guard case .windowMenu(_, let x, let y, _) = state else {
            return ordered.first
        }
        return ordered.first {
            x >= Double($0.logicalX)
                && y >= Double($0.logicalY)
                && x < Double($0.logicalX + $0.logicalWidth)
                && y < Double($0.logicalY + $0.logicalHeight)
        } ?? ordered.first
    }

    private func selectWindowMenuItem(
        windowID: UInt64,
        verb: UInt32
    ) {
        do {
            try policyChannel?.send(ShellPolicyRequest(
                kind: .selectWindowMenuItem,
                windowID: windowID,
                windowMenuVerb: verb))
        } catch {
            running = false
        }
        actionDispatcher.dismissFeedback()
    }
}
