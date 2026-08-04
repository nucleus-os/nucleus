import ColliderCore
import Foundation
import SystemPackage
import Testing

@testable import ColliderRuntime

private struct ParallelismProbeIdentity: ColliderActionIdentity {
    let name: String

    func encode(into encoder: inout ActionIdentityEncoder) {
        encoder.append(tag: 1, string: name)
    }
}

private actor ParallelismProbe {
    private var active = 0
    private var maximumActive = 0

    func exercise() async {
        active += 1
        maximumActive = max(maximumActive, active)
        try? await Task.sleep(for: .milliseconds(100))
        active -= 1
    }

    func maximum() -> Int { maximumActive }
}

private struct ParallelismProbeAction: ColliderAction {
    static let kind: ActionKind = "test.parallelism-probe"

    let identity: ParallelismProbeIdentity
    let probe: ParallelismProbe
    let output: FilePath

    var requirements: ActionRequirements {
        ActionRequirements(effects: [
            ActionEffect(.write, scope: .output(output))
        ])
    }

    func execute(in context: ActionContext) async throws {
        await probe.exercise()
        try context.files.write(Array(identity.name.utf8), to: output)
    }
}

@Test func taskSchedulerRunsIndependentTasksConcurrently() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-concurrency-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = FilePath(directory.path)
    let probe = ParallelismProbe()
    let tasks = try ["first", "second"].map { name in
        let output = root.appending(name)
        return TaskDeclaration(
            id: TaskID(rawValue: "fixture.concurrent.\(name)"),
            component: ComponentID(rawValue: "fixture"),
            outputs: [
                OutputDeclaration(path: output, validation: .regularFile)
            ],
            action:
                try AnyColliderAction(
                    ParallelismProbeAction(
                        identity: ParallelismProbeIdentity(name: name),
                        probe: probe,
                        output: output)))
    }

    let report = try await ColliderRuntime().execute(
        graph: TaskGraph(tasks),
        selected: tasks.map(\.id),
        stateRoot: root.appending("state"),
        options: TaskExecutionOptions(maximumParallelism: 2))
    let maximumActive = await probe.maximum()

    #expect(report.executed == tasks.map(\.id))
    #expect(maximumActive == 2)
}

@Test func taskSchedulerSerializesTasksWithTheSameLock() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-lock-concurrency-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = FilePath(directory.path)
    let probe = ParallelismProbe()
    let lock = TaskLock.checkout("fixture-shared-checkout")
    let tasks = try ["first", "second"].map { name in
        let output = root.appending(name)
        return TaskDeclaration(
            id: TaskID(rawValue: "fixture.locked.\(name)"),
            component: ComponentID(rawValue: "fixture"),
            outputs: [
                OutputDeclaration(path: output, validation: .regularFile)
            ],
            locks: [lock],
            action:
                try AnyColliderAction(
                    ParallelismProbeAction(
                        identity: ParallelismProbeIdentity(name: name),
                        probe: probe,
                        output: output)))
    }

    _ = try await ColliderRuntime().execute(
        graph: TaskGraph(tasks),
        selected: tasks.map(\.id),
        stateRoot: root.appending("state"),
        options: TaskExecutionOptions(maximumParallelism: 2))
    let maximumActive = await probe.maximum()

    #expect(maximumActive == 1)
}

@Test func unselectedToolsAreNotResolvedAndPlanOrderIsDeterministic() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-selected-closure-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = FilePath(directory.path)
    let selected = TaskDeclaration(
        id: TaskID(rawValue: "fixture.selected"),
        component: ComponentID(rawValue: "fixture"),
        action: try fixtureCreateDirectoryAction(root.appending("selected")))
    let unselected = TaskDeclaration(
        id: TaskID(rawValue: "fixture.unselected"),
        component: ComponentID(rawValue: "fixture"),
        inputs: [.tool(.named("collider-intentionally-missing-tool"))],
        action: try fixtureCommandAction(
            CommandSpec(
                executable: .named("collider-intentionally-missing-tool"),
                arguments: [],
                workingDirectory: root,
                environment: [:])))
    let unselectedContainer = TaskDeclaration(
        id: TaskID(rawValue: "fixture.unselected-container"),
        component: ComponentID(rawValue: "fixture"),
        action: try fixturePrepareOCIImageAction(
            OCIImagePreparation(
                executionPlatform: ExecutionPlatform(
                    environment: .native,
                    operatingSystem: .android,
                    architecture: .arm64),
                context: root,
                containerFile: root.appending("missing-Containerfile"),
                imageID: root.appending("missing-image"),
                imageName: "unselected-fixture",
                environment: [:])))

    let first = try await ColliderRuntime().execute(
        graph: TaskGraph([selected, unselected, unselectedContainer]),
        selected: [selected.id],
        stateRoot: root.appending("state"),
        options: TaskExecutionOptions(dryRun: true))
    let second = try await ColliderRuntime().execute(
        graph: TaskGraph([unselectedContainer, unselected, selected]),
        selected: [selected.id],
        stateRoot: root.appending("state"),
        options: TaskExecutionOptions(dryRun: true))

    #expect(first.plan.map(\.task) == [selected.id])
    #expect(second.plan.map(\.task) == [selected.id])
    #expect(first.plan.map(\.identity) == second.plan.map(\.identity))
}

