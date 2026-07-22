@_spi(NucleusCompositor) import NucleusReactRuntime
import NucleusUI
import NucleusTextBackend
import NucleusUIEmbedder
import NucleusLayers
import NucleusRenderModel
import NucleusRenderHost
import NucleusAppHostBundle
import NucleusShellWayland
import NucleusShellPasteboard
import NucleusShellInput
import NucleusShellAuth
import NucleusLinuxDBus
import NucleusLinuxAccessibility
import NucleusShellServices
import NucleusLinuxEnvironment
import NucleusLinuxReactor
import NucleusShellProduct
import NucleusShellRender
import NucleusShellLoop
import NucleusRenderer
import NucleusShellSignalC
import Foundation
import Synchronization
import Tracy
#if canImport(Glibc)
import Glibc
#endif

@MainActor
extension ShellHost {
    // MARK: - Services

    func setupServices() {
        guard let bus = try? DBusConnection(.system) else {
            writeErr("shell: no system bus; running without system services")
            return
        }
        systemBus = bus

        let upower = UPowerService(connection: bus)
        upower.onChange = { [weak self] reading in
            self?.batteryWidget.update(BatteryLevel(
                fraction: reading.percentage / 100,
                isCharging: reading.state.isPluggedIn,
                isPresent: reading.isPresent,
                secondsRemaining: reading.secondsRemaining))
            self?.requestRender(nativeSceneChanged: true)
        }
        do {
            try upower.start()
        } catch {
            writeErr("shell: UPower unavailable: \(error)")
        }
        self.upower = upower
    }

    // MARK: - Bar surface

    func createBarSurface() {
        let config = LayerSurfaceConfig.topBar(height: barHeight)
        // Anchor to the first output (compositor picks if nil).
        let output = client.outputs.values.first
        guard let surface = LayerSurface(client: client, config: config, output: output) else {
            writeErr("shell: failed to create bar layer surface")
            return
        }
        surface.onConfigure = { [weak self] w, h in
            self?.onBarConfigured(width: Int32(w == 0 ? 1920 : w), height: Int32(h))
        }
        surface.onClosed = { [weak self] in self?.running = false }
        barSurface = surface
        client.flush()
    }

    func onBarConfigured(width: Int32, height: Int32) {
        let scale = Double(client.outputs.values.first?.scale ?? 1)
        guard let surface = barSurface, let renderContext else {
            writeErr("shell: bar configured without a render context")
            return
        }

        // Popovers place themselves inside the display, so the scene needs the
        // output's logical size. The bar's own configure is the first point at
        // which it is known; a popover opened before this would resolve inside a
        // zero rect.
        if let output = client.outputs.values.first, output.logicalWidth > 0 {
            inputScene?.displayBounds = Rect(
                x: 0, y: 0,
                width: Double(output.logicalWidth),
                height: Double(output.logicalHeight))
        }
        if let id = barOutputID {
            engine.resizeSurface(id, width: width, height: height, scale: scale)
        } else if let id = engine.addSurface(
            waylandSurface: surface.wlSurface,
            width: width,
            height: height,
            scale: scale,
            presentationContextID: renderContext.id.rawValue,
            refreshMillihertz:
                surface.output?.refreshMillihertz
                ?? client.outputs.values.first?.refreshMillihertz
                ?? 0
        ) {
            barOutputID = id
            bootReactBar(width: Double(width) / scale, height: Double(height) / scale, scale: scale)
        }
    }

    func outputsChanged() {
        if let barOutputID {
            let refresh = barSurface?.output?.refreshMillihertz
                ?? client.outputs.values.first?.refreshMillihertz
                ?? 0
            engine.setRefreshMillihertz(refresh, forSurface: barOutputID)
        }
        lockController?.updateOutputRefreshRates()
        requestRender(nativeSceneChanged: true)
    }

    // MARK: - React boot (the NucleusReactRuntime.Host facade)

    func bootReactBar(width: Double, height: Double, scale: Double) {
        guard let renderContext, let nativePublicationContext else { return }
        do {
            let rootView = nativePublicationContext.withSemanticContext {
                View()
            }
            let host = try NucleusReactRuntime.Host()
            try host.installFabricRuntime()
            let surfaceID = 1
            try host.registerSurface(id: surfaceID)
            try host.configureSurface(id: surfaceID, width: width, height: height)
            try host.setDisplayMetrics(width: width, height: height, scale: scale, fontScale: 1.0)
            try host.evaluateBundle(at: bundleURL)
            try host.runApplication(surfaceID: surfaceID, appKey: "bar")
            _ = try host.attachSurface(
                rootView: rootView, surfaceID: surfaceID,
                visualContext: renderContext,
                backingScaleFactor: BackingScaleFactor(Float(scale)), at: 0)
            // JS→native taskbar actions: NucleusHostCommand.invoke(command, argsJson) fires
            // on the JS thread → push onto the thread-safe inbox the frame loop drains onto
            // the main actor (the Wayland client is single-threaded / @MainActor).
            let inbox = commandInbox
            try host.setCommandHandler { command, argsJson in inbox.push(command, argsJson) }
            let renderWake = self.renderWake
            try host.setJSWorkWakeHandler {
                renderWake.signalRenderWork()
            }
            rnHost = host
            barRootView = rootView
            barSurfaceID = surfaceID
        } catch {
            writeErr("shell: RN boot failed: \(error)")
        }
    }

    // MARK: - Foreign-toplevel → taskbar

    func setupForeignToplevel() {
        guard let manager = ForeignToplevelManager(client: client) else { return }
        manager.onChanged = { [weak self] in self?.pushWindowsToJS() }
        toplevels = manager
    }

    func pushWindowsToJS() {
        guard let windows = toplevels?.windows, let host = rnHost else { return }
        // Serialize the window snapshot and push it to JS via the facade (native→JS). The bar's
        // taskbar subscribes with DeviceEventEmitter.addListener("nucleusShellWindows", …).
        let snapshot: [[String: Any]] = windows.map { window in
            [
                // A 64-bit handle exceeds JS's precise integer range.
                "id": String(window.id),
                "title": window.title,
                "appId": window.appID,
                "activated": window.activated,
                "minimized": window.minimized,
            ]
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: snapshot)
            guard let json = String(data: data, encoding: .utf8) else {
                writeErr("nucleus-shell: window snapshot was not UTF-8")
                return
            }
            try host.emitDeviceEvent(name: "nucleusShellWindows", payloadJson: json)
        } catch {
            writeErr("nucleus-shell: failed to publish window snapshot: \(error)")
        }
    }

    /// Route a JS→native taskbar command (drained from the inbox on the main actor) to the
    /// foreign-toplevel client. `argsJson` is `{"id": <n|"n">, …}`; ids may be strings to
    /// survive JS's 2^53 number precision (a toplevel id is a 64-bit handle).
    func applyCommand(_ command: String, _ argsJson: String) {
        guard let data = argsJson.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let id: UInt64
        if let n = obj["id"] as? NSNumber { id = n.uint64Value }
        else if let s = obj["id"] as? String, let v = UInt64(s) { id = v }
        else { return }
        switch command {
        case "activate": toplevels?.activate(id: id)
        case "close": toplevels?.close(id: id)
        case "setMinimized": toplevels?.setMinimized(id: id, (obj["minimized"] as? Bool) ?? false)
        default: break
        }
    }
}
