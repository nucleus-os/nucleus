import NucleusCompositorWaylandRuntime
import NucleusCompositorWindowScene
import NucleusLayers

@MainActor
func makeTestWaylandRouterRuntime() -> WaylandRouterRuntime? {
    let sink = InMemoryCommitSink()
    let author = WindowSceneAuthor(commitSinkFactory: { sink })
    return WaylandRouterRuntime(author: author)
}