@Test func taskOutputStreamsLoggedCommandsByDefaultAndQuietSuppressesInheritedOutput() {
    #expect(
        TaskOutputPresentation.stream.output(for: .logged)
            == CommandSpec.Output.inherited)
    #expect(
        TaskOutputPresentation.quiet.output(for: .inherited)
            == CommandSpec.Output.logged)
    #expect(
        TaskOutputPresentation.stream.output(for: .captured(limit: 4096))
            == CommandSpec.Output.captured(limit: 4096))
    #expect(
        TaskOutputPresentation.quiet.output(for: .file(FilePath("/tmp/output")))
            == CommandSpec.Output.file(FilePath("/tmp/output")))
}

@Test func taskIdentitySurvivesAShellSearchPathThatChangesEveryInvocation()
    async throws
{
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-path-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let tool = FilePath("/usr/bin/env")
    func task(searchPath: String, language: String) throws -> TaskDeclaration {
        TaskDeclaration(
            id: TaskID(rawValue: "fixture.search-path"),
            component: ComponentID(rawValue: "fixture"),
            inputs: [.tool(.path(tool))],
            action: try fixtureCommandAction(
                CommandSpec(
                    executable: .path(tool),
                    arguments: ["true"],
                    workingDirectory: FilePath(directory.path),
                    environment: ["PATH": searchPath, "LANG": language])))
    }
    func identity(of task: TaskDeclaration) async throws -> ArtifactDigest {
        try await ColliderRuntime().execute(
            graph: TaskGraph([task]),
            selected: [task.id],
            stateRoot: FilePath(directory.appendingPathComponent("state").path),
            options: TaskExecutionOptions(dryRun: true)
        ).plan[0].identity
    }

    let first = try await identity(
        of: try task(
            searchPath: "/run/shim/98431_1785277689021:/usr/bin", language: "C"))
    let relaunched = try await identity(
        of: try task(
            searchPath: "/run/shim/98452_1785277711088:/usr/bin", language: "C"))
    let reconfigured = try await identity(
        of: try task(
            searchPath: "/run/shim/98431_1785277689021:/usr/bin", language: "en_US"))

    #expect(first == relaunched)
    #expect(first != reconfigured)
}

@Test func namedToolIdentityUsesTheCanonicalExecutableBehindTransientShims()
    async throws
{
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-tool-shim-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let installation = directory.appendingPathComponent("installation/bin")
    let firstShim = directory.appendingPathComponent("shim-1")
    let secondShim = directory.appendingPathComponent("shim-2")
    for path in [installation, firstShim, secondShim] {
        try FileManager.default.createDirectory(
            at: path, withIntermediateDirectories: true)
    }
    let tool = installation.appendingPathComponent("fixture-tool")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: tool)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: tool.path)
    for shim in [firstShim, secondShim] {
        try FileManager.default.createSymbolicLink(
            atPath: shim.appendingPathComponent("fixture-tool").path,
            withDestinationPath: tool.path)
    }
    func identity(searchRoot: URL) async throws -> ArtifactDigest {
        let task = TaskDeclaration(
            id: TaskID(rawValue: "fixture.named-tool"),
            component: ComponentID(rawValue: "fixture"),
            inputs: [.tool(.named("fixture-tool"))],
            action: try fixtureCommandAction(
                CommandSpec(
                    executable: .named("fixture-tool"),
                    arguments: [],
                    workingDirectory: FilePath(directory.path),
                    environment: ["PATH": searchRoot.path])))
        return try await ColliderRuntime().execute(
            graph: TaskGraph([task]),
            selected: [task.id],
            stateRoot: FilePath(directory.appendingPathComponent("state").path),
            options: TaskExecutionOptions(dryRun: true)
        ).plan[0].identity
    }

    let first = try await identity(searchRoot: firstShim)
    let second = try await identity(searchRoot: secondShim)

    #expect(first == second)
}

