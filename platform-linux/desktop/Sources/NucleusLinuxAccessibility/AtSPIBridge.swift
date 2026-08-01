package import NucleusUI

/// Couples one retained scene's neutral semantic tree to a platform adapter.
///
/// Publishing is explicit and frame-aligned. Platform calls invoke actions
/// through the latest published tree, so an object removed in the same frame
/// cannot act on a stale view.
@MainActor
package final class AtSPIBridge {
    private let tree: AccessibilityTree
    private let applyUpdate:
        @MainActor (
            AccessibilityTreeSnapshot,
            AccessibilityTreeUpdate
        ) -> Void

    package init(
        scene: WindowScene,
        service: AtSPIService
    ) {
        tree = scene.accessibilityTree
        applyUpdate = { snapshot, update in
            service.apply(snapshot: snapshot, update: update)
        }
    }

    init(
        scene: WindowScene,
        applyUpdate:
            @escaping @MainActor (
                AccessibilityTreeSnapshot,
                AccessibilityTreeUpdate
            ) -> Void
    ) {
        tree = scene.accessibilityTree
        self.applyUpdate = applyUpdate
    }

    @discardableResult
    package func publish() -> AccessibilityTreeUpdate {
        let update = tree.publish()
        applyUpdate(tree.snapshot, update)
        return update
    }

    @discardableResult
    package func perform(_ request: AccessibilityActionRequest) -> Bool {
        tree.perform(request)
    }
}
