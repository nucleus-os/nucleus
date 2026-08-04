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
            operation: .action(
                try AnyColliderAction(
                    ParallelismProbeAction(
                        identity: ParallelismProbeIdentity(name: name),
                        probe: probe,
                        output: output))))
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
            operation: .action(
                try AnyColliderAction(
                    ParallelismProbeAction(
                        identity: ParallelismProbeIdentity(name: name),
                        probe: probe,
                        output: output))))
    }

    _ = try await ColliderRuntime().execute(
        graph: TaskGraph(tasks),
        selected: tasks.map(\.id),
        stateRoot: root.appending("state"),
        options: TaskExecutionOptions(maximumParallelism: 2))
    let maximumActive = await probe.maximum()

    #expect(maximumActive == 1)
}

@Test func taskSchedulerWaitsForSynthesizedSwiftTestBuilds() {
    let packageRoot = FilePath("/tmp/collider-swift-test-readiness")
    let context = SwiftBuildContext(
        packageRoot: packageRoot,
        configuration: .debug,
        target: .host(identity: "arm64-macos"),
        toolchainIdentity: "fixture-toolchain")
    let invocation = SwiftPMInvocation(
        context: context,
        scratchPath: packageRoot.appending("scratch"))
    let requirement = SwiftTestRequirement(
        package: "fixture",
        testProduct: "FixtureTests",
        packageRoot: packageRoot,
        invocation: invocation,
        inputs: [],
        environment: [:])
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.test"),
        component: ComponentID(rawValue: "fixture"),
        swiftTests: [requirement],
        operation: .sequence([]))
    let build = TaskID(rawValue: "swift.package.test.fixture")
    let secondBuild = TaskID(rawValue: "swift.package.build.fixture")
    let buildsByContext = [context: Set([build, secondBuild])]

    #expect(
        !requiredSwiftBuildsAreCompleted(
            for: task,
            buildsByContext: buildsByContext,
            completed: []))
    #expect(
        !requiredSwiftBuildsAreCompleted(
            for: task,
            buildsByContext: buildsByContext,
            completed: [build]))
    #expect(
        requiredSwiftBuildsAreCompleted(
            for: task,
            buildsByContext: buildsByContext,
            completed: [build, secondBuild]))
}

@Test func unselectedToolsAreNotResolvedAndPlanOrderIsDeterministic() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-selected-closure-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = FilePath(directory.path)
    let selected = TaskDeclaration(
        id: TaskID(rawValue: "fixture.selected"),
        component: ComponentID(rawValue: "fixture"),
        operation: try fixtureCreateDirectoryOperation(root.appending("selected")))
    let unselected = TaskDeclaration(
        id: TaskID(rawValue: "fixture.unselected"),
        component: ComponentID(rawValue: "fixture"),
        inputs: [.tool(.named("collider-intentionally-missing-tool"))],
        operation: .command(
            CommandSpec(
                executable: .named("collider-intentionally-missing-tool"),
                arguments: [],
                workingDirectory: root,
                environment: [:])))
    let unselectedContainer = TaskDeclaration(
        id: TaskID(rawValue: "fixture.unselected-container"),
        component: ComponentID(rawValue: "fixture"),
        operation: try fixturePrepareOCIImageOperation(
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

@Test func synthesizedSwiftTestForwardsSelectionArguments() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-swift-test-arguments-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let package = directory.appendingPathComponent("package")
    let tools = directory.appendingPathComponent("tools")
    let scratch = directory.appendingPathComponent("scratch")
    try FileManager.default.createDirectory(
        at: package, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: tools, withIntermediateDirectories: true)
    try Data("// swift-tools-version: 6.4\n".utf8).write(
        to: package.appendingPathComponent("Package.swift"))

    let arguments = directory.appendingPathComponent("arguments")
    let swift = tools.appendingPathComponent("swift")
    let script = """
        #!/bin/sh
        set -eu
        printf '%s\n' "$@" > "\(arguments.path)"
        mkdir -p "\(scratch.path)"
        printf 'complete\n' > "\(scratch.appendingPathComponent("result").path)"
        """
    try Data(script.utf8).write(to: swift)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: swift.path)

    let packageRoot = FilePath(package.path)
    let context = SwiftBuildContext(
        packageRoot: packageRoot,
        configuration: .debug,
        target: .host(identity: "arm64-macos"),
        toolchainIdentity: "fixture-toolchain")
    let invocation = SwiftPMInvocation(
        context: context,
        scratchPath: FilePath(scratch.path))
    let requirement = SwiftTestRequirement(
        package: "fixture",
        testProduct: "FixtureTests",
        packageRoot: packageRoot,
        invocation: invocation,
        inputs: [],
        environment: ["PATH": "\(tools.path):/usr/bin:/bin"],
        arguments: ["--filter", "gpuHeadless_"])
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.filtered-test"),
        component: ComponentID(rawValue: "fixture"),
        swiftTests: [requirement],
        operation: .sequence([]))

    _ = try await ColliderRuntime().execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))

    let received = try String(contentsOf: arguments, encoding: .utf8)
        .split(whereSeparator: \.isNewline)
        .map(String.init)
    #expect(received.filter { $0 == "test" }.count == 1)
    #expect(received.first == "test")
    #expect(received.suffix(2) == ["--filter", "gpuHeadless_"])
}