@Test func operationalCommandIdentityDoesNotContainTheAmbientExecutable() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-operational-tool-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    func identity(path: String) async throws -> ArtifactDigest {
        let task = TaskDeclaration(
            id: TaskID(rawValue: "fixture.operational-tool"),
            component: ComponentID(rawValue: "fixture"),
            action: try fixtureCommandAction(
                CommandSpec(
                    executable: .operationalNamed("materializer"),
                    arguments: ["--verify-exact-revision"],
                    workingDirectory: FilePath(directory.path),
                    environment: ["PATH": path, "LANG": "C"])))
        return try await ColliderRuntime().execute(
            graph: TaskGraph([task]),
            selected: [task.id],
            stateRoot: FilePath(directory.appendingPathComponent("state").path),
            options: TaskExecutionOptions(dryRun: true)
        ).plan[0].identity
    }

    let first = try await identity(path: "/first/host/bin")
    let second = try await identity(path: "/second/host/bin")
    #expect(first == second)
}

@Test func taskIdentityEncodingRemainsByteStableAcrossWorkflowMoves() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-identity-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = FilePath("/nucleus/identity-fixture/output")
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.identity"),
        component: ComponentID(rawValue: "fixture"),
        inputs: [
            .value(name: "configuration", bytes: Array("stable-v1".utf8)),
            .environment(name: "MODE", value: "release"),
        ],
        outputs: [
            OutputDeclaration(path: output, validation: .regularFile)
        ],
        action: try fixtureWriteAction(output, bytes: Array("payload\n".utf8)))
    let report = try await ColliderRuntime().execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path),
        options: TaskExecutionOptions(dryRun: true))

    #expect(
        report.plan[0].identity.description
            == "sha256:3a6e894e0ed83e324a340088e7e0f1ee10c8e6e5997bdd97ef3917b1582fa8e6")
}

@Test func taskEngineExplainsInvalidationAndThenSkipsCleanWork() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("output")
    let command = CommandSpec(
        executable: .named("sh"),
        arguments: ["-c", "printf result > \"$1\"", "sh", output.path],
        workingDirectory: FilePath(directory.path),
        environment: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"])
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.write"),
        component: ComponentID(rawValue: "fixture"),
        inputs: [.value(name: "content", bytes: Array("result".utf8))],
        outputs: [OutputDeclaration(path: FilePath(output.path), validation: .regularFile)],
        action: try fixtureCommandAction(command))
    let graph = try TaskGraph([task])
    let runtime = ColliderRuntime()
    let state = FilePath(directory.appendingPathComponent("state").path)
    let first = try await runtime.execute(
        graph: graph, selected: [task.id], stateRoot: state)
    #expect(first.executed == [task.id])
    #expect(first.plan[0].explanation == "no prior task state")
    let second = try await runtime.execute(
        graph: graph, selected: [task.id], stateRoot: state)
    #expect(second.executed.isEmpty)
    #expect(second.plan[0].isClean)
    let rebuilt = try await runtime.execute(
        graph: graph,
        selected: [task.id],
        stateRoot: state,
        options: TaskExecutionOptions(rebuildSelected: true))
    #expect(rebuilt.executed == [task.id])
    #expect(!rebuilt.plan[0].isClean)
    #expect(rebuilt.plan[0].explanation == "rebuild requested for selected task")
}

