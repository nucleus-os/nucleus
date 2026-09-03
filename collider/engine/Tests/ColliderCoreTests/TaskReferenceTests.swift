import ColliderCore
import ColliderEngine
import Foundation
import SystemPackage
import Testing

@testable import ColliderRuntime

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

@Test func identityEncodingIsSequentialAndTypeSensitive() {
    var forward = IdentityEncoder()
    forward.append("one")
    forward.append(2)
    var reverse = IdentityEncoder()
    reverse.append(2)
    reverse.append("one")
    var differentType = IdentityEncoder()
    differentType.append(bytes: Array("one".utf8))
    differentType.append(2)

    #expect(forward.bytes != reverse.bytes)
    #expect(forward.bytes != differentType.bytes)
}

@Test func identityEncodingFramesOptionalRecordsAndSequences() {
    var first = IdentityEncoder()
    first.appendOptional(nil as String?) { $0.append($1) }
    first.appendRecord { $0.append("ab") }
    first.appendSequence(["c", "d"]) { $0.append($1) }

    var second = IdentityEncoder()
    second.appendOptional("" as String?) { $0.append($1) }
    second.appendRecord {
        $0.append("a")
        $0.append("b")
    }
    second.appendSequence(["cd"]) { $0.append($1) }

    #expect(first.bytes != second.bytes)
}

@Test func identityPathRelocationAppliesOnlyToPathValues() {
    let firstRoot = FilePath("/first/workspace")
    let secondRoot = FilePath("/second/workspace")
    var first = IdentityEncoder(
        identityPathMap: IdentityPathMap(roots: [
            IdentityPathRoot(name: "workspace", path: firstRoot)
        ]))
    first.append(path: firstRoot.appending("Sources/input.swift"))
    first.append(firstRoot.appending("literal").string)

    var second = IdentityEncoder(
        identityPathMap: IdentityPathMap(roots: [
            IdentityPathRoot(name: "workspace", path: secondRoot)
        ]))
    second.append(path: secondRoot.appending("Sources/input.swift"))
    second.append(secondRoot.appending("literal").string)

    #expect(first.bytes != second.bytes)

    var relocatedPath = IdentityEncoder(
        identityPathMap: IdentityPathMap(roots: [
            IdentityPathRoot(name: "workspace", path: secondRoot)
        ]))
    relocatedPath.append(path: secondRoot.appending("Sources/input.swift"))

    var originalPath = IdentityEncoder(
        identityPathMap: IdentityPathMap(roots: [
            IdentityPathRoot(name: "workspace", path: firstRoot)
        ]))
    originalPath.append(path: firstRoot.appending("Sources/input.swift"))
    #expect(originalPath.bytes == relocatedPath.bytes)
}

@Test func ociResourceLimitsDoNotInvalidateActionResults() throws {
    func identity(
        resourceLimits: OCIResourceLimits,
        entrypoint: String? = nil
    ) throws -> [UInt8] {
        let execution = OCIExecution(
            executionPlatform: .linuxARM64OCI,
            artifactTarget: .linuxARM64,
            imageID: FilePath("/fixture/image-id"),
            hostname: "fixture",
            workingDirectory: "/workspace",
            hostWorkingDirectory: FilePath("/fixture"),
            mounts: [],
            userPolicy: .builder,
            capabilityPolicy: .dropAll,
            privilegePolicy: .prohibitAcquisition,
            processFilesystemPolicy: .standard,
            resourceLimits: resourceLimits,
            containerEnvironment: [:],
            imageEntrypointOverride: entrypoint,
            command: ["build"],
            environment: [:],
            output: .logged)
        var encoder = IdentityEncoder()
        OCIExecutionActionIdentity(execution).encode(into: &encoder)
        return encoder.bytes
    }

    #expect(try identity(resourceLimits: .build) == identity(resourceLimits: .parallelBuild))
    #expect(
        try identity(resourceLimits: .build)
            != identity(
                resourceLimits: .build,
                entrypoint: "/collider-entrypoints/build"))
}

@Test func ociEnvironmentIdentityIgnoresDeclaredHostPlacement() {
    func identity(workspace: FilePath) -> [UInt8] {
        let map = IdentityPathMap(roots: [
            IdentityPathRoot(name: "workspace", path: workspace)
        ])
        let execution = OCIExecution(
            executionPlatform: .linuxARM64OCI,
            artifactTarget: .linuxARM64,
            imageID: workspace.appending("image-id"),
            hostname: "fixture",
            workingDirectory: "/nucleus-workspace",
            hostWorkingDirectory: workspace,
            mounts: [
                OCIMount(
                    source: workspace,
                    target: "/nucleus-workspace",
                    access: .readOnly)
            ],
            userPolicy: .builder,
            capabilityPolicy: .dropAll,
            privilegePolicy: .prohibitAcquisition,
            processFilesystemPolicy: .standard,
            resourceLimits: .build,
            containerEnvironment: ["CCACHE_BASEDIR": workspace.string],
            command: ["build"],
            environment: [:],
            output: .logged)
        var encoder = IdentityEncoder(identityPathMap: map)
        OCIExecutionActionIdentity(execution).encode(into: &encoder)
        return encoder.bytes
    }

    #expect(
        identity(workspace: FilePath("/Library/Nucleus/checkout"))
            == identity(workspace: FilePath("/Users/builder/work/nucleus")))
}