@Test func synthesizedSwiftBuildCoalescesProductsIntoOneRootInvocation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-swift-product-selection-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let package = directory.appendingPathComponent("package")
    let tools = directory.appendingPathComponent("tools")
    let scratch = directory.appendingPathComponent("scratch")
    try FileManager.default.createDirectory(
        at: package, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: tools, withIntermediateDirectories: true)
    try Data("// swift-tools-version: 6.4\n".utf8).write(
        to: package.appendingPathComponent("Package.swift"))

    let arguments = directory.appendingPathComponent("arguments")
    let swift = tools.appendingPathComponent("swift")
    let script = """
        #!/bin/sh
        set -eu
        printf '%s ' "$@" >> "\(arguments.path)"
        printf '\n' >> "\(arguments.path)"
        mkdir -p "\(scratch.path)"
        """
    try Data(script.utf8).write(to: swift)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: swift.path)

    let packageRoot = FilePath(package.path)
    let context = SwiftBuildContext(
        packageRoot: packageRoot,
        configuration: .debug,
        target: .host(identity: "arm64-macos"),
        toolchainIdentity: "fixture-toolchain")
    let invocation = SwiftPMInvocation(
        context: context,
        scratchPath: FilePath(scratch.path))
    let tasks = ["SecondProduct", "FirstProduct"].map { product in
        let requirement = SwiftProductRequirement(
            package: "fixture",
            product: product,
            packageRoot: packageRoot,
            invocation: invocation,
            inputs: [.file(packageRoot.appending("Package.swift"))],
            environment: ["PATH": "\(tools.path):/usr/bin:/bin"])
        return TaskDeclaration(
            id: TaskID(rawValue: "fixture.\(product)"),
            component: ComponentID(rawValue: "fixture"),
            swiftProducts: [requirement],
            operation: .sequence([]))
    }

    let report = try await ColliderRuntime().execute(
        graph: TaskGraph(tasks),
        selected: tasks.map(\.id),
        stateRoot: FilePath(directory.appendingPathComponent("state").path))

    let received = try String(contentsOf: arguments, encoding: .utf8)
        .split(whereSeparator: \.isNewline)
        .map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
    #expect(received.count == 1)
    #expect(received[0].first == "build")
    #expect(!received[0].contains("--product"))
    #expect(report.swiftPMInvocationCount == 1)
    #expect(report.selectedInputHashingDurationNanoseconds > 0)
    #expect(report.executionDurationNanoseconds > 0)
}

@Test func distinctSwiftTestFiltersRemainDistinctInvocations() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-swift-test-filter-groups-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let package = directory.appendingPathComponent("package")
    let tools = directory.appendingPathComponent("tools")
    let scratch = directory.appendingPathComponent("scratch")
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
    try Data("// swift-tools-version: 6.4\n".utf8).write(
        to: package.appendingPathComponent("Package.swift"))
    let arguments = directory.appendingPathComponent("arguments")
    let swift = tools.appendingPathComponent("swift")
    try Data(
        "#!/bin/sh\nset -eu\nprintf '%s ' \"$@\" >> '\(arguments.path)'\nprintf '\\n' >> '\(arguments.path)'\nmkdir -p '\(scratch.path)'\n"
            .utf8
    ).write(to: swift)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: swift.path)

    let packageRoot = FilePath(package.path)
    let invocation = SwiftPMInvocation(
        context: SwiftBuildContext(
            packageRoot: packageRoot,
            configuration: .release,
            target: .host(identity: "arm64-macos"),
            toolchainIdentity: "fixture-toolchain"),
        scratchPath: FilePath(scratch.path))
    let environment = ["PATH": "\(tools.path):/usr/bin:/bin"]
    let tasks = ["FirstSuite", "SecondSuite"].map { suite in
        TaskDeclaration(
            id: TaskID(rawValue: "fixture.\(suite)"),
            component: ComponentID(rawValue: "fixture"),
            swiftTests: [
                SwiftTestRequirement(
                    package: "fixture",
                    testProduct: suite,
                    packageRoot: packageRoot,
                    invocation: invocation,
                    inputs: [],
                    environment: environment,
                    arguments: ["--filter", suite])
            ],
            operation: .sequence([]))
    }

    let report = try await ColliderRuntime().execute(
        graph: TaskGraph(tasks),
        selected: tasks.map(\.id),
        stateRoot: FilePath(directory.appendingPathComponent("state").path))
    let commands = try String(contentsOf: arguments, encoding: .utf8)
        .split(whereSeparator: \.isNewline)
        .map(String.init)

    #expect(report.swiftPMInvocationCount == 2)
    #expect(commands.count == 2)
    #expect(commands.contains { $0.contains("--filter FirstSuite") })
    #expect(commands.contains { $0.contains("--filter SecondSuite") })
}

