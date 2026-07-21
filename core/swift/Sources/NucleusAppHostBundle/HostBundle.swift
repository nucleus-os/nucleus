import NucleusLayers
import NucleusAppHostProtocols
import NucleusRenderModel

/// One host runtime's concrete Swift resource and runtime-protocol graph. The
/// compositor, shell, Android host, or fixture owns this value and passes its
/// `layersHost` to every context it creates. Nothing is installed process-wide.
@MainActor
public final class NucleusAppHostBundle: ~Sendable {
    public let resourceHost: SwiftResourceHost
    public let imageRegistrar: any ImageRegistrar
    public let imageLifecycle: any ImageLifecycle
    public let displayLinkSource: any DisplayLinkSource
    public let paintContentRegistrar: any PaintContentRegistrar
    public let runtimeEffectRegistrar: any RuntimeEffectRegistrar
    public let paintContentLifecycle: any PaintContentLifecycle
    public let runtimeEffectLifecycle: any RuntimeEffectLifecycle
    public let snapshotLifecycle: any SnapshotLifecycle
    public let iosurfaceBinder: any IOSurfaceBinder
    public let iosurfaceLifecycle: any IOSurfaceLifecycle
    public let contextIDAllocator: any ContextIDAllocator
    public let implicitActionRegistrar: any ImplicitActionRegistrar
    public let layersHost: LayerRuntimeHost

    public init(resourceHost: SwiftResourceHost) {
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
    public func invalidate() {
        layersHost.presentationCompletions.invalidate()
        resourceHost.invalidate()
    }
}
