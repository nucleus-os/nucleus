import ColliderCore
import ColliderPlanning
import SystemPackage
import Testing

private let catalogCoreID = ComponentID(rawValue: "core")
private let catalogBuildID = TaskID(rawValue: "core.build")

private func catalogRequest(
    _ spelling: String,
    _ entrypoint: ComponentEntrypointID = .build
) -> ComponentEntrypointRequest {
    ComponentEntrypointRequest(spelling: spelling, entrypoint: entrypoint)
}

private func catalogTask(
    _ id: TaskID = catalogBuildID,
    component: ComponentID = catalogCoreID,
    dependencies: [TaskID] = [],
    inputs: [ArtifactInput] = [],
    output: FilePath? = nil,
    additionalOutputs: [FilePath] = [],
    action: AnyColliderAction? = nil
) -> TaskDeclaration {
    TaskDeclaration(
        id: id,
        component: component,
        dependencies: dependencies,
        inputs: inputs,
        outputs: ((output.map { [$0] } ?? []) + additionalOutputs).map {
            OutputDeclaration(path: $0, validation: .regularFile)
        },
        action: action)
}

private func catalogComponent(
    id: ComponentID = catalogCoreID,
    name: String = "core",
    directory: String = "core",
    aliases: Set<String> = [],
    tasks: [TaskDeclaration] = [catalogTask()],
    entrypoints: [ComponentEntrypoint]? = nil
) throws -> ComponentDefinition {
    try ComponentDefinition(
        descriptor: ComponentDescriptor(
            id: id,
            canonicalName: name,
            directoryName: directory,
            aliases: aliases),
        tasks: tasks,
        entrypoints: entrypoints ?? [
            ComponentEntrypoint(id: .build, roots: Set(tasks.map(\.id)))
        ])
}

@Test func plannerIndexesCatalogAliasesGroupsAndRoutes() throws {
    let core = try catalogComponent(aliases: ["render-core"])
    let catalog = ComponentCatalog(
        components: [core],
        groups: [ComponentSelectionGroup(name: "all", components: [catalogCoreID])],
        routes: [
            ComponentEntrypointRoute(
                spelling: "everything",
                requestedEntrypoint: .build,
                destinations: [
                    ComponentEntrypointReference(
                        component: catalogCoreID,
                        entrypoint: .build)
                ])
        ],
        publicEntrypoints: [
            catalogRequest("all"), catalogRequest("core"),
            catalogRequest("render-core"), catalogRequest("everything"),
        ])
    let planner = ColliderPlanner()

    for spelling in ["all", "core", "render-core", "everything"] {
        #expect(
            try planner.selectedTasks(
                in: catalog,
                requests: [catalogRequest(spelling)]) == [catalogBuildID])
    }
    #expect(throws: ComponentCatalogFailure.self) {
        _ = try planner.selectedTasks(
            in: catalog,
            requests: [catalogRequest("everything", .testDefault)])
    }
}

@Test func plannerRejectsInvalidCatalogIndexDeclarations() throws {
    let core = try catalogComponent(aliases: ["runtime"])
    let duplicateSpelling = ComponentCatalog(
        components: [core],
        groups: [ComponentSelectionGroup(name: "runtime", components: [catalogCoreID])],
        publicEntrypoints: [catalogRequest("core")])
    #expect(throws: ComponentCatalogFailure.self) {
        _ = try ColliderPlanner().selectedTasks(
            in: duplicateSpelling,
            requests: [catalogRequest("core")])
    }

    let unreachable = ComponentCatalog(
        components: [try catalogComponent()],
        publicEntrypoints: [])
    #expect(throws: ComponentCatalogFailure.self) {
        _ = try ColliderPlanner().selectedTasks(in: unreachable, requests: [])
    }
}