@Test func synthesizedSwiftBuildRunsDeclaredHeaderTargetBeforeTheRootBuild() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-swift-prebuild-target-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let package = directory.appendingPathComponent("package")
    let tools = directory.appendingPathComponent("tools")
    let scratch = directory.appendingPathComponent("scratch")
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
    try Data("// swift-tools-version: 6.4\n".utf8).write(
        to: package.appendingPathComponent("Package.swift"))
    let arguments = directory.appendingPathComponent("arguments")
    let swift = tools.appendingPathComponent("swift")
    try Data(
        "#!/bin/sh\nset -eu\nprintf '%s ' \"$@\" >> '\(arguments.path)'\nprintf '\\n' >> '\(arguments.path)'\nmkdir -p '\(scratch.path)'\n"
            .utf8
    ).write(to: swift)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: swift.path)

    let packageRoot = FilePath(package.path)
    let invocation = SwiftPMInvocation(
        context: SwiftBuildContext(
            packageRoot: packageRoot,
            configuration: .debug,
            target: .host(identity: "arm64-macos"),
            toolchainIdentity: "fixture-toolchain"),
        scratchPath: FilePath(scratch.path))
    let requirement = SwiftProductRequirement(
        package: "fixture",
        product: "FixtureProduct",
        packageRoot: packageRoot,
        invocation: invocation,
        inputs: [],
        environment: ["PATH": "\(tools.path):/usr/bin:/bin"],
        prebuildTargets: ["GeneratedHeaderTarget"])
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.prebuild"),
        component: ComponentID(rawValue: "fixture"),
        swiftProducts: [requirement],
        operation: .sequence([]))

    _ = try await ColliderRuntime().execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))

    let commands = try String(contentsOf: arguments, encoding: .utf8)
        .split(whereSeparator: \.isNewline)
        .map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
    #expect(commands.count == 2)
    #expect(commands[0].first == "build")
    #expect(commands[0].contains("--target"))
    #expect(commands[0].contains("GeneratedHeaderTarget"))
    #expect(commands[1].first == "build")
    #expect(!commands[1].contains("--target"))
    #expect(commands[1].contains("--product"))
    #expect(commands[1].contains("FixtureProduct"))
}

@Test func swiftTestSubsumesOnlyBuildOutputsItDeclares() async throws {
    func commands(testCoversOutput: Bool) async throws -> [String] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "collider-swift-test-coverage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let package = directory.appendingPathComponent("package")
        let tools = directory.appendingPathComponent("tools")
        let scratch = directory.appendingPathComponent("scratch")
        let executable = directory.appendingPathComponent("FixtureExecutable")
        let arguments = directory.appendingPathComponent("commands")
        try FileManager.default.createDirectory(
            at: package, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tools, withIntermediateDirectories: true)
        try Data("// swift-tools-version: 6.4\n".utf8).write(
            to: package.appendingPathComponent("Package.swift"))

        let swift = tools.appendingPathComponent("swift")
        let testOutputCommand =
            testCoversOutput
            ? "mkdir -p \"\(executable.deletingLastPathComponent().path)\"; "
                + "printf test > \"\(executable.path)\"; chmod 755 \"\(executable.path)\""
            : ":"
        let script = """
            #!/bin/sh
            set -eu
            printf '%s\n' "$1" >> "\(arguments.path)"
            mkdir -p "\(scratch.path)"
            if [ "$1" = build ]; then
              printf build > "\(executable.path)"
              chmod 755 "\(executable.path)"
            elif [ "$1" = test ]; then
              \(testOutputCommand)
            fi
            """
        try Data(script.utf8).write(to: swift)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: swift.path)

        let packageRoot = FilePath(package.path)
        let invocation = SwiftPMInvocation(
            context: SwiftBuildContext(
                packageRoot: packageRoot,
                configuration: .debug,
                target: .host(identity: "arm64-macos"),
                toolchainIdentity: "fixture-toolchain"),
            scratchPath: FilePath(scratch.path))
        let output = PathPostcondition(
            path: FilePath(executable.path),
            validation: .executableFile)
        let environment = ["PATH": "\(tools.path):/usr/bin:/bin"]
        let product = SwiftProductRequirement(
            package: "fixture",
            product: "FixtureExecutable",
            packageRoot: packageRoot,
            invocation: invocation,
            inputs: [],
            environment: environment,
            expectedOutputs: [output])
        let test = SwiftTestRequirement(
            package: "fixture",
            testProduct: "FixtureTests",
            packageRoot: packageRoot,
            invocation: invocation,
            inputs: [],
            environment: environment,
            expectedBuildOutputs: testCoversOutput ? [output] : [])
        let buildTask = TaskDeclaration(
            id: TaskID(rawValue: "fixture.build"),
            component: ComponentID(rawValue: "fixture"),
            swiftProducts: [product],
            operation: .sequence([]))
        let testTask = TaskDeclaration(
            id: TaskID(rawValue: "fixture.test"),
            component: ComponentID(rawValue: "fixture"),
            dependencies: [buildTask.id],
            subsumedDependencies: [buildTask.id],
            swiftTests: [test],
            operation: .sequence([]))

        _ = try await ColliderRuntime().execute(
            graph: TaskGraph([buildTask, testTask]),
            selected: [testTask.id],
            stateRoot: FilePath(directory.appendingPathComponent("state").path))
        return try String(contentsOf: arguments, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    #expect(try await commands(testCoversOutput: false) == ["build", "test"])
    #expect(try await commands(testCoversOutput: true) == ["test"])
}

