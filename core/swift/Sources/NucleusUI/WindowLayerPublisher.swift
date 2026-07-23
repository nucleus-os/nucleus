package import NucleusLayers

@MainActor
package final class WindowLayerPublisher: ~Sendable {
    private let viewPublisher: ViewLayerPublisher

    package let context: Context

    package init(context: Context) {
        self.context = context
        self.viewPublisher = ViewLayerPublisher(context: context)
    }

    package func ensureRootAttached() throws(UIError) -> Layer {
        try viewPublisher.ensureRootAttached()
    }

    package func publish(
        windows: [Window]
    ) throws(UIError) -> [PublishedVisualContent] {
        try publish(windows: windows) { _ in true }
    }

    package func publish(
        windows: [Window],
        includes windowIncluded: @MainActor (Window) -> Bool
    ) throws(UIError) -> [PublishedVisualContent] {
        let roots = windows.compactMap { window -> ViewLayerRootPublication? in
            guard windowIncluded(window), window.isVisible else {
                return nil
            }
            guard let root = window.root else { return nil }
            return ViewLayerRootPublication(
                view: root,
                placement: ViewLayerRootPlacement(
                    id: window.id,
                    frame: window.frame
                )
            )
        }
        return try viewPublisher.publish(roots: roots)
    }

    package func placementLayer(for window: Window) -> Layer? {
        viewPublisher.placementLayer(for: window)
    }

    package func invalidate() throws(UIError) {
        try viewPublisher.invalidate()
    }

    package var publishedVisualLayerCount: Int {
        viewPublisher.publishedVisualLayerCount
    }

    package var retainedPaintRegistrationCount: Int {
        viewPublisher.retainedPaintRegistrationCount
    }
}
