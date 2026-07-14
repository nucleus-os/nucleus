import NucleusLayers

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
        let roots = windows.compactMap { window -> View? in
            guard windowIncluded(window), window.isVisible else {
                return nil
            }
            return window.root
        }
        return try viewPublisher.publish(roots: roots)
    }
}
