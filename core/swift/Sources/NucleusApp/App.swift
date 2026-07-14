// The `App` half of the entry vocabulary. A `struct` conforming to `App`, marked `@main`,
// is the app's entry point; its `body` is a `Scene`. This is the SwiftUI shape an iOS/
// macOS developer already knows, sitting on top of the imperative `Application` / `Window`
// / `View` surface, which stays as the layer it builds on.
//
// `Application.withContext` is the one first-party privileged seam used here (pushing the
// host's rendering context while the scene tree materializes), reached through the
// `@_spi(NucleusCompositor)` group — the SPI is used internally and never re-exported.

import NucleusUI

/// The entry point for a Nucleus app. Conform a `struct`, describe your windows in `body`,
/// and mark it `@main`:
///
///     @main
///     struct MyApp: App {
///         var body: some Scene {
///             WindowGroup { RootView() }
///         }
///     }
///
/// `@main` calls `main()`, which builds `body` into the installed `PlatformAppHost`'s
/// rendering context and hands off to the backend's frame loop. `NucleusApp` never spins a
/// loop of its own — see `PlatformAppHost`.
@MainActor
public protocol App {
    associatedtype Body: Scene
    init()
    @SceneBuilder var body: Body { get }
}

extension App {
    /// The `@main` entry: construct the app, materialize its scenes into the platform
    /// host, and hand off. Does not return until the host's `run()` does (which, for a
    /// host whose loop runs elsewhere, is immediately).
    @MainActor
    public static func main() {
        NucleusAppRuntime.launch(Self.self)
    }
}