@Test func plannerValidatesCompleteCatalogOutputOwnership() throws {
    let producerID = ComponentID(rawValue: "producer")
    let producerTaskID = TaskID(rawValue: "producer.build")
    let producer = try catalogComponent(
        id: producerID,
        name: "producer",
        directory: "producer",
        tasks: [
            catalogTask(
                producerTaskID,
                component: producerID,
                output: FilePath("/outputs/generated"))
        ])
    let rawConsumer = try catalogComponent(
        tasks: [
            catalogTask(
                dependencies: [producerTaskID],
                inputs: [.file(FilePath("/outputs/generated/value.json"))])
        ])
    let rawCatalog = ComponentCatalog(
        components: [producer, rawConsumer],
        publicEntrypoints: [catalogRequest("producer"), catalogRequest("core")])
    #expect(throws: ColliderPlanningFailure.self) {
        _ = try plan(rawCatalog, request: catalogRequest("core"))
    }

    let overlapping = try catalogComponent(
        tasks: [
            catalogTask(output: FilePath("/outputs/generated/child"))
        ])
    let overlapCatalog = ComponentCatalog(
        components: [producer, overlapping],
        publicEntrypoints: [catalogRequest("producer"), catalogRequest("core")])
    #expect(throws: ColliderPlanningFailure.self) {
        _ = try plan(overlapCatalog, request: catalogRequest("core"))
    }
}

@Test func plannerOutputOwnershipUsesPathComponentsAndAllowsOneOwner() throws {
    let owner = catalogTask(
        output: FilePath("/outputs/generated"),
        additionalOutputs: [
            FilePath("/outputs/generated/child"),
            FilePath("/outputs/generated/deeper/value"),
        ])
    let siblingID = TaskID(rawValue: "core.sibling")
    let sibling = catalogTask(
        siblingID,
        output: FilePath("/outputs/generated-other"))
    let relativeID = TaskID(rawValue: "core.relative")
    let relative = catalogTask(
        relativeID,
        output: FilePath("outputs/generated"))
    let catalog = ComponentCatalog(
        components: [
            try catalogComponent(tasks: [owner, sibling, relative])
        ],
        publicEntrypoints: [catalogRequest("core")])

    _ = try plan(catalog, request: catalogRequest("core"))
}

@Test func plannerFindsAnEarlierDescendantWhenItsAncestorIsDeclaredLater() throws {
    let descendantID = TaskID(rawValue: "core.a-descendant")
    let descendant = catalogTask(
        descendantID,
        output: FilePath("/outputs/generated/child"))
    let ancestorID = TaskID(rawValue: "core.z-ancestor")
    let ancestor = catalogTask(
        ancestorID,
        output: FilePath("/outputs/generated"))
    let catalog = ComponentCatalog(
        components: [try catalogComponent(tasks: [descendant, ancestor])],
        publicEntrypoints: [catalogRequest("core")])

    do {
        _ = try plan(catalog, request: catalogRequest("core"))
        Issue.record("expected overlapping output ownership")
    } catch let failure as ColliderPlanningFailure {
        guard case .overlappingOutput(let first, let second, let path) = failure else {
            Issue.record("unexpected planning failure: \(failure)")
            return
        }
        #expect(first == descendantID)
        #expect(second == ancestorID)
        #expect(path == FilePath("/outputs/generated"))
    }
}

@Test func plannerAllowsATaskToReadWithinItsOwnOutput() throws {
    let task = catalogTask(
        inputs: [
            .file(FilePath("/outputs/generated/value.json")),
            .file(FilePath("/outputs/generated-other/value.json")),
        ],
        output: FilePath("/outputs/generated"))
    let catalog = ComponentCatalog(
        components: [try catalogComponent(tasks: [task])],
        publicEntrypoints: [catalogRequest("core")])

    _ = try plan(catalog, request: catalogRequest("core"))
}

private func plan(
    _ catalog: ComponentCatalog,
    request: ComponentEntrypointRequest
) throws -> ExecutionPlan {
    let digest = ArtifactDigest(bytes: Array(repeating: 19, count: 32))
    return try ColliderPlanner().plan(
        catalog: catalog,
        requests: [request],
        rebuildSelected: false,
        lowerings: [],
        services: TaskPlanningServices(
            digestBytes: { _ in digest },
            digestFile: { _ in digest },
            digestTree: { _ in digest },
            digestSourceCheckout: { _ in digest },
            optionalSourceCheckoutDigest: { _ in nil },
            semanticToolIdentity: { _, _ in
                ToolIdentitySnapshot(path: FilePath("/fixture/tool"), digest: digest)
            },
            taskState: { _ in .missing },
            validateOutputs: { _ in }))
}
