import NucleusUI
import NucleusUIEmbedder
import NucleusLayers

extension Host {
    @MainActor
    @discardableResult
    @_spi(NucleusCompositor) public func attachSurface(
        rootView: View,
        surfaceID: Int = 1,
        parentLayer: Layer? = nil,
        backingScaleFactor: BackingScaleFactor = .one,
        at index: UInt32 = UInt32.max
    ) throws -> ViewComponentViewRegistry {
        guard let consumer = mountConsumer else {
            return ViewComponentViewRegistry()
        }
        let renderContext = rootView.embedderBackingLayer.context
        let environment = ReactSurfaceEnvironment(backingScaleFactor: backingScaleFactor)
        let registry = surfaceRegistries[surfaceID] ?? ViewComponentViewRegistry()
        surfaceRegistries[surfaceID] = registry

        let surfaceContext: MountSurfaceContext
        if let existing = consumer.context(surfaceID: surfaceID) {
            existing.environment = environment
            surfaceContext = existing
        } else {
            surfaceContext = MountSurfaceContext(
                surfaceID: surfaceID,
                rootView: rootView,
                registry: registry,
                environment: environment
            )
        }

        // The materialize callback runs after each batch is applied.
        // For the initial registration flush, errors are captured here
        // and re-thrown so the caller's `try` sees them — mirroring the
        // previous synchronous shape. Errors thrown during later
        // transactions have no caller to throw to and are dropped.
        var thrownError: Error?
        surfaceContext.onMaterialize = { [weak self] registry in
            guard let self else { return }
            do {
                try self.applyAttachSideEffects(
                    surfaceID: surfaceID,
                    rootView: rootView,
                    parentLayer: parentLayer,
                    insertionIndex: index,
                    registry: registry,
                    renderContext: renderContext,
                    environment: environment
                )
            } catch {
                thrownError = error
            }
        }

        EmbedderApplication.withContext(renderContext) {
            consumer.registerContext(surfaceContext)
        }

        if let error = thrownError {
            throw error
        }
        return registry
    }

    @MainActor
    package func detachSurface(surfaceID: Int) {
        mountConsumer?.unregisterContext(surfaceID: surfaceID)
        surfaceRegistries.removeValue(forKey: surfaceID)
        attachedSurfaceIDs.remove(surfaceID)
    }

    @MainActor
    private func applyAttachSideEffects(
        surfaceID: Int,
        rootView: View,
        parentLayer: Layer?,
        insertionIndex: UInt32,
        registry: ViewComponentViewRegistry,
        renderContext: Context,
        environment: ReactSurfaceEnvironment
    ) throws {
        for component in registry.components where component.view !== rootView {
            component.updateEnvironment(environment)
        }

        if !attachedSurfaceIDs.contains(surfaceID) {
            var transaction = LayerTransaction(context: renderContext)
            try transaction.createExisting(rootView.embedderBackingLayer)
            for component in registry.components where component.view !== rootView {
                try transaction.createExisting(component.view.embedderBackingLayer)
            }
            try transaction.insert(rootView.embedderBackingLayer, into: parentLayer, at: insertionIndex)
            try transaction.commit()
            attachedSurfaceIDs.insert(surfaceID)
        }

        for component in registry.components {
            try component.commitDisplayContentIfNeeded()
        }
        try LayerTransaction.flushImplicit(in: renderContext)
    }
}
