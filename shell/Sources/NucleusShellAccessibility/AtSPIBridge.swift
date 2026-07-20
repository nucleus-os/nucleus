import NucleusUI

@MainActor
public protocol AccessibilityPlatformAdapter: AnyObject {
    func apply(
        snapshot: AccessibilityTreeSnapshot,
        update: AccessibilityTreeUpdate)
}

/// Couples one retained scene's neutral semantic tree to a platform adapter.
///
/// Publishing is explicit and frame-aligned. Platform calls invoke actions
/// through the latest published tree, so an object removed in the same frame
/// cannot act on a stale view.
@MainActor
public final class AtSPIBridge {
    private let tree: AccessibilityTree
    private let adapter: any AccessibilityPlatformAdapter

    public init(
        scene: WindowScene,
        adapter: any AccessibilityPlatformAdapter
    ) {
        tree = scene.accessibilityTree
        self.adapter = adapter
    }

    @discardableResult
    public func publish() -> AccessibilityTreeUpdate {
        let update = tree.publish()
        adapter.apply(snapshot: tree.snapshot, update: update)
        return update
    }

    @discardableResult
    public func perform(_ request: AccessibilityActionRequest) -> Bool {
        tree.perform(request)
    }
}

@MainActor
final class RecordingAtSPIAdapter: AccessibilityPlatformAdapter {
    private(set) var model: AtSPIExportModel
    private(set) var updates: [AtSPIExportUpdate] = []

    init(applicationName: String = "Nucleus") {
        model = AtSPIExportModel(applicationName: applicationName)
    }

    func apply(
        snapshot: AccessibilityTreeSnapshot,
        update: AccessibilityTreeUpdate
    ) {
        updates.append(model.apply(snapshot: snapshot, update: update))
    }
}
