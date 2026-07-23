public import NucleusUI
import NucleusUIEmbedder
public import NucleusLayers

extension Host {
    @MainActor
    @discardableResult
    @_spi(NucleusCompositor) public func attachSurface(
        rootView: View,
        surfaceID: Int = 1,
        visualContext: Context,
        parentLayer: Layer? = nil,
        backingScaleFactor: BackingScaleFactor = .one,
        at index: UInt32 = UInt32.max
    ) throws -> ViewComponentViewRegistry {
        guard let consumer = mountConsumer else {
            return ViewComponentViewRegistry()
        }
        let renderContext = parentLayer?.context ?? visualContext
        precondition(
            parentLayer == nil || parentLayer?.context === visualContext,
            "the explicit visual context must own the parent layer")
        let publisher = surfacePublishers[surfaceID] ??
            EmbeddedViewTreePublisher(visualContext: renderContext)
        surfacePublishers[surfaceID] = publisher
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

        // The materialize callback runs after each batch is applied. The
        // initial registration flush rethrows to this call site. A later batch
        // has no synchronous caller, so its failure is retained on `Host` and
        // delivered through the host's diagnostic callback.
        var thrownError: (any Error)?
        var initialAttachInProgress = true
        surfaceContext.onMaterialize = { [weak self] registry in
            guard let self else { return }
            do {
                try self.applyAttachSideEffects(
                    surfaceID: surfaceID,
                    rootView: rootView,
                    parentLayer: parentLayer,
                    insertionIndex: index,
                    registry: registry,
                    publisher: publisher,
                    environment: environment
                )
                self.clearPublicationFailure(surfaceID: surfaceID)
            } catch {
                if initialAttachInProgress {
                    thrownError = error
                } else {
                    self.recordPublicationFailure(
                        surfaceID: surfaceID,
                        error: error)
                }
            }
        }

        EmbedderApplication.withContexts(
            uiContext: rootView.embedderUIContext,
            visualContext: renderContext
        ) {
            consumer.registerContext(surfaceContext)
        }
        initialAttachInProgress = false

        if let error = thrownError {
            throw error
        }
        return registry
    }

    @MainActor
    private func applyAttachSideEffects(
        surfaceID: Int,
        rootView: View,
        parentLayer: Layer?,
        insertionIndex: UInt32,
        registry: ViewComponentViewRegistry,
        publisher: EmbeddedViewTreePublisher,
        environment: ReactSurfaceEnvironment
    ) throws {
        for component in registry.components where component.view !== rootView {
            component.updateEnvironment(environment)
        }

        _ = registry
        try publisher.publish(
            rootView: rootView,
            into: parentLayer,
            at: insertionIndex
        )
        attachedSurfaceIDs.insert(surfaceID)
    }
}
