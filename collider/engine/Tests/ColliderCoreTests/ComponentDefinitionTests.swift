import Testing

@testable import ColliderCore

private let coreID = ComponentID(rawValue: "core")
private let buildID = TaskID(rawValue: "core.build")

private func task(
    component: ComponentID = coreID
) -> TaskDeclaration {
    TaskDeclaration(id: buildID, component: component)
}

private func component(
    tasks: [TaskDeclaration] = [task()],
    entrypoints: [ComponentEntrypoint] = [
        ComponentEntrypoint(id: .build, roots: [buildID])
    ]
) throws -> ComponentDefinition {
    try ComponentDefinition(
        descriptor: ComponentDescriptor(
            id: coreID,
            canonicalName: "core",
            directoryName: "core"),
        tasks: tasks,
        entrypoints: entrypoints)
}

@Test func componentDefinitionRejectsForeignTasksAndUnknownRoots() throws {
    #expect(throws: ComponentDefinitionFailure.self) {
        _ = try component(
            tasks: [task(component: ComponentID(rawValue: "other"))])
    }
    #expect(throws: ComponentDefinitionFailure.self) {
        _ = try component(
            entrypoints: [
                ComponentEntrypoint(
                    id: .build,
                    roots: [TaskID(rawValue: "missing")])
            ])
    }
}
