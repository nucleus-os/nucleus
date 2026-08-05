import ColliderCore
import ColliderPersistence
import ColliderPlanning
import Foundation
import Synchronization
import SystemPackage
import Testing

@Test func identicalDeclarationsAndSnapshotsProduceIdenticalPlanBytes() throws {
    let input = FilePath("/fixture/selected-input")
    let selected = TaskDeclaration(
        id: TaskID(rawValue: "fixture.selected"),
        component: ComponentID(rawValue: "fixture"),
        inputs: [.file(input)])
    let graph = try TaskGraph([selected])
    let digest = ArtifactDigest(bytes: Array(repeating: 11, count: 32))
    let services = deterministicServices(digest: digest)

    let first = try ColliderPlanner().plan(
        graph: graph,
        selected: [selected.id],
        rebuildSelected: false,
        lowerings: [],
        services: services)
    let second = try ColliderPlanner().plan(
        graph: graph,
        selected: [selected.id],
        rebuildSelected: false,
        lowerings: [],
        services: services)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    #expect(try encoder.encode(first.reportedEntries) == encoder.encode(second.reportedEntries))
}

@Test func planningDoesNotReadUnselectedInputsOrValidateUnselectedOutputs() throws {
    let selected = TaskDeclaration(
        id: TaskID(rawValue: "fixture.selected"),
        component: ComponentID(rawValue: "fixture"),
        inputs: [.file(FilePath("/fixture/selected"))])
    let unselected = TaskDeclaration(
        id: TaskID(rawValue: "fixture.unselected"),
        component: ComponentID(rawValue: "fixture"),
        inputs: [.tree(FilePath("/fixture/unselected"))])
    let fileReads = Mutex(0)
    let treeReads = Mutex(0)
    let validations = Mutex(0)
    let digest = ArtifactDigest(bytes: Array(repeating: 13, count: 32))
    let services = TaskPlanningServices(
        resourceCapacity: fixtureCapacity,
        digestBytes: { _ in digest },
        digestFile: { _ in
            fileReads.withLock { $0 += 1 }
            return digest
        },
        digestTree: { _ in
            treeReads.withLock { $0 += 1 }
            return digest
        },
        optionalTreeDigest: { _ in nil },
        semanticToolIdentity: { _, _ in
            ToolIdentitySnapshot(path: FilePath("/fixture/tool"), digest: digest)
        },
        taskState: { _ in .missing },
        validateOutputs: { _ in validations.withLock { $0 += 1 } })

    _ = try ColliderPlanner().plan(
        graph: TaskGraph([selected, unselected]),
        selected: [selected.id],
        rebuildSelected: false,
        lowerings: [],
        services: services)

    #expect(fileReads.withLock { $0 } == 1)
    #expect(treeReads.withLock { $0 } == 0)
    #expect(validations.withLock { $0 } == 0)
}

@Test func executionAndArtifactCoordinatesAffectTaskIdentity() throws {
    func identity(
        execution: ExecutionPlatform,
        artifact: ArtifactTarget
    ) throws -> ArtifactDigest {
        let action = try AnyColliderAction(
            PlacementIdentityAction(
                executionPlatform: execution,
                artifactTarget: artifact))
        let task = TaskDeclaration(
            id: TaskID(rawValue: "fixture.placement"),
            component: ComponentID(rawValue: "fixture"),
            action: action)
        let services = deterministicHashingServices()
        let plan = try ColliderPlanner().plan(
            graph: TaskGraph([task]),
            selected: [task.id],
            rebuildSelected: false,
            lowerings: [],
            services: services)
        return try #require(plan.declaredEntries.first).identity
    }

    let armExecution = try identity(
        execution: .linuxARM64OCI,
        artifact: .linuxX86_64)
    let amdExecution = try identity(
        execution: .linuxAMD64OCI,
        artifact: .linuxX86_64)
    let armArtifact = try identity(
        execution: .linuxARM64OCI,
        artifact: .linuxARM64)

    #expect(armExecution != amdExecution)
    #expect(armExecution != armArtifact)
}

private struct PlacementIdentityAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: "stable-action")
        }
    }

    static let kind: ActionKind = "fixture.placement"

    let executionPlatform: ExecutionPlatform
    let artifactTarget: ArtifactTarget

    var identity: Identity { Identity() }

    var requirements: ActionRequirements {
        ActionRequirements(
            executionPlatform: executionPlatform,
            artifactTarget: artifactTarget)
    }

    func execute(in _: ActionContext) async throws {}
}

private func deterministicServices(digest: ArtifactDigest) -> TaskPlanningServices {
    TaskPlanningServices(
        resourceCapacity: fixtureCapacity,
        digestBytes: { _ in digest },
        digestFile: { _ in digest },
        digestTree: { _ in digest },
        optionalTreeDigest: { _ in nil },
        semanticToolIdentity: { _, _ in
            ToolIdentitySnapshot(path: FilePath("/fixture/tool"), digest: digest)
        },
        taskState: { _ in .missing },
        validateOutputs: { _ in })
}

private func deterministicHashingServices() -> TaskPlanningServices {
    let digest = ArtifactDigest(bytes: Array(repeating: 17, count: 32))
    return TaskPlanningServices(
        resourceCapacity: fixtureCapacity,
        digestBytes: { ArtifactDigest.sha256(Data($0)) },
        digestFile: { _ in digest },
        digestTree: { _ in digest },
        optionalTreeDigest: { _ in nil },
        semanticToolIdentity: { _, _ in
            ToolIdentitySnapshot(path: FilePath("/fixture/tool"), digest: digest)
        },
        taskState: { _ in .missing },
        validateOutputs: { _ in })
}

private let fixtureCapacity = TaskResourceCapacity(
    cpuCount: 8,
    memoryBytes: 32 * 1_024 * 1_024 * 1_024)
