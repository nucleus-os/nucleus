import FoundationEssentials
import FoundationInternationalization
import NucleusLinuxDBus
import NucleusShellProduct
import NucleusShellServices
import NucleusShellWayland
import NucleusUI
import NucleusUIEmbedder

@MainActor
struct NativeBarSurface {
    let outputID: UInt32
    let layerSurface: LayerSurface
    let surfaceID: UInt
    let window: Window
    let product: ShellBarProduct
}

@MainActor
extension ShellHost {
    // MARK: - Product and services

    func setupProduct() {
        guard let nativePublicationContext else {
            writeErr("shell: native product requires a publication context")
            return
        }
        let product = nativePublicationContext.withSemanticContext {
            ShellProductController()
        }
        product.onWindowAction = { [weak self] id, action in
            self?.applyWindowAction(action, id: id)
        }
        productController = product
        refreshClock(nowNanoseconds: monotonicNowNs(), force: true)
    }

    func setupServices() {
        guard let bus = try? DBusConnection(.system) else {
            writeErr("shell: no system bus; running without system services")
            return
        }
        systemBus = bus

        let upower = UPowerService(connection: bus)
        upower.onChange = { [weak self] reading in
            self?.productController?.updateBattery(BatteryLevel(
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

    // MARK: - Native bars

    func reconcileBarSurfaces() {
        guard let productController, let nativePublicationContext,
              let surfaceRegistry
        else { return }

        let liveOutputIDs = Set(client.outputs.keys)
        for outputID in Array(barSurfaces.keys)
            where !liveOutputIDs.contains(outputID)
        {
            destroyBarSurface(outputID: outputID)
        }

        for output in client.outputs.values
            where barSurfaces[output.registryName] == nil
        {
            let outputID = output.registryName
            let (barProduct, window) = nativePublicationContext
                .withSemanticContext {
                let barProduct = productController.makeBar(
                    forOutput: outputID)
                barProduct.barView.thickness = Double(barHeight)
                let window = Window(
                    title: "Nucleus Bar",
                    role: .layer,
                    level: .shellChrome)
                window.setContentView(barProduct.barView)
                return (barProduct, window)
            }
            let config = LayerSurfaceConfig.topBar(
                height: barHeight,
                namespace: "nucleus-shell.bar.\(outputID)")
            guard let layerSurface = LayerSurface(
                client: client,
                config: config,
                output: output)
            else {
                productController.removeBar(forOutput: outputID)
                writeErr("shell: failed to create bar for output \(outputID)")
                continue
            }
            let surfaceID = surfaceRegistry.register(
                window: window,
                waylandSurface: layerSurface.wlSurface,
                refreshMillihertz: output.refreshMillihertz)
            let record = NativeBarSurface(
                outputID: outputID,
                layerSurface: layerSurface,
                surfaceID: surfaceID,
                window: window,
                product: barProduct)
            barSurfaces[outputID] = record
            layerSurface.onConfigure = { [weak self] width, height in
                self?.writeErr(
                    "shell: bar configure received output=\(outputID) "
                        + "size=\(width)x\(height)")
                self?.configureBarSurface(
                    outputID: outputID,
                    width: width,
                    height: height)
            }
            layerSurface.onClosed = { [weak self] in
                self?.destroyBarSurface(outputID: outputID)
            }
        }
        updateSceneDisplayBounds()
        _ = client.flush()
    }

    func configureBarSurface(
        outputID: UInt32,
        width: UInt32,
        height: UInt32
    ) {
        guard let record = barSurfaces[outputID],
              let output = client.outputs[outputID],
              let surfaceRegistry
        else { return }

        let logicalWidth = Double(width != 0
            ? width
            : UInt32(max(1, output.logicalWidth)))
        let logicalHeight = Double(height != 0 ? height : barHeight)
        let scale = Double(max(1, output.scale))
        record.product.barView.thickness = logicalHeight
        let configured = surfaceRegistry.configure(
            surfaceID: record.surfaceID,
            logicalOrigin: Point(
                x: Double(output.logicalX),
                y: Double(output.logicalY)),
            logicalWidth: logicalWidth,
            logicalHeight: logicalHeight,
            scale: scale,
            refreshMillihertz: output.refreshMillihertz)
        if !configured {
            writeErr("shell: failed to configure native bar on output \(outputID)")
        } else {
            writeErr("shell: native bar ready on output \(outputID)")
        }
    }

    func destroyBarSurface(outputID: UInt32) {
        guard let record = barSurfaces.removeValue(forKey: outputID) else {
            return
        }
        surfaceRegistry?.unregister(surfaceID: record.surfaceID)
        record.layerSurface.destroy()
        productController?.removeBar(forOutput: outputID)
    }

    func destroyAllBarSurfaces() {
        for outputID in Array(barSurfaces.keys) {
            destroyBarSurface(outputID: outputID)
        }
    }

    func outputsChanged() {
        reconcileWallpaperSurfaces()
        reconcileBarSurfaces()
        for record in wallpaperSurfaces.values {
            guard let output = client.outputs[record.outputID] else { continue }
            surfaceRegistry?.updateRefreshRate(
                output.refreshMillihertz,
                surfaceID: record.surfaceID)
        }
        for record in barSurfaces.values {
            guard let output = client.outputs[record.outputID] else { continue }
            surfaceRegistry?.updateRefreshRate(
                output.refreshMillihertz,
                surfaceID: record.surfaceID)
        }
        lockController?.outputsChanged()
        updateSceneDisplayBounds()
        requestRender(nativeSceneChanged: true)
    }

    func updateSceneDisplayBounds() {
        let rects = client.outputs.values.compactMap { output -> Rect? in
            guard output.logicalWidth > 0, output.logicalHeight > 0 else {
                return nil
            }
            return Rect(
                x: Double(output.logicalX),
                y: Double(output.logicalY),
                width: Double(output.logicalWidth),
                height: Double(output.logicalHeight))
        }
        guard let first = rects.first else { return }
        inputScene?.displayBounds = rects.dropFirst().reduce(first) {
            $0.union($1)
        }
    }

    // MARK: - Clock

    func refreshClock(
        nowNanoseconds: UInt64,
        force: Bool = false
    ) {
        if !force, let deadline = nextClockUpdateNanoseconds,
           nowNanoseconds < deadline
        {
            return
        }
        let now = Date()
        productController?.updateClock(
            displayText: now.formatted(clockFormatStyle))

        let secondsIntoMinute = now.timeIntervalSince1970
            .truncatingRemainder(dividingBy: 60)
        let untilNextMinute = max(0.05, 60 - secondsIntoMinute)
        let delta = UInt64(
            min(Double(UInt64.max), untilNextMinute * 1_000_000_000))
        nextClockUpdateNanoseconds = clampedAdd(nowNanoseconds, delta)
        requestRender(nativeSceneChanged: true)
    }

    // MARK: - Foreign toplevels

    func setupForeignToplevel() {
        guard let manager = ForeignToplevelManager(client: client) else {
            productController?.updateWindows([])
            return
        }
        manager.onChanged = { [weak self] in
            self?.publishWindowSnapshots()
        }
        toplevels = manager
        publishWindowSnapshots()
    }

    func publishWindowSnapshots() {
        let snapshots = toplevels?.windows.map {
            ShellWindowSnapshot(
                id: $0.id,
                title: $0.title,
                applicationID: $0.appID,
                isActive: $0.activated,
                isMinimized: $0.minimized)
        } ?? []
        productController?.updateWindows(snapshots)
        requestRender(nativeSceneChanged: true)
    }

    func applyWindowAction(
        _ action: ShellWindowAction,
        id: UInt64
    ) {
        switch action {
        case .activate:
            toplevels?.activate(id: id)
        case .close:
            toplevels?.close(id: id)
        case .setMinimized(let minimized):
            toplevels?.setMinimized(id: id, minimized)
        }
        _ = client.flush()
    }
}
