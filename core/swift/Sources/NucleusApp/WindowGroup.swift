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
    let makeContent: @MainActor () throws -> Content

    public init(_ title: String = "", content: @escaping @MainActor () throws -> Content) {
        self.title = title
        self.makeContent = content
    }

    func _materializePrimitive(into host: any PlatformAppHost) throws {
        // Runs inside `Application.withContext(host.appContext())` (established by
        // `App.main()`), so the root view and window mint their layers in the host's
        // context — committed transactions flow to the host's renderer.
        let root = try makeContent()
        let window = Window(
            title: title,
            role: .application,
            level: .normal,
            styleMask: [.titled, .closable, .resizable])
        window.setContentView(root)
        host.present(WindowScene(windows: [window]))
    }
}
