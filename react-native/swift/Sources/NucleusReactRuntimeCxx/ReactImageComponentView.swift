@_spi(NucleusCompositor) import NucleusUI
@_spi(NucleusCompositor) import NucleusLayers
import NucleusAppHostProtocols

private final class RegisteredImageLease: Sendable {
    let handle: UInt64
    let resourceHostHandle: UInt64

    init(handle: UInt64, resourceHostHandle: UInt64) {
        self.handle = handle
        self.resourceHostHandle = resourceHostHandle
    }

    deinit {
        currentLifecycleHost()?.imageLifecycle.release(
            resourceHostHandle: resourceHostHandle,
            handle: handle
        )
    }
}

@MainActor
public final class ReactImageComponentView: ReactComponentView {
    public let tag: Int
    public let componentName: String
    public private(set) var nativeID: String
    public let view: View
    private let imageView: ImageView
    private var environment: ReactSurfaceEnvironment
    private var currentSource: String?
    private var currentLease: RegisteredImageLease?

    init(tag: Int, componentName: String, nativeID: String, imageView: ImageView) {
        self.tag = tag
        self.componentName = componentName
        self.nativeID = nativeID
        self.view = imageView
        self.imageView = imageView
        self.environment = ReactSurfaceEnvironment()
    }

    public func apply(_ event: MountEvent) {
        nativeID = event.nativeID
        view.frame = event.frame
        let nextSource = event.imageSource
        guard nextSource != currentSource else { return }
        currentLease = nil
        currentSource = nextSource
        guard let path = nextSource.flatMap(Self.localFilePath(from:)) else {
            imageView.image = nil
            return
        }
        let frame = event.frame
        let maxWidth = Self.pixelDimension(frame.size.width)
        let maxHeight = Self.pixelDimension(frame.size.height)
        let resourceHostHandle = view.backingLayer.context.commitSink.resourceHostHandle
        if let handle = Self.registerImage(
            path: path,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            resourceHostHandle: resourceHostHandle
        ) {
            currentLease = RegisteredImageLease(
                handle: handle,
                resourceHostHandle: resourceHostHandle
            )
            imageView.image = ImageHandle(id: handle)
            if maxWidth > 0, maxHeight > 0 {
                imageView.imageSize = Size(
                    width: Double(maxWidth),
                    height: Double(maxHeight)
                )
            }
        } else {
            imageView.image = nil
        }
    }

    public func updateEnvironment(_ environment: ReactSurfaceEnvironment) {
        self.environment = environment
    }

    public func commitDisplayContentIfNeeded() throws {
        try ReactLayerContentCommitter.commitDisplayContentIfNeeded(for: view)
    }

    private static func pixelDimension(_ value: Double) -> UInt32 {
        guard value.isFinite, value > 0 else { return 0 }
        return UInt32(Swift.min(value.rounded(.up), Double(UInt32.max)))
    }

    private static func localFilePath(from source: String) -> String? {
        if source.hasPrefix("file://") {
            return String(source.dropFirst("file://".count))
        }
        if source.hasPrefix("/") {
            return source
        }
        return nil
    }

    @MainActor
    private static func registerImage(
        path: String,
        maxWidth: UInt32,
        maxHeight: UInt32,
        resourceHostHandle: UInt64
    ) -> UInt64? {
        guard resourceHostHandle != 0 else { return nil }
        guard let registrar = currentHost()?.imageRegistrar else { return nil }
        do {
            let handle = try registrar.register(
                path: path,
                maxWidth: maxWidth,
                maxHeight: maxHeight
            )
            return handle != 0 ? handle : nil
        } catch {
            return nil
        }
    }
}
