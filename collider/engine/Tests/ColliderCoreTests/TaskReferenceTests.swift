import ColliderCore
import Foundation
import SystemPackage
import Testing

@testable import ColliderRuntime

private enum FixtureResult: TaskResultValue {}

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
        operation: .writeFile(artifact.path, bytes: Array("{}".utf8)))

    var consumer = TaskBuilder(
        id: TaskID(rawValue: "fixture.consumer"),
        component: ComponentID(rawValue: "fixture"))
    consumer.consume(artifact)
    consumer.consume(result)
    let consumerTask = consumer.build(
        operation: .createDirectory(FilePath("/tmp/fixture/consumer")))

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
        operation: .createDirectory(FilePath("/tmp/fixture/replacement")))
    var consumer = TaskBuilder(
        id: TaskID(rawValue: "fixture.consumer"),
        component: ComponentID(rawValue: "fixture"))
    consumer.consume(reference)
    let consumerTask = consumer.build(
        operation: .createDirectory(FilePath("/tmp/fixture/consumer")))

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
        operation: .createDirectory(root.appending("anchor")))

    func consumer(
        after ordering: TaskOrderingReference?,
        policy: TaskAssessmentPolicy
    ) -> TaskDeclaration {
        var builder = TaskBuilder(id: consumerID, component: component)
        if let ordering { builder.after(ordering) }
        return builder.build(
            assessmentPolicy: policy,
            operation: .createDirectory(root.appending("consumer")))
    }

    func identity(
        _ task: TaskDeclaration,
        includingAnchor: Bool
    ) async throws -> ArtifactDigest {
        let tasks = includingAnchor ? [anchor, task] : [task]
        let report = try await ColliderRuntime().execute(
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
