import NucleusLayers
import NucleusAppHostProtocols

@MainActor
public struct NucleusAppHostBundle {
    public let imageRegistrar: any ImageRegistrar
    public let imageLifecycle: any ImageLifecycle
    public let displayLinkSource: any DisplayLinkSource
    public let paintContentRegistrar: any PaintContentRegistrar
    public let paintContentLifecycle: any PaintContentLifecycle
    public let snapshotLifecycle: any SnapshotLifecycle
    public let iosurfaceBinder: any IOSurfaceBinder
    public let iosurfaceLifecycle: any IOSurfaceLifecycle
    public let contextIDAllocator: any ContextIDAllocator
    public let implicitActionRegistrar: any ImplicitActionRegistrar

    public init(
        imageRegistrar: any ImageRegistrar,
        imageLifecycle: any ImageLifecycle,
        displayLinkSource: any DisplayLinkSource,
        paintContentRegistrar: any PaintContentRegistrar,
        paintContentLifecycle: any PaintContentLifecycle,
        snapshotLifecycle: any SnapshotLifecycle,
        iosurfaceBinder: any IOSurfaceBinder,
        iosurfaceLifecycle: any IOSurfaceLifecycle,
        contextIDAllocator: any ContextIDAllocator,
        implicitActionRegistrar: any ImplicitActionRegistrar
    ) {
        self.imageRegistrar = imageRegistrar
        self.imageLifecycle = imageLifecycle
        self.displayLinkSource = displayLinkSource
        self.paintContentRegistrar = paintContentRegistrar
        self.paintContentLifecycle = paintContentLifecycle
        self.snapshotLifecycle = snapshotLifecycle
        self.iosurfaceBinder = iosurfaceBinder
        self.iosurfaceLifecycle = iosurfaceLifecycle
        self.contextIDAllocator = contextIDAllocator
        self.implicitActionRegistrar = implicitActionRegistrar
    }

    public static func makeProduction(
        imageRegistrar: any ImageRegistrar,
        imageLifecycle: any ImageLifecycle,
        displayLinkSource: any DisplayLinkSource,
        paintContentRegistrar: any PaintContentRegistrar,
        paintContentLifecycle: any PaintContentLifecycle,
        snapshotLifecycle: any SnapshotLifecycle,
        iosurfaceBinder: any IOSurfaceBinder,
        iosurfaceLifecycle: any IOSurfaceLifecycle,
        contextIDAllocator: any ContextIDAllocator,
        implicitActionRegistrar: any ImplicitActionRegistrar
    ) -> NucleusAppHostBundle {
        return NucleusAppHostBundle(
            imageRegistrar: imageRegistrar,
            imageLifecycle: imageLifecycle,
            displayLinkSource: displayLinkSource,
            paintContentRegistrar: paintContentRegistrar,
            paintContentLifecycle: paintContentLifecycle,
            snapshotLifecycle: snapshotLifecycle,
            iosurfaceBinder: iosurfaceBinder,
            iosurfaceLifecycle: iosurfaceLifecycle,
            contextIDAllocator: contextIDAllocator,
            implicitActionRegistrar: implicitActionRegistrar
        )
    }
}

@MainActor
private var activeProductionHostBundle: NucleusAppHostBundle?

@MainActor
public func currentProductionHostBundle() -> NucleusAppHostBundle? {
    activeProductionHostBundle
}

/// Install the production host bundle. Every slot is a Swift-native conformer:
/// the resource-host slots (image / paint / snapshot / implicit-action) are backed
/// by `SwiftResourceHost.shared`; the runtime slots (display link, IOSurface
/// bind/lifecycle, context-id) are the `SwiftRuntimeHostConformers`.
@MainActor
public func nucleus_app_host_bundle_install_production() -> UInt8 {
    let bundle = NucleusAppHostBundle.makeProduction(
        imageRegistrar: SwiftImageRegistrar(),
        imageLifecycle: SwiftImageLifecycle(),
        displayLinkSource: SwiftDisplayLinkSource(),
        paintContentRegistrar: SwiftPaintContentRegistrar(),
        paintContentLifecycle: SwiftPaintContentLifecycle(),
        snapshotLifecycle: SwiftSnapshotLifecycle(),
        iosurfaceBinder: SwiftIOSurfaceBinder(),
        iosurfaceLifecycle: SwiftIOSurfaceLifecycle(),
        contextIDAllocator: SwiftContextIDAllocator(),
        implicitActionRegistrar: SwiftImplicitActionRegistrar()
    )
    activeProductionHostBundle = bundle
    installHost(Host(
        imageRegistrar: bundle.imageRegistrar,
        paintContentRegistrar: bundle.paintContentRegistrar,
        iosurfaceBinder: bundle.iosurfaceBinder,
        contextIDAllocator: bundle.contextIDAllocator,
        displayLinkSource: bundle.displayLinkSource,
        implicitActionRegistrar: bundle.implicitActionRegistrar
    ))
    registerImplicitActionSettings()
    installLifecycleHost(LifecycleHost(
        imageLifecycle: bundle.imageLifecycle,
        paintContentLifecycle: bundle.paintContentLifecycle,
        snapshotLifecycle: bundle.snapshotLifecycle,
        iosurfaceLifecycle: bundle.iosurfaceLifecycle,
        contextIDAllocator: bundle.contextIDAllocator
    ))
    return 1
}

@MainActor
public func nucleus_app_host_bundle_clear_production() {
    activeProductionHostBundle = nil
    clearHost()
    clearLifecycleHost()
}