@Test func incompatibleSwiftContextsUseSeparateInvocationsAndScratchPaths()
    async throws
{
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-swift-context-separation-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let package = directory.appendingPathComponent("package")
    let tools = directory.appendingPathComponent("tools")
    let arguments = directory.appendingPathComponent("commands")
    try FileManager.default.createDirectory(
        at: package, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: tools, withIntermediateDirectories: true)
    try Data("// swift-tools-version: 6.4\n".utf8).write(
        to: package.appendingPathComponent("Package.swift"))
    let swift = tools.appendingPathComponent("swift")
    try Data(
        "#!/bin/sh\nset -eu\nprintf '%s\\n' \"$*\" >> \"\(arguments.path)\"\n".utf8
    ).write(to: swift)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: swift.path)

    let packageRoot = FilePath(package.path)
    let environment = ["PATH": "\(tools.path):/usr/bin:/bin"]
    let configurations: [SwiftBuildConfiguration] = [.debug, .release]
    let invocations = configurations.map { configuration in
        SwiftPMInvocation(
            context: SwiftBuildContext(
                packageRoot: packageRoot,
                configuration: configuration,
                target: .host(identity: "arm64-macos"),
                toolchainIdentity: "fixture-toolchain"),
            scratchPath: FilePath(
                directory.appendingPathComponent(configuration.rawValue).path))
    }
    let tasks = invocations.enumerated().map { index, invocation in
        TaskDeclaration(
            id: TaskID(rawValue: "fixture.context.\(index)"),
            component: ComponentID(rawValue: "fixture"),
            swiftProducts: [
                SwiftProductRequirement(
                    package: "fixture",
                    product: "FixtureProduct",
                    packageRoot: packageRoot,
                    invocation: invocation,
                    inputs: [],
                    environment: environment)
            ],
            operation: .sequence([]))
    }
    _ = try await ColliderRuntime().execute(
        graph: TaskGraph(tasks),
        selected: tasks.map(\.id),
        stateRoot: FilePath(directory.appendingPathComponent("state").path))

    let commands = try String(contentsOf: arguments, encoding: .utf8)
        .split(whereSeparator: \.isNewline)
        .map(String.init)
    #expect(commands.count == 2)
    for invocation in invocations {
        #expect(commands.contains { $0.contains(invocation.scratchPath.string) })
    }
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
    func task(searchPath: String, language: String) -> TaskDeclaration {
        TaskDeclaration(
            id: TaskID(rawValue: "fixture.search-path"),
            component: ComponentID(rawValue: "fixture"),
            inputs: [.tool(.path(tool))],
            operation: .command(
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
        of: task(
            searchPath: "/run/shim/98431_1785277689021:/usr/bin", language: "C"))
    let relaunched = try await identity(
        of: task(
            searchPath: "/run/shim/98452_1785277711088:/usr/bin", language: "C"))
    let reconfigured = try await identity(
        of: task(
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
            operation: .command(
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
            operation: .command(
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
        operation: try fixtureWriteOperation(output, bytes: Array("payload\n".utf8)))
    let report = try await ColliderRuntime().execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path),
        options: TaskExecutionOptions(dryRun: true))

    #expect(
        report.plan[0].identity.description
            == "sha256:fd3b872dcbf773d953d89995404e4e06cbb07f01f81b9bad50c6180e475c6762")
}

@Test func aospBuildConcurrencyDoesNotChangeArtifactIdentity() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-aosp-job-identity-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    func task(jobs: UInt32) -> TaskDeclaration {
        let root = FilePath(directory.path)
        return TaskDeclaration(
            id: TaskID(rawValue: "fixture.aosp-publish"),
            component: ComponentID(rawValue: "fixture"),
            inputs: [
                .value(name: "product", bytes: Array("stable".utf8))
            ],
            operation: .aospProduct(
                .publish,
                AOSPProductBuild(
                    productSource: root.appending("product"),
                    source: root.appending("source"),
                    repoLauncher: root.appending("repo"),
                    sourceProvenance: root.appending("source-provenance.json"),
                    buildRoot: root.appending("build"),
                    ccacheDirectory: root.appending("ccache"),
                    containerImageID: root.appending("container-image-id"),
                    signingIdentity: root.appending("signing-identity"),
                    product: "nucleus_x86_64",
                    release: "cp2a",
                    variant: "user",
                    buildNumber: "nucleus",
                    buildTimestamp: 1,
                    buildJobs: jobs,
                    expectedPlatformSDK: 37,
                    expectedVendorAPILevel: 202604,
                    environment: [:])))
    }
    let runtime = ColliderRuntime()
    let state = FilePath(directory.appendingPathComponent("state").path)
    let first = try await runtime.execute(
        graph: TaskGraph([task(jobs: 12)]),
        selected: [TaskID(rawValue: "fixture.aosp-publish")],
        stateRoot: state,
        options: TaskExecutionOptions(dryRun: true))
    let second = try await runtime.execute(
        graph: TaskGraph([task(jobs: 24)]),
        selected: [TaskID(rawValue: "fixture.aosp-publish")],
        stateRoot: state,
        options: TaskExecutionOptions(dryRun: true))
    #expect(first.plan[0].identity == second.plan[0].identity)
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
        operation: .command(command))
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
        operation: try fixtureWriteOperation(preparationOutput, bytes: Array("ready".utf8)))
    let build = TaskDeclaration(
        id: TaskID(rawValue: "fixture.build"),
        component: ComponentID(rawValue: "fixture"),
        dependencies: [preparation.id],
        operation: try fixtureWriteOperation(buildOutput, bytes: Array("redundant".utf8)))
    let test = TaskDeclaration(
        id: TaskID(rawValue: "fixture.test"),
        component: ComponentID(rawValue: "fixture"),
        dependencies: [build.id],
        subsumedDependencies: [build.id],
        outputs: [
            OutputDeclaration(path: testOutput, validation: .regularFile)
        ],
        operation: try fixtureWriteOperation(testOutput, bytes: Array("tested".utf8)))
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
        operation: try fixtureWriteOperation(buildOutput, bytes: Array("built".utf8)))
    let superset = TaskDeclaration(
        id: TaskID(rawValue: "fixture.superset"),
        component: ComponentID(rawValue: "fixture"),
        dependencies: [build.id],
        subsumedDependencies: [build.id],
        operation: try fixtureCreateDirectoryOperation(root.appending("superset")))
    let consumer = TaskDeclaration(
        id: TaskID(rawValue: "fixture.consumer"),
        component: ComponentID(rawValue: "fixture"),
        dependencies: [build.id],
        operation: try fixtureCreateDirectoryOperation(root.appending("consumer")))

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
        operation: .command(
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

    func task(runDirectory: String) -> TaskDeclaration {
        TaskDeclaration(
            id: TaskID(rawValue: "fixture.run-environment"),
            component: ComponentID(rawValue: "fixture"),
            outputs: [
                OutputDeclaration(
                    path: FilePath(output.path),
                    validation: .regularFile)
            ],
            operation: .command(
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
    let first = task(runDirectory: "/runs/first")
    _ = try await runtime.execute(
        graph: TaskGraph([first]), selected: [first.id], stateRoot: state)
    let second = task(runDirectory: "/runs/second")
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

    func task(validation: OutputDeclaration.Validation) -> TaskDeclaration {
        TaskDeclaration(
            id: TaskID(rawValue: "fixture.output-contract"),
            component: ComponentID(rawValue: "fixture"),
            outputs: [
                OutputDeclaration(
                    path: FilePath(output.path),
                    validation: validation)
            ],
            operation: .command(command))
    }

    let runtime = ColliderRuntime()
    let first = task(validation: .exists)
    _ = try await runtime.execute(
        graph: TaskGraph([first]), selected: [first.id], stateRoot: state)
    let changed = task(validation: .regularFile)
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
        operation: .command(
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

@Test func taskSequenceOwnsOrderedFilesystemMutation() async throws {
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
        operation: .sequence([
            try fixturePrepareDirectoryOperation(candidate),
            try fixtureWriteOperation(payload, bytes: Array("fresh".utf8)),
        ]))

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
        operation: try fixturePruneDirectoriesOperation(
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
        operation: try fixturePruneDirectoriesOperation(
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

@Test func chromiumSourcePreparationValidatesAndActivatesAnImmutableGeneration() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-chromium-source-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let generations = directory.appendingPathComponent("generations")
    let sourceID = "1234567890abcdef12345678"
    let source = generations.appendingPathComponent(sourceID)
    let chromium = source.appendingPathComponent("chromium/src")
    let cef = chromium.appendingPathComponent("cef")
    let angle = chromium.appendingPathComponent("third_party/angle")
    let skia = chromium.appendingPathComponent("third_party/skia")
    let v8 = chromium.appendingPathComponent("v8")
    let dawn = chromium.appendingPathComponent("third_party/dawn")
    let depot = directory.appendingPathComponent("depot_tools")
    let lockFile = directory.appendingPathComponent("source.lock.json")
    let environment = [
        "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        "GIT_AUTHOR_NAME": "Collider Test",
        "GIT_AUTHOR_EMAIL": "collider@example.invalid",
        "GIT_COMMITTER_NAME": "Collider Test",
        "GIT_COMMITTER_EMAIL": "collider@example.invalid",
    ]
    let runtime = ColliderRuntime()
    func git(_ repository: URL) async throws -> (commit: String, tree: String) {
        try FileManager.default.createDirectory(
            at: repository, withIntermediateDirectories: true)
        let marker = repository.appendingPathComponent("marker")
        if !FileManager.default.fileExists(atPath: marker.path) {
            try Data("source".utf8).write(to: marker)
        }
        for arguments in [
            ["init", "-q"],
            ["add", "."],
            ["commit", "-qm", "fixture"],
        ] {
            let result = try await runtime.execute(
                CommandSpec(
                    executable: .named("git"),
                    arguments: arguments,
                    workingDirectory: FilePath(repository.path),
                    environment: environment))
            #expect(result.status == 0)
        }
        let commitResult = try await runtime.execute(
            CommandSpec(
                executable: .named("git"),
                arguments: ["rev-parse", "HEAD"],
                workingDirectory: FilePath(repository.path),
                environment: environment,
                output: .captured(limit: 4_096)))
        let treeResult = try await runtime.execute(
            CommandSpec(
                executable: .named("git"),
                arguments: ["rev-parse", "HEAD^{tree}"],
                workingDirectory: FilePath(repository.path),
                environment: environment,
                output: .captured(limit: 4_096)))
        #expect(commitResult.status == 0)
        #expect(treeResult.status == 0)
        return (
            commitResult.standardOutput.trimmingCharacters(
                in: .whitespacesAndNewlines),
            treeResult.standardOutput.trimmingCharacters(
                in: .whitespacesAndNewlines)
        )
    }
    let cefRevision = try await git(cef)
    let angleRevision = try await git(angle)
    let skiaRevision = try await git(skia)
    let dawnRevision = try await git(dawn)
    let pgoName = "fixture.profdata"
    let pgo = chromium.appendingPathComponent(
        "chrome/build/pgo_profiles/\(pgoName)")
    let pgoDescriptor = chromium.appendingPathComponent(
        "chrome/build/linux.pgo.txt")
    let v8PGO = v8.appendingPathComponent(
        "tools/builtins-pgo/profiles/x64.profile")
    for file in [pgo, pgoDescriptor, v8PGO] {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true)
    }
    try Data("profile".utf8).write(to: pgo)
    try Data("\(pgoName)\n".utf8).write(to: pgoDescriptor)
    try Data("v8 profile".utf8).write(to: v8PGO)
    let v8Revision = try await git(v8)
    let deps = chromium.appendingPathComponent("DEPS")
    try Data("deps fixture".utf8).write(to: deps)
    let chromiumRevision = try await git(chromium)
    let depotRevision = try await git(depot)
    let graph = source.appendingPathComponent("chromium/.gclient_entries")
    try Data("graph fixture".utf8).write(to: graph)
    let repositories = [
        ("chromium", "chromium/src", chromiumRevision),
        ("cef", "chromium/src/cef", cefRevision),
        ("angle", "chromium/src/third_party/angle", angleRevision),
        ("skia", "chromium/src/third_party/skia", skiaRevision),
        ("v8", "chromium/src/v8", v8Revision),
        ("dawn", "chromium/src/third_party/dawn", dawnRevision),
    ].map { name, checkoutPath, revision in
        ChromiumSourceRepository(
            name: name,
            checkoutPath: checkoutPath,
            remote: "https://example.invalid/\(name).git",
            upstreamRemote: "https://upstream.example.invalid/\(name).git",
            upstreamCommit: revision.commit,
            commit: revision.commit,
            tree: revision.tree)
    }
    let sourceLock = ChromiumSourceLock(
        cefBranch: "fixture",
        chromiumVersion: "1.2.3.4",
        repositories: repositories,
        depotTools: ChromiumDepotToolsLock(
            remote: "https://example.invalid/depot_tools.git",
            commit: depotRevision.commit))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(sourceLock).write(to: lockFile)
    let manifest: [String: Any] = [
        "sourceID": sourceID,
        "sourceLockSHA256": try ArtifactHasher.digest(
            file: FilePath(lockFile.path)
        ).description,
        "repositories": repositories.map {
            ["name": $0.name, "commit": $0.commit, "tree": $0.tree]
        },
        "depotToolsCommit": depotRevision.commit,
        "chromiumDEPSSHA256": try ArtifactHasher.digest(
            file: FilePath(deps.path)
        ).description,
        "gclientGraphSHA256": try ArtifactHasher.digest(
            file: FilePath(graph.path)
        ).description,
        "pgo": [
            "name": pgoName,
            "sha256": try ArtifactHasher.digest(
                file: FilePath(pgo.path)
            ).description,
        ],
        "v8BuiltinsPGO": [
            "name": "x64.profile",
            "sha256": try ArtifactHasher.digest(
                file: FilePath(v8PGO.path)
            ).description,
        ],
    ]
    try JSONSerialization.data(
        withJSONObject: manifest,
        options: [.sortedKeys]
    ).write(
        to: source.appendingPathComponent(
            "source-provenance.json"))
    let current = generations.appendingPathComponent("current")
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.prepare-chromium-source"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [
            OutputDeclaration(
                path: FilePath(
                    source.appendingPathComponent(
                        "source-provenance.json"
                    ).path),
                validation: .json)
        ],
        assessmentPolicy: .always,
        operation: .prepareChromiumSource(
            ChromiumSourcePreparation(
                sourceID: sourceID,
                sourceRoot: FilePath(source.path),
                sourceGenerations: FilePath(generations.path),
                current: FilePath(current.path),
                depotTools: FilePath(depot.path),
                sourceLockFile: FilePath(lockFile.path),
                sourceLock: sourceLock,
                environment: environment)))
    _ = try await runtime.execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))
    #expect(
        try FileManager.default.destinationOfSymbolicLink(
            atPath: current.path) == sourceID)
}

