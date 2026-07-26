import FoundationEssentials
import NucleusShellProduct
import NucleusShellWayland
import NucleusUI
import NucleusUIEmbedder

@MainActor
struct NativeWallpaperSurface {
    let outputID: UInt32
    let layerSurface: LayerSurface
    let surfaceID: UInt
    let window: Window
    let product: ShellWallpaperProduct
}

@MainActor
extension ShellHost {
    func reconcileWallpaperSurfaces() {
        guard let productController, let nativePublicationContext,
              let surfaceRegistry
        else { return }

        guard FileManager.default.isReadableFile(atPath: wallpaperPath) else {
            if !wallpaperFailureReported {
                wallpaperFailureReported = true
                writeErr("shell: wallpaper is not readable: \(wallpaperPath)")
            }
            destroyAllWallpaperSurfaces()
            return
        }
        wallpaperFailureReported = false

        let liveOutputIDs = Set(client.outputs.keys)
        for outputID in Array(wallpaperSurfaces.keys)
            where !liveOutputIDs.contains(outputID)
        {
            destroyWallpaperSurface(outputID: outputID)
        }

        for output in client.outputs.values
            where wallpaperSurfaces[output.registryName] == nil
        {
            let outputID = output.registryName
            let (wallpaperProduct, window) = nativePublicationContext
                .withSemanticContext {
                let wallpaperProduct = productController.makeWallpaper(
                    forOutput: outputID,
                    sourcePath: wallpaperPath,
                    sourceSize: Size(width: 16, height: 9))
                let window = Window(
                    title: "Nucleus Wallpaper",
                    role: .layer,
                    level: .desktop,
                    participatesInHitTesting: false)
                window.setContentView(wallpaperProduct.imageView)
                return (wallpaperProduct, window)
            }
            let config = LayerSurfaceConfig.wallpaper(
                namespace: "nucleus-shell.wallpaper.\(outputID)")
            guard let layerSurface = LayerSurface(
                client: client,
                config: config,
                output: output)
            else {
                productController.removeWallpaper(forOutput: outputID)
                writeErr(
                    "shell: failed to create wallpaper for output \(outputID)")
                continue
            }
            let surfaceID = surfaceRegistry.register(
                window: window,
                waylandSurface: layerSurface.wlSurface,
                refreshMillihertz: output.refreshMillihertz)
            let record = NativeWallpaperSurface(
                outputID: outputID,
                layerSurface: layerSurface,
                surfaceID: surfaceID,
                window: window,
                product: wallpaperProduct)
            wallpaperSurfaces[outputID] = record
            layerSurface.onConfigure = { [weak self] width, height in
                self?.writeErr(
                    "shell: wallpaper configure received output=\(outputID) "
                        + "size=\(width)x\(height)")
                self?.configureWallpaperSurface(
                    outputID: outputID,
                    width: width,
                    height: height)
            }
            layerSurface.onClosed = { [weak self] in
                self?.destroyWallpaperSurface(outputID: outputID)
            }
            writeErr(
                "shell: wallpaper output=\(outputID) source=\(wallpaperPath)")
        }
        updateSceneDisplayBounds()
        _ = client.flush()
    }

    func configureWallpaperSurface(
        outputID: UInt32,
        width: UInt32,
        height: UInt32
    ) {
        guard let record = wallpaperSurfaces[outputID],
              let output = client.outputs[outputID],
              let surfaceRegistry
        else { return }

        let logicalWidth = Double(width != 0
            ? width
            : UInt32(max(1, output.logicalWidth)))
        let logicalHeight = Double(height != 0
            ? height
            : UInt32(max(1, output.logicalHeight)))
        let configured = surfaceRegistry.configure(
            surfaceID: record.surfaceID,
            logicalOrigin: Point(
                x: Double(output.logicalX),
                y: Double(output.logicalY)),
            logicalWidth: logicalWidth,
            logicalHeight: logicalHeight,
            scale: Double(max(1, output.scale)),
            refreshMillihertz: output.refreshMillihertz)
        if !configured {
            writeErr(
                "shell: failed to configure wallpaper on output \(outputID)")
        } else {
            writeErr("shell: native wallpaper ready on output \(outputID)")
        }
    }

    func destroyWallpaperSurface(outputID: UInt32) {
        guard let record = wallpaperSurfaces.removeValue(forKey: outputID)
        else { return }
        surfaceRegistry?.unregister(surfaceID: record.surfaceID)
        record.layerSurface.destroy()
        productController?.removeWallpaper(forOutput: outputID)
    }

    func destroyAllWallpaperSurfaces() {
        for outputID in Array(wallpaperSurfaces.keys) {
            destroyWallpaperSurface(outputID: outputID)
        }
    }
}
