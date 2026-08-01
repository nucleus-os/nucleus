package import NucleusLayers
package import NucleusAppHostProtocols
package import NucleusRenderModel

/// One host runtime's concrete Swift resource and runtime-protocol graph. The
/// compositor, shell, Android host, or fixture owns this value and passes its
/// `layersHost` to every context it creates. Nothing is installed process-wide.
@MainActor
package final class NucleusAppHostBundle: ~Sendable {
    package let resourceHost: SwiftResourceHost
    package let imageRegistrar: any ImageRegistrar
    package let imageLifecycle: any ImageLifecycle
    package let displayLinkSource: any DisplayLinkSource
    package let paintContentRegistrar: any PaintContentRegistrar
    package let runtimeEffectRegistrar: any RuntimeEffectRegistrar
    package let paintContentLifecycle: any PaintContentLifecycle
    package let runtimeEffectLifecycle: any RuntimeEffectLifecycle
    package let snapshotLifecycle: any SnapshotLifecycle
    package let iosurfaceBinder: any IOSurfaceBinder
    package let iosurfaceLifecycle: any IOSurfaceLifecycle
    package let contextIDAllocator: any ContextIDAllocator
    package let implicitActionRegistrar: any ImplicitActionRegistrar
    package let layersHost: LayerRuntimeHost

    package init(resourceHost: SwiftResourceHost) {
        let imageRegistrar = SwiftImageRegistrar(resourceHost: resourceHost)
        let imageLifecycle = SwiftImageLifecycle(resourceHost: resourceHost)
        let displayLinkSource = SwiftDisplayLinkSource()
        let paintContentRegistrar = SwiftPaintContentRegistrar(
            resourceHost: resourceHost)
        let runtimeEffectRegistrar = SwiftRuntimeEffectRegistrar(
            resourceHost: resourceHost)
        let paintContentLifecycle = SwiftPaintContentLifecycle(
            resourceHost: resourceHost)
        let runtimeEffectLifecycle = SwiftRuntimeEffectLifecycle(
            resourceHost: resourceHost)
        let snapshotLifecycle = SwiftSnapshotLifecycle(
            resourceHost: resourceHost)
        let iosurfaceBinder = SwiftIOSurfaceBinder()
        let iosurfaceLifecycle = SwiftIOSurfaceLifecycle()
        let contextIDAllocator = SwiftContextIDAllocator()
        let implicitActionRegistrar = SwiftImplicitActionRegistrar(
            resourceHost: resourceHost)

        self.resourceHost = resourceHost
        self.imageRegistrar = imageRegistrar
        self.imageLifecycle = imageLifecycle
        self.displayLinkSource = displayLinkSource
        self.paintContentRegistrar = paintContentRegistrar
        self.runtimeEffectRegistrar = runtimeEffectRegistrar
        self.paintContentLifecycle = paintContentLifecycle
        self.runtimeEffectLifecycle = runtimeEffectLifecycle
        self.snapshotLifecycle = snapshotLifecycle
        self.iosurfaceBinder = iosurfaceBinder
        self.iosurfaceLifecycle = iosurfaceLifecycle
        self.contextIDAllocator = contextIDAllocator
        self.implicitActionRegistrar = implicitActionRegistrar
        self.layersHost = LayerRuntimeHost(
            operations: Host(
                imageRegistrar: imageRegistrar,
                paintContentRegistrar: paintContentRegistrar,
                runtimeEffectRegistrar: runtimeEffectRegistrar,
                iosurfaceBinder: iosurfaceBinder,
                contextIDAllocator: contextIDAllocator,
                displayLinkSource: displayLinkSource,
                implicitActionRegistrar: implicitActionRegistrar),
            lifecycle: LifecycleHost(
                imageLifecycle: imageLifecycle,
                paintContentLifecycle: paintContentLifecycle,
                runtimeEffectLifecycle: runtimeEffectLifecycle,
                snapshotLifecycle: snapshotLifecycle,
                iosurfaceLifecycle: iosurfaceLifecycle,
                contextIDAllocator: contextIDAllocator))

        registerImplicitActionSettings(
            Settings(), using: implicitActionRegistrar)
    }

    /// Invalidates the raw boundary identity before late callbacks can reach any
    /// store. Contexts and content leases retain their conformers long enough to
    /// reject those callbacks deterministically.
    package func invalidate() {
        layersHost.presentationCompletions.invalidate()
        resourceHost.invalidate()
    }
}