@Test func browserArtifactAssemblyPublishesAValidatedImmutableGeneration() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-browser-artifact-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("chromium")
    let output = directory.appendingPathComponent("out")
    let distribution = directory.appendingPathComponent("dist")
    try FileManager.default.createDirectory(
        at: output.appendingPathComponent("locales"),
        withIntermediateDirectories: true)
    let required = [
        "chrome", "chrome_crashpad_handler", "chrome_sandbox",
        "icudtl.dat", "resources.pak", "chrome_100_percent.pak",
        "chrome_200_percent.pak", "v8_context_snapshot.bin",
        "libEGL.so", "libGLESv2.so", "libvulkan.so.1",
    ]
    for name in required {
        try Data(name.utf8).write(
            to: output.appendingPathComponent(name))
    }
    try Data("locale".utf8).write(
        to: output.appendingPathComponent("locales/en-US.pak"))
    let icon = source.appendingPathComponent(
        "chrome/app/theme/chromium/linux/product_logo_128.png")
    try FileManager.default.createDirectory(
        at: icon.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try Data("icon".utf8).write(to: icon)
    let launcher = directory.appendingPathComponent("nucleus-browser")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: launcher)
    let desktop = directory.appendingPathComponent("browser.desktop.in")
    try Data(
        "Exec=@NUCLEUS_BROWSER_LAUNCHER@\n".utf8
    ).write(to: desktop)
    let buildID = "abcdefabcdefabcdefabcdef"
    try JSONSerialization.data(
        withJSONObject: ["buildID": buildID],
        options: [.sortedKeys]
    ).write(
        to: output.appendingPathComponent(
            ".nucleus-built-build.json"))
    let tools = directory.appendingPathComponent("tools")
    try FileManager.default.createDirectory(
        at: tools, withIntermediateDirectories: true)
    let ldd = tools.appendingPathComponent("ldd")
    try Data("#!/bin/sh\nprintf 'all resolved\\n'\n".utf8).write(to: ldd)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: ldd.path)
    let assembly = BrowserArtifactAssembly(
        chromiumSource: FilePath(source.path),
        buildOutput: FilePath(output.path),
        distributionRoot: FilePath(distribution.path),
        launcher: FilePath(launcher.path),
        desktopTemplate: FilePath(desktop.path),
        environment: [
            "PATH": tools.path + ":"
                + (ProcessInfo.processInfo.environment["PATH"]
                    ?? "/usr/bin:/bin")
        ])
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.assemble-browser-artifact"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [
            OutputDeclaration(
                path: FilePath(
                    distribution.appendingPathComponent(
                        "current"
                    ).path),
                validation: .exists)
        ],
        assessmentPolicy: .always,
        operation: .sequence([
            .assembleBrowserArtifact(assembly),
            .validateBrowserArtifact(assembly),
        ]))
    _ = try await ColliderRuntime().execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))
    #expect(
        try FileManager.default.destinationOfSymbolicLink(
            atPath: distribution.appendingPathComponent("current").path)
            == "generations/\(buildID)")
}

