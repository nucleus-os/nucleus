// The leaf scene: a group presenting one window over a root view. `WindowGroup { Root() }`
// is the declarative form of the imperative "make a `Window`, set its content view, put it
// in a `WindowScene`" — reusing `Window`, `WindowScene`, and `View` unchanged. The
// content closure is deferred so the root view is constructed inside the app's rendering
// context during materialization (its backing layers must be minted in that context).

import NucleusUI

/// A scene presenting a window whose content is `Content`. The trailing closure builds the
/// root view; an optional title names the window.
///
///     WindowGroup { RootView() }
///     WindowGroup("Inspector") { InspectorView() }
public struct WindowGroup<Content: View>: Scene, _PrimitiveScene {
    public typealias Body = Never

    let title: String
    let role: WindowRole
    let activationPolicy: SceneActivationPolicy
    let makeContent: @MainActor () throws -> Content

    public init(
        _ title: String = "",
        role: WindowRole = .application,
        activationPolicy: SceneActivationPolicy = .automatic,
        content: @escaping @MainActor () throws -> Content
    ) {
        self.title = title
        self.role = role
        self.activationPolicy = activationPolicy
        self.makeContent = content
    }

    func _materializePrimitive(using materializer: SceneMaterializer) throws {
        try materializer.present(
            title: title,
            role: role,
            activationPolicy: activationPolicy,
            makeContent: makeContent)
    }
}
