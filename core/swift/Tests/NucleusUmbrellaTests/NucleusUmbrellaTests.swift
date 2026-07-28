import Nucleus
import Testing

@MainActor
private struct PortableUmbrellaFixtureApp: App {
    var body: some Scene {
        EmptyScene()
    }
}

@MainActor
@Test func portableUmbrellaHasOneUnambiguousApplicationVocabulary() {
    _ = PortableUmbrellaFixtureApp().body
    let frame = Rect(x: 2, y: 3, width: 5, height: 7)
    let color = Color(0.1, 0.2, 0.3, 1)

    #expect(frame.origin == Point(x: 2, y: 3))
    #expect(frame.size == Size(width: 5, height: 7))
    #expect(color.a == 1)
}