@Test func cefArtifactAssemblyPublishesSDKAndChecksummedArchive() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-cef-artifact-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source")
    let chromium = source.appendingPathComponent("chromium/src")
    let output = chromium.appendingPathComponent("out/Release_GN_x64")
    let depot = directory.appendingPathComponent("depot_tools")
    let distribution = directory.appendingPathComponent("dist")
    try FileManager.default.createDirectory(
        at: output, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: depot, withIntermediateDirectories: true)
    let buildID = "1234567890abcdef12345678"
    try JSONSerialization.data(
        withJSONObject: ["buildID": buildID],
        options: [.sortedKeys]
    ).write(
        to: output.appendingPathComponent(
            ".nucleus-built-build.json"))
    let checkout = "abcdefa000000000000000000000000000000000"
    let version = "1.2.3.4"
    let distributor = chromium.appendingPathComponent(
        "cef/tools/make_distrib.py")
    try FileManager.default.createDirectory(
        at: distributor.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try Data(
        """
        import sys
        from pathlib import Path
        output = next(
            argument.split('=', 1)[1]
            for argument in sys.argv
            if argument.startswith('--output-dir=')
        )
        root = Path(output) / (
            'cef_binary_fixture+gabcdefa+chromium-\(version)'
            '_linux64_minimal'
        )
        for path in [
            root / 'Release',
            root / 'Resources',
            root / 'include',
        ]:
            path.mkdir(parents=True, exist_ok=True)
        for relative in [
            'Release/libcef.so',
            'Release/chrome-sandbox',
            'Release/icudtl.dat',
            'include/cef_version_info.h',
            'Resources/resources.pak',
        ]:
            path = root / relative
            path.write_text('fixture')
        """.utf8
    ).write(to: distributor)
    let versionManager = chromium.appendingPathComponent(
        "cef/tools/version_manager.py")
    try FileManager.default.createDirectory(
        at: versionManager.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try Data("raise SystemExit(0)\n".utf8).write(to: versionManager)
    let tools = directory.appendingPathComponent("tools")
    try FileManager.default.createDirectory(
        at: tools, withIntermediateDirectories: true)
    let ldd = tools.appendingPathComponent("ldd")
    try Data("#!/bin/sh\nprintf 'all resolved\\n'\n".utf8).write(to: ldd)
    let cc = tools.appendingPathComponent("cc")
    try Data(
        """
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-o" ]; then
            out="$2"
            break
          fi
          shift
        done
        printf '#!/bin/sh\\nexit 0\\n' > "$out"
        chmod 755 "$out"
        """.utf8
    ).write(to: cc)
    let tar = tools.appendingPathComponent("tar")
    try Data(
        """
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-cf" ]; then
            printf 'deterministic archive fixture' > "$2"
            exit 0
          fi
          shift
        done
        exit 64
        """.utf8
    ).write(to: tar)
    for executable in [ldd, cc, tar] {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path)
    }
    let environment = [
        "PATH": tools.path + ":"
            + (ProcessInfo.processInfo.environment["PATH"]
                ?? "/usr/bin:/bin")
    ]
    let assembly = CEFArtifactAssembly(
        chromiumSource: FilePath(chromium.path),
        buildOutput: FilePath(output.path),
        depotTools: FilePath(depot.path),
        distributionRoot: FilePath(distribution.path),
        cefCheckout: checkout,
        chromiumVersion: version,
        environment: environment)
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.assemble-cef-artifact"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [
            OutputDeclaration(
                path: FilePath(
                    distribution.appendingPathComponent(
                        "current"
                    ).path),
                validation: .exists)
        ],
        assessmentPolicy: .always,
        operation: .sequence([
            .assembleCEFArtifact(assembly),
            .validateCEFArtifact(assembly),
        ]))
    _ = try await ColliderRuntime().execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))
    #expect(
        try FileManager.default.destinationOfSymbolicLink(
            atPath: distribution.appendingPathComponent(
                "current-release"
            ).path) == "releases/\(buildID)")
    let artifactNames = try FileManager.default.contentsOfDirectory(
        atPath: distribution.appendingPathComponent(
            "artifacts-current"
        ).path)
    #expect(
        artifactNames.contains {
            $0.hasSuffix(".tar.gz.sha256")
        })
}