@Test func selectedSupersetTaskOmitsAndCompletesRedundantDependencyOperation()
    async throws
{
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-subsumption-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = FilePath(directory.path)
    let preparationOutput = root.appending("prepared")
    let buildOutput = root.appending("built")
    let testOutput = root.appending("tested")
    let preparation = TaskDeclaration(
        id: TaskID(rawValue: "fixture.prepare"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [
            OutputDeclaration(
                path: preparationOutput,
                validation: .regularFile)
        ],
        action: try fixtureWriteAction(preparationOutput, bytes: Array("ready".utf8)))
    let build = TaskDeclaration(
        id: TaskID(rawValue: "fixture.build"),
        component: ComponentID(rawValue: "fixture"),
        dependencies: [preparation.id],
        action: try fixtureWriteAction(buildOutput, bytes: Array("redundant".utf8)))
    let test = TaskDeclaration(
        id: TaskID(rawValue: "fixture.test"),
        component: ComponentID(rawValue: "fixture"),
        dependencies: [build.id],
        subsumedDependencies: [build.id],
        outputs: [
            OutputDeclaration(path: testOutput, validation: .regularFile)
        ],
        action: try fixtureWriteAction(testOutput, bytes: Array("tested".utf8)))
    let graph = try TaskGraph([preparation, build, test])
    let runtime = ColliderRuntime()
    let state = root.appending("state")

    let first = try await runtime.execute(
        graph: graph, selected: [test.id], stateRoot: state)
    #expect(first.executed == [preparation.id, test.id])
    #expect(first.plan.first { $0.task == build.id }?.isSubsumed == true)
    #expect(FileManager.default.fileExists(atPath: preparationOutput.string))
    #expect(!FileManager.default.fileExists(atPath: buildOutput.string))
    #expect(FileManager.default.fileExists(atPath: testOutput.string))

    let second = try await runtime.execute(
        graph: graph, selected: [test.id], stateRoot: state)
    #expect(second.executed.isEmpty)
    #expect(second.plan.allSatisfy { $0.isClean })
}

@Test func sharedDependencyExecutesWhenAnySelectedConsumerDoesNotSubsumeIt()
    async throws
{
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-shared-subsumption-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = FilePath(directory.path)
    let buildOutput = root.appending("built")
    let build = TaskDeclaration(
        id: TaskID(rawValue: "fixture.build"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [
            OutputDeclaration(path: buildOutput, validation: .regularFile)
        ],
        action: try fixtureWriteAction(buildOutput, bytes: Array("built".utf8)))
    let superset = TaskDeclaration(
        id: TaskID(rawValue: "fixture.superset"),
        component: ComponentID(rawValue: "fixture"),
        dependencies: [build.id],
        subsumedDependencies: [build.id],
        action: try fixtureCreateDirectoryAction(root.appending("superset")))
    let consumer = TaskDeclaration(
        id: TaskID(rawValue: "fixture.consumer"),
        component: ComponentID(rawValue: "fixture"),
        dependencies: [build.id],
        action: try fixtureCreateDirectoryAction(root.appending("consumer")))

    let report = try await ColliderRuntime().execute(
        graph: TaskGraph([build, superset, consumer]),
        selected: [superset.id, consumer.id],
        stateRoot: root.appending("state"))
    #expect(report.executed == [build.id, superset.id, consumer.id])
    #expect(FileManager.default.fileExists(atPath: buildOutput.string))
}

@Test func executableOutputValidationFollowsTheDeclaredSymlink() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-executable-symlink-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("swift-driver")
    let link = directory.appendingPathComponent("swift")
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.executable-symlink"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [
            OutputDeclaration(
                path: FilePath(link.path),
                validation: .executableFile)
        ],
        action: try fixtureCommandAction(
            CommandSpec(
                executable: .named("sh"),
                arguments: [
                    "-c",
                    "printf '#!/bin/sh\\n' > \"$1\" && chmod 755 \"$1\" && "
                        + "ln -s swift-driver \"$2\"",
                    "sh",
                    executable.path,
                    link.path,
                ],
                workingDirectory: FilePath(directory.path),
                environment: [
                    "PATH": ProcessInfo.processInfo.environment["PATH"]
                        ?? "/usr/bin:/bin"
                ])))
    _ = try await ColliderRuntime().execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))
    _ = try await ColliderRuntime().execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))

    #expect(
        try FileManager.default.destinationOfSymbolicLink(
            atPath: link.path) == "swift-driver")
}