@Test func mountedOCIEntrypointBindsItsContainingDirectory() throws {
    var builder = TaskBuilder(
        id: TaskID(rawValue: "fixture.image"),
        component: ComponentID(rawValue: "fixture"))
    let image = try builder.output(
        "image-id",
        path: FilePath("/cache/image-id"),
        validation: .regularFile)
    let entrypoint = OCIMountedEntrypoint(
        image: image,
        executable: FilePath("/workspace/tools/build-entrypoint.sh"),
        containerDirectory: "/collider-entrypoints/build")

    #expect(entrypoint.mount.source == FilePath("/workspace/tools"))
    #expect(entrypoint.mount.target == "/collider-entrypoints/build")
    #expect(entrypoint.mount.isReadOnly)
    #expect(
        entrypoint.containerPath
            == "/collider-entrypoints/build/build-entrypoint.sh")
    #expect(entrypoint.input == .file(entrypoint.executable))
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

    let failure = await #expect(throws: ExecutionFailure.self) {
        try await pipeline.execute(in: context)
    }
    #expect(failure?.status == 7)
    #expect(failure?.reason == "OCI pipeline command 0 failed")
}

@Test func containerRunRejectsNonzeroWhileExecuteReturnsTheResult() async throws {
    let execution = OCIExecution(
        executionPlatform: .linuxARM64OCI,
        artifactTarget: .linuxARM64,
        imageID: FilePath("/fixture/image-id"),
        hostname: "fixture",
        workingDirectory: "/workspace",
        hostWorkingDirectory: FilePath("/fixture"),
        mounts: [],
        userPolicy: .builder,
        capabilityPolicy: .dropAll,
        privilegePolicy: .prohibitAcquisition,
        processFilesystemPolicy: .standard,
        resourceLimits: .parallelBuild,
        containerEnvironment: [:],
        command: ["false"],
        environment: [:],
        output: .captured(limit: 1_024))
    let executor = ActionContainerExecutor(
        run: { _ in CommandResult(status: 19) })

    let failure = await #expect(throws: ExecutionFailure.self) {
        try await executor.run(execution)
    }
    #expect(failure?.status == 19)
    #expect(failure?.reason == "container command failed")
    let result = try await executor.execute(execution)
    #expect(result.status == 19)
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

@Test func taskBuilderCreatesArtifactAndOrderingEdges() throws {
    let producerID = TaskID(rawValue: "fixture.producer")
    var producer = TaskBuilder(
        id: producerID,
        component: ComponentID(rawValue: "fixture"))
    let artifact: ArtifactReference = try producer.output(
        "report",
        path: FilePath("/tmp/fixture/report.json"),
        validation: .json)
    let ordering = producer.ordering
    let producerTask = producer.build(
        action: try fixtureWriteAction(
            artifact.path,
            bytes: Array("{}".utf8)))

    var consumer = TaskBuilder(
        id: TaskID(rawValue: "fixture.consumer"),
        component: ComponentID(rawValue: "fixture"))
    consumer.consume(artifact)
    consumer.after(ordering)
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
    let reference: ArtifactReference = try declaredProducer.output(
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

@Test func taskBuilderReservesExecutableCapabilityForExecutableOutputs() throws {
    var builder = TaskBuilder(
        id: TaskID(rawValue: "fixture.producer"),
        component: ComponentID(rawValue: "fixture"))
    let directory = try builder.output(
        "directory",
        path: FilePath("/tmp/fixture/directory"),
        validation: .nonEmptyDirectory)
    let executable = try builder.executableOutput(
        "executable",
        path: FilePath("/tmp/fixture/tool"))

    #expect(directory.validation == .nonEmptyDirectory)
    #expect(executable.artifact.validation == .executableFile)
    #expect(executable.executable == .artifact(executable.artifact))
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
        let _: ArtifactReference = try builder.output(
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
    let ordered = try await identity(
        consumer(
            after: TaskBuilder(id: anchorID, component: component).ordering,
            policy: .incremental),
        includingAnchor: true)

    #expect(incremental == ordered)
}

/// Allocation used to be one machine's capacity transcribed by hand, correct
/// on that machine and wrong on every other. What matters is not the numbers
/// but the relationships: a task with the machine gets the machine, a task
/// that may be sharing gets half the cores, and two of the latter together
/// still leave the host memory to run in. Reading the machine at all is
/// only safe because allocation stays outside task identity, which
/// `ociResourceLimitsDoNotInvalidateActionResults` above asserts directly.
@Test func allocationTiersFollowTheMachineRatherThanOneMachinesNumbers() {
    let whole = OCIResourceLimits.build
    let shared = OCIResourceLimits.parallelBuild
    let processors = UInt32(ProcessInfo.processInfo.activeProcessorCount)

    #expect(whole.cpuCount == processors)
    #expect(whole.memoryBytes == ProcessInfo.processInfo.physicalMemory)
    #expect(shared.cpuCount == max(1, processors / 2))
    #expect((shared.cpuCount ?? 0) >= 1)

    let sharedMemory = try! #require(shared.memoryBytes)
    let wholeMemory = try! #require(whole.memoryBytes)
    // Two sharing tasks must not commit the host's last byte.
    #expect(sharedMemory * 2 <= wholeMemory)
    #expect(sharedMemory >= 1_024 * 1_024 * 1_024)
}
