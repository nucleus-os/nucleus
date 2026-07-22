import NucleusUIEmbedder

@MainActor
extension ShellHost {
    /// Bring up the native Swift product and drive it until the compositor
    /// disconnects or a process signal requests exit.
    public func run() async {
        client.onOutputsChanged = { [weak self] in
            self?.outputsChanged()
        }
        client.onGlobalChanged = { [weak self] kind in
            self?.waylandGlobalChanged(kind)
        }

        let initialEnvironment = setupEnvironment()
        setupRenderContext(environment: initialEnvironment)
        setupInput()
        setupProduct()
        setupForeignToplevel()
        setupServices()
        reconcileBarSurfaces()

        guard nativePublicationContext != nil,
              inputScene != nil,
              surfaceRegistry != nil,
              productController != nil
        else {
            writeErr("nucleus-shell: native runtime bring-up failed")
            await shutdown()
            return
        }

        running = true
        await loop()
    }

    func shutdown() async {
        await reactor.shutdown()
        environmentAdapter?.stop()
        environmentAdapter = nil
        dragDropAdapter?.shutdown()
        dragDropAdapter = nil
        authenticator?.cancelPendingAttempt()
        authenticator = nil
        upower?.stop()
        upower = nil
        systemBus?.close()
        systemBus = nil
        lockController?.shutdown()
        lockController = nil
        destroyAllBarSurfaces()
        surfaceRegistry?.unregisterAll()
        surfaceRegistry = nil
        do {
            try inputScene?.disconnect()
        } catch {
            writeErr("nucleus-shell: native scene teardown failed: \(error)")
        }
        accessibilityAdapter?.close()
        accessibilityBridge = nil
        accessibilityAdapter = nil
        nativePublicationContext?.semanticContext
            .setAnimationFrameRequestHandler(nil)
        nativePublicationContext?.semanticContext.services.pasteboard.shutdown()
        productController = nil
        inputScene = nil
        inputRouter = nil
        seat = nil
        toplevels = nil
        nativePublicationContext = nil
        pasteboardAdapter = nil
        engine.shutdown()
        renderWake.shutdown()
        hostBundle.invalidate()
    }
}