@Test func taskIdentityIgnoresPerRunLoggingDestinations() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-run-environment-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("output")
    let state = FilePath(directory.appendingPathComponent("state").path)
    let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"

    func task(runDirectory: String) throws -> TaskDeclaration {
        TaskDeclaration(
            id: TaskID(rawValue: "fixture.run-environment"),
            component: ComponentID(rawValue: "fixture"),
            outputs: [
                OutputDeclaration(
                    path: FilePath(output.path),
                    validation: .regularFile)
            ],
            action: try fixtureCommandAction(
                CommandSpec(
                    executable: .named("sh"),
                    arguments: ["-c", "printf result > \"$1\"", "sh", output.path],
                    workingDirectory: FilePath(directory.path),
                    environment: [
                        "PATH": path,
                        "NUCLEUS_RUN_DIR": runDirectory,
                        "NUCLEUS_RUN_LOG": runDirectory + "/run.log",
                    ])))
    }

    let runtime = ColliderRuntime()
    let first = try task(runDirectory: "/runs/first")
    _ = try await runtime.execute(
        graph: TaskGraph([first]), selected: [first.id], stateRoot: state)
    let second = try task(runDirectory: "/runs/second")
    let report = try await runtime.execute(
        graph: TaskGraph([second]), selected: [second.id], stateRoot: state)
    #expect(report.executed.isEmpty)
    #expect(report.plan[0].isClean)
}

@Test func outputContractChangesInvalidatePriorTaskState() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-output-contract-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("output")
    let state = FilePath(directory.appendingPathComponent("state").path)
    let command = CommandSpec(
        executable: .named("sh"),
        arguments: ["-c", "printf result > \"$1\"", "sh", output.path],
        workingDirectory: FilePath(directory.path),
        environment: [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        ])

    func task(validation: OutputDeclaration.Validation) throws -> TaskDeclaration {
        TaskDeclaration(
            id: TaskID(rawValue: "fixture.output-contract"),
            component: ComponentID(rawValue: "fixture"),
            outputs: [
                OutputDeclaration(
                    path: FilePath(output.path),
                    validation: validation)
            ],
            action: try fixtureCommandAction(command))
    }

    let runtime = ColliderRuntime()
    let first = try task(validation: .exists)
    _ = try await runtime.execute(
        graph: TaskGraph([first]), selected: [first.id], stateRoot: state)
    let changed = try task(validation: .regularFile)
    let report = try await runtime.execute(
        graph: TaskGraph([changed]), selected: [changed.id], stateRoot: state)
    #expect(report.executed == [changed.id])
    #expect(report.plan[0].explanation.hasPrefix("input identity changed "))
}

@Test func uncommittedSourceContentsInvalidatePriorTaskState() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-source-content-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source")
    let output = directory.appendingPathComponent("output")
    try Data("first".utf8).write(to: source)
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.source-content"),
        component: ComponentID(rawValue: "fixture"),
        inputs: [.file(FilePath(source.path))],
        outputs: [
            OutputDeclaration(
                path: FilePath(output.path), validation: .regularFile)
        ],
        action: try fixtureCommandAction(
            CommandSpec(
                executable: .named("sh"),
                arguments: [
                    "-c", "cp \"$1\" \"$2\"", "sh", source.path, output.path,
                ],
                workingDirectory: FilePath(directory.path),
                environment: [
                    "PATH": ProcessInfo.processInfo.environment["PATH"]
                        ?? "/usr/bin:/bin"
                ])))
    let runtime = ColliderRuntime()
    let graph = try TaskGraph([task])
    let state = FilePath(directory.appendingPathComponent("state").path)
    _ = try await runtime.execute(
        graph: graph, selected: [task.id], stateRoot: state)
    try Data("second".utf8).write(to: source)

    let report = try await runtime.execute(
        graph: graph, selected: [task.id], stateRoot: state)
    #expect(report.executed == [task.id])
    #expect(report.plan[0].explanation.hasPrefix("input identity changed "))
    #expect(try String(contentsOf: output, encoding: .utf8) == "second")
}

@Test func oneActionOwnsOrderedFilesystemMutation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-sequence-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let candidate = FilePath(directory.appendingPathComponent("candidate").path)
    try FileManager.default.createDirectory(
        atPath: candidate.string, withIntermediateDirectories: true)
    try Data("stale".utf8).write(
        to: URL(fileURLWithPath: candidate.appending("stale").string))
    let payload = candidate.appending("payload")
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.sequence"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [
            OutputDeclaration(path: payload, validation: .regularFile)
        ],
        action: try fixturePrepareAndWriteAction(
            root: candidate,
            file: payload,
            bytes: Array("fresh".utf8),
            reset: true))

    let report = try await ColliderRuntime().execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))
    #expect(report.executed == [task.id])
    #expect(
        !FileManager.default.fileExists(
            atPath: candidate.appending("stale").string))
    #expect(
        try String(
            contentsOf: URL(fileURLWithPath: payload.string),
            encoding: .utf8) == "fresh")
}

