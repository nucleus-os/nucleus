import SystemPackage
import Testing

@testable import ColliderCore

private let coreID = ComponentID(rawValue: "core")
private let buildID = TaskID(rawValue: "core.build")

private func request(
    _ spelling: String,
    _ entrypoint: ComponentEntrypointID = .build
) -> ComponentEntrypointRequest {
    ComponentEntrypointRequest(spelling: spelling, entrypoint: entrypoint)
}

private func task(
    _ id: TaskID = buildID,
    component: ComponentID = coreID,
    dependencies: [TaskID] = [],
    output: FilePath? = nil
) -> TaskDeclaration {
    TaskDeclaration(
        id: id,
        component: component,
        dependencies: dependencies,
        outputs: output.map {
            [OutputDeclaration(path: $0, validation: .regularFile)]
        } ?? [],
        operation: .sequence([]))
}

private func component(
    id: ComponentID = coreID,
    name: String = "core",
    directory: String = "core",
    aliases: Set<String> = [],
    tasks: [TaskDeclaration] = [task()],
    entrypoints: [ComponentEntrypoint] = [
        ComponentEntrypoint(id: .build, roots: [buildID])
    ]
) throws -> ComponentDefinition {
    try ComponentDefinition(
        descriptor: ComponentDescriptor(
            id: id,
            canonicalName: name,
            directoryName: directory,
            aliases: aliases),
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

@Test func componentCatalogResolvesCanonicalAliasesGroupsAndEntrypointAliases() throws {
    let core = try component(aliases: ["render-core"])
    let catalog = try ComponentCatalog(
        components: [core],
        groups: [ComponentSelectionGroup(name: "all", components: [coreID])],
        routes: [
            ComponentEntrypointRoute(
                spelling: "everything",
                requestedEntrypoint: .build,
                destinations: [
                    ComponentEntrypointReference(
                        component: coreID,
                        entrypoint: .build)
                ])
        ],
        publicEntrypoints: [
            request("all"), request("core"), request("render-core"),
            request("everything"),
        ])

    #expect(try catalog.roots(named: .build, selection: nil) == [buildID])
    #expect(try catalog.roots(named: .build, selection: "core") == [buildID])
    #expect(try catalog.roots(named: .build, selection: "render-core") == [buildID])
    #expect(try catalog.roots(named: .build, selection: "everything") == [buildID])
    #expect(throws: ComponentCatalogFailure.self) {
        _ = try catalog.roots(named: .testDefault, selection: "everything")
    }
}

@Test func componentCatalogRejectsDuplicateSpellingsAndUnknownGroupMembers() throws {
    let core = try component(aliases: ["runtime"])
    #expect(throws: ComponentCatalogFailure.self) {
        _ = try ComponentCatalog(
            components: [core],
            groups: [ComponentSelectionGroup(name: "runtime", components: [coreID])],
            publicEntrypoints: [request("core")])
    }
    #expect(throws: ComponentCatalogFailure.self) {
        _ = try ComponentCatalog(
            components: [core],
            groups: [
                ComponentSelectionGroup(
                    name: "all",
                    components: [ComponentID(rawValue: "missing")])
            ],
            publicEntrypoints: [request("core")])
    }
}

@Test func componentCatalogValidatesCrossComponentEdgesAndOutputOwnership() throws {
    let otherID = ComponentID(rawValue: "other")
    let otherBuildID = TaskID(rawValue: "other.build")
    let core = try component(
        tasks: [
            task(dependencies: [otherBuildID], output: FilePath("/outputs/core"))
        ])
    let other = try component(
        id: otherID,
        name: "other",
        directory: "other",
        tasks: [
            task(
                otherBuildID,
                component: otherID,
                output: FilePath("/outputs/other"))
        ],
        entrypoints: [
            ComponentEntrypoint(id: .build, roots: [otherBuildID])
        ])
    _ = try ComponentCatalog(
        components: [core, other],
        groups: [
            ComponentSelectionGroup(name: "all", components: [coreID, otherID])
        ],
        publicEntrypoints: [request("all")])

    let overlapping = try component(
        id: otherID,
        name: "overlapping",
        directory: "overlapping",
        tasks: [
            task(
                otherBuildID,
                component: otherID,
                output: FilePath("/outputs/core/child"))
        ],
        entrypoints: [
            ComponentEntrypoint(id: .build, roots: [otherBuildID])
        ])
    #expect(throws: ComponentCatalogFailure.self) {
        _ = try ComponentCatalog(
            components: [core, overlapping],
            publicEntrypoints: [request("core"), request("overlapping")])
    }
}

private struct EmptyActionIdentity: ColliderActionIdentity {
    func encode(into _: inout ActionIdentityEncoder) {}
}

private struct FirstAction: ColliderAction {
    static let kind: ActionKind = "core.colliding"
    let identity = EmptyActionIdentity()

    func execute(in _: ActionContext) async throws {}
}

private struct SecondAction: ColliderAction {
    static let kind: ActionKind = "core.colliding"
    let identity = EmptyActionIdentity()

    func execute(in _: ActionContext) async throws {}
}

private struct ForeignAction: ColliderAction {
    static let kind: ActionKind = "other.foreign"
    let identity = EmptyActionIdentity()

    func execute(in _: ActionContext) async throws {}
}

@Test func componentCatalogRejectsUnreachableEntrypointsAndRoutes() throws {
    let core = try component()
    #expect(throws: ComponentCatalogFailure.self) {
        _ = try ComponentCatalog(
            components: [core],
            publicEntrypoints: [])
    }
    #expect(throws: ComponentCatalogFailure.self) {
        _ = try ComponentCatalog(
            components: [core],
            routes: [
                ComponentEntrypointRoute(
                    spelling: "everything",
                    requestedEntrypoint: .build,
                    destinations: [
                        ComponentEntrypointReference(
                            component: coreID,
                            entrypoint: .build)
                    ])
            ],
            publicEntrypoints: [request("core")])
    }
}

@Test func componentCatalogRejectsActionKindCollisionsAndForeignNamespaces() throws {
    let first = try taskWithAction(FirstAction())
    let secondID = TaskID(rawValue: "core.second")
    let second = try taskWithAction(SecondAction(), id: secondID)
    #expect(throws: ComponentCatalogFailure.self) {
        _ = try ComponentCatalog(
            components: [
                try component(
                    tasks: [first, second],
                    entrypoints: [
                        ComponentEntrypoint(id: .build, roots: [buildID, secondID])
                    ])
            ],
            publicEntrypoints: [request("core")])
    }

    #expect(throws: ComponentCatalogFailure.self) {
        _ = try ComponentCatalog(
            components: [
                try component(tasks: [try taskWithAction(ForeignAction())])
            ],
            publicEntrypoints: [request("core")])
    }
}

private func taskWithAction<Action: ColliderAction>(
    _ action: Action,
    id: TaskID = buildID
) throws -> TaskDeclaration {
    TaskDeclaration(
        id: id,
        component: coreID,
        operation: .action(try AnyColliderAction(action)))
}
