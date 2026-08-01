package import NucleusUI

/// Fabric image projection onto the same retained request/cache lifecycle used
/// by native `ImageView`.
@MainActor
package final class ReactImageComponentView: ReactComponentView {
    package let tag: Int
    package let componentName: String
    package private(set) var nativeID: String
    package let view: View
    private let imageView: ImageView
    private var environment: ReactSurfaceEnvironment
    private var currentSource: String?

    init(
        tag: Int,
        componentName: String,
        nativeID: String,
        imageView: ImageView
    ) {
        self.tag = tag
        self.componentName = componentName
        self.nativeID = nativeID
        self.view = imageView
        self.imageView = imageView
        self.environment = ReactSurfaceEnvironment()
    }

    package func apply(_ snapshot: MountComponentSnapshot) {
        guard
            case .image(
                let viewSnapshot,
                let nextSource) = snapshot
        else { return }
        nativeID = viewSnapshot.nativeID
        view.frame = viewSnapshot.frame
        imageView.requestBackingScaleFactor =
            environment.backingScaleFactor
        if nextSource != currentSource {
            currentSource = nextSource
            imageView.source =
                nextSource
                .flatMap(Self.localFilePath(from:))
                .map(ImageRequestSource.resource)
        }
        imageView.layoutIfNeeded()
    }

    package func updateEnvironment(
        _ environment: ReactSurfaceEnvironment
    ) {
        self.environment = environment
        imageView.requestBackingScaleFactor =
            environment.backingScaleFactor
        imageView.layoutIfNeeded()
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
}