@Test func directoryRetentionKeepsNewestAndCurrentContentIdentities() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-directory-retention-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let generations = directory.appendingPathComponent("generations")
    try FileManager.default.createDirectory(
        at: generations, withIntermediateDirectories: true)
    let names = [
        "111111111111111111111111",
        "222222222222222222222222",
        "333333333333333333333333",
    ]
    for (index, name) in names.enumerated() {
        let path = generations.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: path, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: Double(index))],
            ofItemAtPath: path.path)
    }
    let current = directory.appendingPathComponent("current")
    try FileManager.default.createSymbolicLink(
        atPath: current.path,
        withDestinationPath: "generations/\(names[0])")
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.prune-directories"),
        component: ComponentID(rawValue: "fixture"),
        assessmentPolicy: .always,
        action: try fixturePruneDirectoriesAction(
            DirectoryRetentionPlan(
                safetyRoot: FilePath(directory.path),
                rules: [
                    DirectoryRetentionRule(
                        root: FilePath(generations.path),
                        current: FilePath(current.path),
                        retain: 1,
                        naming: .contentIdentity)
                ])))
    _ = try await ColliderRuntime().execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))
    #expect(
        FileManager.default.fileExists(
            atPath: generations.appendingPathComponent(names[0]).path))
    #expect(
        !FileManager.default.fileExists(
            atPath: generations.appendingPathComponent(names[1]).path))
    #expect(
        FileManager.default.fileExists(
            atPath: generations.appendingPathComponent(names[2]).path))
}

@Test func directoryRetentionRemovesOnlySwiftSDKCandidateDirectories() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-swift-sdk-candidate-retention-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let generations = directory.appendingPathComponent("generations")
    try FileManager.default.createDirectory(
        at: generations, withIntermediateDirectories: true)
    let candidate = generations.appendingPathComponent(
        ".candidate-1234567890abcdef12345678-2026-08-02T01-42-29Z-38631")
    let active = generations.appendingPathComponent("1234567890abcdef12345678")
    let unrelated = generations.appendingPathComponent(".candidate-manual-not-owned")
    for path in [candidate, active, unrelated] {
        try FileManager.default.createDirectory(
            at: path, withIntermediateDirectories: true)
    }
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.prune-swift-sdk-candidates"),
        component: ComponentID(rawValue: "fixture"),
        assessmentPolicy: .always,
        action: try fixturePruneDirectoriesAction(
            DirectoryRetentionPlan(
                safetyRoot: FilePath(directory.path),
                rules: [
                    DirectoryRetentionRule(
                        root: FilePath(generations.path),
                        retain: 0,
                        naming: .swiftSDKCandidate)
                ])))
    _ = try await ColliderRuntime().execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))

    #expect(!FileManager.default.fileExists(atPath: candidate.path))
    #expect(FileManager.default.fileExists(atPath: active.path))
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
}

@Test func invalidGenerationCandidateNeverReplacesTheActivePointer() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-generation-rollback-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let previous = directory.appendingPathComponent("generation-previous")
    let candidate = directory.appendingPathComponent("candidate")
    let generation = directory.appendingPathComponent("generation-invalid")
    let active = directory.appendingPathComponent("active")
    try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        atPath: active.path,
        withDestinationPath: "generation-previous")
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.publish-invalid"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [
            OutputDeclaration(
                path: FilePath(generation.path),
                validation: .nonEmptyDirectory),
            OutputDeclaration(path: FilePath(active.path), validation: .exists),
        ],
        action: try fixtureActivateGenerationAction(
            candidate: FilePath(candidate.path),
            generation: FilePath(generation.path),
            active: FilePath(active.path)))

    await #expect(throws: (any Error).self) {
        try await ColliderRuntime().execute(
            graph: TaskGraph([task]),
            selected: [task.id],
            stateRoot: FilePath(directory.appendingPathComponent("state").path))
    }
    #expect(FileManager.default.fileExists(atPath: candidate.path))
    #expect(!FileManager.default.fileExists(atPath: generation.path))
    #expect(
        try FileManager.default.destinationOfSymbolicLink(atPath: active.path)
            == "generation-previous")
}

