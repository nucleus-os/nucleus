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
    /// Bring the shell up: install the host bundle, register native modules, create the bar
    /// surface, boot RN, and start the frame loop. Blocks in the loop until the compositor
    /// disconnects or a signal requests exit.
    public func run() async {
        client.onOutputsChanged = { [weak self] in
            self?.outputsChanged()
        }
        client.onGlobalChanged = { [weak self] kind in
            self?.waylandGlobalChanged(kind)
        }
        // 1. Acquire the initial desktop environment before the semantic
        //    context or any retained view exists.
        let initialEnvironment = setupEnvironment()

        // 2. The root render context the RN surface commits into.
        setupRenderContext(environment: initialEnvironment)

        // 4. The foreign-toplevel window model. Its snapshots flow to JS (native→JS) through
        //    the facade's emitDeviceEvent — no custom native module. (JS→native taskbar actions
        //    await the facade host-command seam; see pushWindowsToJS.)
        setupForeignToplevel()

        // 5. The seat: pointer and keyboard, translated into framework events.
        setupInput()

        // 6. System services. Each maps a bus peer onto a value type and hands
        //    it to a view; this is the only place the two meet.
        setupServices()

        // 7. The bar layer-shell surface. Its first configure builds the swapchain + boots RN.
        createBarSurface()

        // 8. The event loop: wl_display fd + a frame timer.
        running = true
        await loop()
    }

    func shutdown() async {
        await reactor.shutdown()
        environmentAdapter?.stop()
        environmentAdapter = nil
        dragDropAdapter?.shutdown()
        dragDropAdapter = nil
        if let host = rnHost, let surfaceID = barSurfaceID {
            do {
                try host.stopSurface(id: surfaceID)
            } catch {
                writeErr(
                    "nucleus-shell: failed to stop RN surface "
                        + "\(surfaceID): \(error)")
            }
        }
        // Destroy the native runtime before closing the eventfd captured by its
        // cross-thread wake callback. The sink still tolerates late calls, but
        // ordered teardown avoids producing them in the first place.
        rnHost = nil
        barSurface?.destroy()
        accessibilityAdapter?.close()
        accessibilityBridge = nil
        accessibilityAdapter = nil
        nativePublicationContext?.semanticContext
            .setAnimationFrameRequestHandler(nil)
        nativePublicationContext?.semanticContext.services.pasteboard.shutdown()
        barRootView = nil
        inputScene = nil
        inputRouter = nil
        renderContext = nil
        nativePublicationContext = nil
        pasteboardAdapter = nil
        engine.shutdown()
        renderWake.shutdown()
        hostBundle.invalidate()
    }
}
