import SystemPackage
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
    ],
    storage: [StorageDeclaration] = []
) throws -> ComponentDefinition {
    try ComponentDefinition(
        descriptor: ComponentDescriptor(
            id: coreID,
            canonicalName: "core",
            directoryName: "core"),
        tasks: tasks,
        entrypoints: entrypoints,
        storage: storage)
}

@Test func componentDefinitionRejectsForeignStorage() {
    #expect(throws: ComponentDefinitionFailure.self) {
        _ = try component(
            storage: [
                StorageDeclaration(
                    id: "fixture",
                    owner: ComponentID(rawValue: "other"),
                    producers: [.runtime("fixture")],
                    storageClass: .cache,
                    root: FilePath("/cache/core"),
                    safetyRoot: FilePath("/cache"),
                    cleanupPolicy: .protected,
                    retention: "fixture")
            ])
    }
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