@Test func taskEnginePublishesAndAtomicallyActivatesImmutableGeneration() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-generation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let candidate = directory.appendingPathComponent("candidate")
    let generation = directory.appendingPathComponent("generation-1")
    let active = directory.appendingPathComponent("active")
    try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
    try Data("artifact".utf8).write(to: candidate.appendingPathComponent("payload"))
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.publish"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [
            OutputDeclaration(
                path: FilePath(generation.path),
                validation: .nonEmptyDirectory),
            OutputDeclaration(path: FilePath(active.path), validation: .exists),
        ],
        action: try fixtureActivateGenerationAction(
            candidate: FilePath(candidate.path),
            generation: FilePath(generation.path),
            active: FilePath(active.path)))

    let report = try await ColliderRuntime().execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))
    #expect(report.executed == [task.id])
    #expect(!FileManager.default.fileExists(atPath: candidate.path))
    #expect(
        try FileManager.default.destinationOfSymbolicLink(atPath: active.path)
            == "generation-1")
    #expect(
        try String(
            contentsOf: generation.appendingPathComponent("payload"),
            encoding: .utf8) == "artifact")
}

@Test func generationPublicationCutsOverMutableLayoutAndReusesIdenticalGeneration() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-generation-cutover-\(UUID().uuidString)")
    let candidate = directory.appendingPathComponent("candidate")
    let generation = directory.appendingPathComponent("generation")
    let active = directory.appendingPathComponent("active")
    try FileManager.default.createDirectory(
        at: candidate, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: active, withIntermediateDirectories: true)
    try Data("obsolete".utf8).write(
        to: active.appendingPathComponent("mutable"))
    try Data("artifact".utf8).write(
        to: candidate.appendingPathComponent("payload"))
    defer { try? FileManager.default.removeItem(at: directory) }

    try GenerationPublisher.publish(
        candidate: FilePath(candidate.path),
        generation: FilePath(generation.path),
        active: FilePath(active.path))
    #expect(
        try FileManager.default.destinationOfSymbolicLink(
            atPath: active.path) == "generation")

    try FileManager.default.createDirectory(
        at: candidate, withIntermediateDirectories: true)
    try Data("artifact".utf8).write(
        to: candidate.appendingPathComponent("payload"))
    try GenerationPublisher.publish(
        candidate: FilePath(candidate.path),
        generation: FilePath(generation.path),
        active: FilePath(active.path))
    #expect(!FileManager.default.fileExists(atPath: candidate.path))
    #expect(
        try FileManager.default.destinationOfSymbolicLink(
            atPath: active.path) == "generation")
}

@Test func publicationFaultsPreserveACompleteOldOrNewActiveGeneration() throws {
    struct InjectedPublicationFault: Error {}

    for boundary in GenerationPublicationBoundary.allCases {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "collider-generation-fault-\(UUID().uuidString)")
        let previous = directory.appendingPathComponent("previous")
        let candidate = directory.appendingPathComponent("candidate")
        let generation = directory.appendingPathComponent("generation")
        let active = directory.appendingPathComponent("active")
        try FileManager.default.createDirectory(
            at: previous, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: candidate, withIntermediateDirectories: true)
        try Data("old".utf8).write(
            to: previous.appendingPathComponent("payload"))
        try Data("new".utf8).write(
            to: candidate.appendingPathComponent("payload"))
        try FileManager.default.createSymbolicLink(
            atPath: active.path, withDestinationPath: "previous")
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: InjectedPublicationFault.self) {
            try GenerationPublisher.publish(
                candidate: FilePath(candidate.path),
                generation: FilePath(generation.path),
                active: FilePath(active.path),
                after: {
                    if $0 == boundary { throw InjectedPublicationFault() }
                })
        }

        let cutoverCompleted =
            switch boundary {
            case .activePointerReplaced, .activeDirectorySynchronized:
                true
            default:
                false
            }
        let target = try FileManager.default.destinationOfSymbolicLink(
            atPath: active.path)
        #expect(target == (cutoverCompleted ? "generation" : "previous"))
        let activePayload =
            active
            .resolvingSymlinksInPath()
            .appendingPathComponent("payload")
        #expect(
            try String(contentsOf: activePayload, encoding: .utf8)
                == (cutoverCompleted ? "new" : "old"))
        #expect(FileManager.default.fileExists(atPath: previous.path))
    }
}
