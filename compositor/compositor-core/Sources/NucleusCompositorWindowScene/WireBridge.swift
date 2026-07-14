@_spi(NucleusCompositor) import NucleusLayers
import NucleusRenderHost

/// The layers commit sink every authored context is created with: a
/// `RenderCommitSink` bound to the process-global `RetainedTreeStore.shared`.
/// Transactions fold directly into the Swift retained tree — the former render path
/// and its ABI-bridging `HostCommitSink` are gone (10b.9). GPU-independent: the
/// shared store exists whether or not a GPU renderer is up, so this is the single
/// authoritative sink in every environment.
@MainActor
func resolveCommitSink() -> any CommitSink {
    RenderCommitSink()
}

/// The live window-scene author. The non-throwing resolver is assignable to the
/// typed-throws `CommitSinkFactory`.
@MainActor
package let windowSceneAuthor = WindowSceneAuthor(commitSinkFactory: { resolveCommitSink() })

/// The live window-scene author, for the in-process Swift callers that drive scene
/// authoring directly — chiefly the `SceneFeeder`, which reads the authoritative
/// Swift window model and calls the author Swift→Swift with typed IDs.
@MainActor
public func currentWindowSceneAuthor() -> WindowSceneAuthor { windowSceneAuthor }