@Test func browserInstallationPublishesOneVersionedPrefixGeneration() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-browser-install-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let distribution = directory.appendingPathComponent("distribution")
    let buildID = "fedcbafedcbafedcbafedcba"
    let artifact = distribution.appendingPathComponent(
        "generations/\(buildID)")
    let runtime = artifact.appendingPathComponent("runtime")
    let widevine = runtime.appendingPathComponent("WidevineCdm")
    try FileManager.default.createDirectory(
        at: widevine.appendingPathComponent(
            "_platform_specific/linux_x64"),
        withIntermediateDirectories: true)
    for (path, value) in [
        (runtime.appendingPathComponent("nucleus-browser-bin"), "browser"),
        (runtime.appendingPathComponent("chrome_sandbox"), "sandbox"),
        (widevine.appendingPathComponent("manifest.json"), "{}"),
        (
            widevine.appendingPathComponent(
                "_platform_specific/linux_x64/libwidevinecdm.so"),
            "widevine"
        ),
    ] {
        try Data(value.utf8).write(to: path)
    }
    let launcher = artifact.appendingPathComponent("bin/nucleus-browser")
    try FileManager.default.createDirectory(
        at: launcher.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: launcher)
    let desktop = artifact.appendingPathComponent(
        "share/applications/dev.nucleus.Browser.desktop.in")
    try FileManager.default.createDirectory(
        at: desktop.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try Data(
        "[Desktop Entry]\nType=Application\n"
            .appending("Exec=@NUCLEUS_BROWSER_LAUNCHER@\n").utf8
    ).write(to: desktop)
    let icon = artifact.appendingPathComponent(
        "share/icons/hicolor/128x128/apps/dev.nucleus.Browser.png")
    try FileManager.default.createDirectory(
        at: icon.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try Data("icon".utf8).write(to: icon)
    try JSONSerialization.data(
        withJSONObject: ["buildID": buildID],
        options: [.sortedKeys]
    ).write(
        to: artifact.appendingPathComponent(
            "nucleus-build-manifest.json"))
    try FileManager.default.createSymbolicLink(
        atPath: distribution.appendingPathComponent("current").path,
        withDestinationPath: "generations/\(buildID)")

    let tools = directory.appendingPathComponent("tools")
    try FileManager.default.createDirectory(
        at: tools, withIntermediateDirectories: true)
    for (name, source) in [
        ("ldd", "#!/bin/sh\nprintf 'all resolved\\n'\n"),
        ("unshare", "#!/bin/sh\nexit 0\n"),
        ("bash", "#!/bin/sh\nexec /bin/bash \"$@\"\n"),
    ] {
        let executable = tools.appendingPathComponent(name)
        try Data(source.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path)
    }
    let prefix = directory.appendingPathComponent("prefix")
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.install-browser"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [
            OutputDeclaration(
                path: FilePath(
                    prefix.appendingPathComponent(
                        "lib/nucleus-browser/current"
                    ).path),
                validation: .exists)
        ],
        assessmentPolicy: .always,
        operation: .installBrowser(
            BrowserInstallation(
                distributionRoot: FilePath(distribution.path),
                prefix: FilePath(prefix.path),
                environment: ["PATH": tools.path])))
    _ = try await ColliderRuntime().execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))
    let current = prefix.appendingPathComponent(
        "lib/nucleus-browser/current")
    let target = try FileManager.default.destinationOfSymbolicLink(
        atPath: current.path)
    #expect(target.hasPrefix("generations/"))
    #expect(
        try FileManager.default.destinationOfSymbolicLink(
            atPath: prefix.appendingPathComponent(
                "bin/nucleus-browser"
            ).path)
            == "../lib/nucleus-browser/current/bin/nucleus-browser")
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
        operation: try fixtureActivateGenerationOperation(
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
        operation: try fixtureActivateGenerationOperation(
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
