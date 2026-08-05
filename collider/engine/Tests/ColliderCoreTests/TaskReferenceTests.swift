import ColliderCore
import ColliderEngine
import Foundation
import SystemPackage
import Testing

@testable import ColliderRuntime

private enum FixtureResult: TaskResultValue {}

private func inertActionFileSystem() -> ActionFileSystem {
    ActionFileSystem(
        metadata: { _ in nil },
        contentsEqual: { _, _ in true },
        createDirectory: { _ in },
        copy: { _, _ in },
        readPrefix: { _, count in Array(repeating: 0, count: count) },
        readSymbolicLink: { _ in "target" },
        move: { _, _ in },
        replaceSymlink: { _, _ in },
        setPermissions: { _, _ in },
        write: { _, _ in })
}

@Test func actionIdentityEncoderRejectsZeroAndDuplicateTags() {
    var zero = ActionIdentityEncoder()
    zero.append(tag: 0, string: "invalid")
    #expect(throws: ActionIdentityEncodingFailure.self) {
        try zero.encodedBytes()
    }

    var duplicate = ActionIdentityEncoder()
    duplicate.append(tag: 1, string: "first")
    duplicate.append(tag: 1, string: "second")
    #expect(throws: ActionIdentityEncodingFailure.self) {
        try duplicate.encodedBytes()
    }
}

@Test func actionIdentityEncodingIsCanonicalAndTypeSensitive() throws {
    var forward = ActionIdentityEncoder()
    forward.append(tag: 1, string: "one")
    forward.append(tag: 2, integer: 2)
    var reverse = ActionIdentityEncoder()
    reverse.append(tag: 2, integer: 2)
    reverse.append(tag: 1, string: "one")
    var differentType = ActionIdentityEncoder()
    differentType.append(tag: 1, bytes: Array("one".utf8))
    differentType.append(tag: 2, integer: 2)

    #expect(try forward.encodedBytes() == reverse.encodedBytes())
    #expect(try forward.encodedBytes() != differentType.encodedBytes())
}

@Test func ociExecutionPipelineRejectsANonzeroCommandStatus() async throws {
    let execution = OCIExecution(
        executionPlatform: .linuxARM64OCI,
        artifactTarget: .linuxARM64,
        imageID: FilePath("/fixture/image-id"),
        hostname: "fixture",
        workingDirectory: "/workspace",
        hostWorkingDirectory: FilePath("/fixture"),
        mounts: [],
        networkPolicy: .externalDisabled,
        userPolicy: .builder,
        capabilityPolicy: .dropAll,
        privilegePolicy: .prohibitAcquisition,
        processFilesystemPolicy: .standard,
        resourceLimits: .parallelBuild,
        containerEnvironment: [:],
        command: ["false"],
        environment: [:],
        output: .captured(limit: 1_024))
    let pipeline = try OCIExecutionPipeline([execution])
    let context = ActionContext(
        files: inertActionFileSystem(),
        cancellation: ActionCancellation(check: {}),
        logger: ActionLogger(log: { _ in }),
        commands: ActionCommandExecutor(execute: { _ in CommandResult(status: 0) }),
        downloads: ActionDownloader(download: { _, _ in }),
        containers: ActionContainerExecutor(
            run: { _ in CommandResult(status: 7) }))

    await #expect(throws: OCIExecutionPipelineFailure.self) {
        try await pipeline.execute(in: context)
    }
}

@Test func actionFileSystemRejectsUndeclaredAndEscapingEffects() throws {
    let files = inertActionFileSystem().scoped(to: [
        ActionEffect(.read, scope: .input(FilePath("/inputs"))),
        ActionEffect(.write, scope: .output(FilePath("/outputs"))),
    ])

    _ = try files.metadata(for: FilePath("/inputs/source"))
    _ = try files.readPrefix(FilePath("/inputs/source"), count: 4)
    _ = try files.readSymbolicLink(FilePath("/inputs/source"))
    try files.write([], to: FilePath("/outputs/result"))

    #expect(throws: ActionFileSystemFailure.self) {
        try files.write([], to: FilePath("/inputs/source"))
    }
    #expect(throws: ActionFileSystemFailure.self) {
        _ = try files.metadata(for: FilePath("/outputs/result"))
    }
    #expect(throws: ActionFileSystemFailure.self) {
        _ = try files.readPrefix(FilePath("/outputs/result"), count: 4)
    }
    #expect(throws: ActionFileSystemFailure.self) {
        _ = try files.readSymbolicLink(FilePath("/outputs/result"))
    }
    #expect(throws: ActionFileSystemFailure.self) {
        _ = try files.readPrefix(FilePath("/inputs/source"), count: -1)
    }
    #expect(throws: ActionFileSystemFailure.self) {
        try files.write([], to: FilePath("/outputs/../outside"))
    }
    #expect(throws: ActionFileSystemFailure.self) {
        _ = try files.metadata(for: FilePath("relative-input"))
    }
}

@Test func actionFileSystemChecksBothSidesOfCopiesAndMoves() throws {
    let files = inertActionFileSystem().scoped(to: [
        ActionEffect(.read, scope: .input(FilePath("/inputs"))),
        ActionEffect(.readWrite, scope: .scratch(FilePath("/scratch"))),
        ActionEffect(.write, scope: .output(FilePath("/outputs"))),
    ])

    try files.copy(
        from: FilePath("/inputs/source"),
        to: FilePath("/outputs/result"))
    try files.move(
        from: FilePath("/scratch/candidate"),
        to: FilePath("/outputs/result"))
    try files.replaceSymlink(
        at: FilePath("/outputs/current"),
        target: "generation")

    #expect(throws: ActionFileSystemFailure.self) {
        try files.copy(
            from: FilePath("/undeclared/source"),
            to: FilePath("/outputs/result"))
    }
    #expect(throws: ActionFileSystemFailure.self) {
        try files.move(
            from: FilePath("/inputs/source"),
            to: FilePath("/outputs/result"))
    }
    #expect(throws: ActionFileSystemFailure.self) {
        try files.replaceSymlink(
            at: FilePath("/inputs/current"),
            target: "generation")
    }
}

