import Nucleus

@MainActor
public func makePortableViewHierarchy() -> View {
    let context = UIContext(services: .inMemory())
    return context.construct {
        let root = View()
        root.addSubview(View())
        return root
    }
}

public func runPortableApplicationBody() throws(UIError) {
    try Application.run {}
}