@Test func taskBuilderCreatesOpaqueTypedArtifactAndResultEdges() throws {
    let producerID = TaskID(rawValue: "fixture.producer")
    var producer = TaskBuilder(
        id: producerID,
        component: ComponentID(rawValue: "fixture"))
    let artifact: ArtifactReference<JSONArtifact> = try producer.output(
        "report",
        path: FilePath("/tmp/fixture/report.json"),
        validation: .json)
    let result: TaskResultReference<FixtureResult> = try producer.result("result")
    let producerTask = producer.build(
        action: try fixtureWriteAction(
            artifact.path,
            bytes: Array("{}".utf8)))

    var consumer = TaskBuilder(
        id: TaskID(rawValue: "fixture.consumer"),
        component: ComponentID(rawValue: "fixture"))
    consumer.consume(artifact)
    consumer.consume(result)
    let consumerTask = consumer.build(
        action: try fixtureCreateDirectoryAction(FilePath("/tmp/fixture/consumer")))

    let graph = try TaskGraph([producerTask, consumerTask])
    #expect(
        try graph.orderedTasks(selecting: [consumerTask.id]).map(\.id)
            == [producerID, consumerTask.id])
    #expect(consumerTask.dependencies == [producerID])
}

@Test func taskGraphRejectsAReferenceToAnUndeclaredProducerSlot() throws {
    var declaredProducer = TaskBuilder(
        id: TaskID(rawValue: "fixture.producer"),
        component: ComponentID(rawValue: "fixture"))
    let reference: ArtifactReference<FileArtifact> = try declaredProducer.output(
        "artifact",
        path: FilePath("/tmp/fixture/artifact"),
        validation: .regularFile)

    let replacementProducer = TaskDeclaration(
        id: declaredProducer.id,
        component: ComponentID(rawValue: "fixture"),
        action: try fixtureCreateDirectoryAction(FilePath("/tmp/fixture/replacement")))
    var consumer = TaskBuilder(
        id: TaskID(rawValue: "fixture.consumer"),
        component: ComponentID(rawValue: "fixture"))
    consumer.consume(reference)
    let consumerTask = consumer.build(
        action: try fixtureCreateDirectoryAction(FilePath("/tmp/fixture/consumer")))

    #expect(throws: TaskGraphFailure.self) {
        _ = try TaskGraph([replacementProducer, consumerTask])
    }
}

@Test func taskBuilderRejectsOutputTypeMismatch() {
    var builder = TaskBuilder(
        id: TaskID(rawValue: "fixture.producer"),
        component: ComponentID(rawValue: "fixture"))
    #expect(throws: TaskBuilderFailure.self) {
        let _: ArtifactReference<FileArtifact> = try builder.output(
            "directory",
            path: FilePath("/tmp/fixture/directory"),
            validation: .nonEmptyDirectory)
    }
}

@Test func orderingAndAssessmentPolicyDoNotAffectIdentity() async throws {
    let root = FilePath(
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "collider-reference-identity-\(UUID().uuidString)"
        ).path)
    defer { try? FileManager.default.removeItem(atPath: root.string) }
    let component = ComponentID(rawValue: "fixture")
    let anchorID = TaskID(rawValue: "fixture.anchor")
    let consumerID = TaskID(rawValue: "fixture.consumer")
    let anchor = TaskDeclaration(
        id: anchorID,
        component: component,
        action: try fixtureCreateDirectoryAction(root.appending("anchor")))

    func consumer(
        after ordering: TaskOrderingReference?,
        policy: TaskAssessmentPolicy
    ) throws -> TaskDeclaration {
        var builder = TaskBuilder(id: consumerID, component: component)
        if let ordering { builder.after(ordering) }
        let _: ArtifactReference<PathArtifact> = try builder.output(
            "directory",
            path: root.appending("consumer"),
            validation: .exists)
        return builder.build(
            assessmentPolicy: policy,
            action: try fixtureCreateDirectoryAction(root.appending("consumer")))
    }

    func identity(
        _ task: TaskDeclaration,
        includingAnchor: Bool
    ) async throws -> ArtifactDigest {
        let tasks = includingAnchor ? [anchor, task] : [task]
        let report = try await ColliderEngine(runtime: ColliderRuntime()).execute(
            graph: TaskGraph(tasks),
            selected: [consumerID],
            stateRoot: root.appending(UUID().uuidString),
            options: TaskExecutionOptions(dryRun: true))
        return try #require(report.plan.first(where: { $0.task == consumerID }))
            .identity
    }

    let incremental = try await identity(
        consumer(after: nil, policy: .incremental),
        includingAnchor: false)
    let portable = try await identity(
        consumer(after: nil, policy: .portable),
        includingAnchor: false)
    let ordered = try await identity(
        consumer(
            after: TaskBuilder(id: anchorID, component: component).ordering,
            policy: .incremental),
        includingAnchor: true)

    #expect(incremental == portable)
    #expect(incremental == ordered)
}
