import ColliderCore
import ColliderEngine
import ColliderRuntime
import Foundation
import SystemPackage
import Testing

@testable import ColliderSwiftPM

private func executeWithSwiftPM(
    graph: TaskGraph,
    selected: [TaskID],
    stateRoot: FilePath,
    options: TaskExecutionOptions = TaskExecutionOptions()
) async throws -> TaskExecutionReport {
    try await ColliderEngine(runtime: ColliderRuntime()).execute(
        graph: graph,
        selected: selected,
        stateRoot: stateRoot,
        lowerings: [SwiftPMLowering()],
        options: options)
}

@Test func loweringCarriesLogicalOwnersAndNonSwiftPrerequisites() throws {
    let packageRoot = FilePath("/fixture/package")
    let prerequisite = TaskDeclaration(
        id: TaskID(rawValue: "fixture.generated-input"),
        component: ComponentID(rawValue: "fixture"))
    let invocation = SwiftPMInvocation(
        context: SwiftBuildContext(
            packageRoot: packageRoot,
            configuration: .debug,
            target: .host(identity: "arm64-macos"),
            toolchainIdentity: "fixture-toolchain"),
        scratchPath: FilePath("/fixture/scratch"))
    let owner = TaskDeclaration(
        id: TaskID(rawValue: "fixture.product"),
        component: ComponentID(rawValue: "fixture"),
        dependencies: [prerequisite.id],
        swiftProducts: [
            SwiftProductRequirement(
                package: "fixture",
                product: "FixtureProduct",
                packageRoot: packageRoot,
                invocation: invocation,
                inputs: [],
                environment: [:])
        ])

    let lowered = try SwiftPMLowering().lower([
        AssessedTaskDeclaration(
            task: prerequisite,
            isClean: false,
            isSubsumed: false),
        AssessedTaskDeclaration(
            task: owner,
            isClean: false,
            isSubsumed: false),
    ])

    #expect(lowered.count == 1)
    #expect(lowered[0].logicalOwners == [owner.id])
    #expect(lowered[0].prerequisites == [prerequisite.id])
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
        swiftTests: [requirement])

    _ = try await executeWithSwiftPM(
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
            swiftProducts: [requirement])
    }

    let report = try await executeWithSwiftPM(
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
            ])
    }

    let report = try await executeWithSwiftPM(
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
        swiftProducts: [requirement])

    _ = try await executeWithSwiftPM(
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
            swiftProducts: [product])
        let testTask = TaskDeclaration(
            id: TaskID(rawValue: "fixture.test"),
            component: ComponentID(rawValue: "fixture"),
            dependencies: [buildTask.id],
            subsumedDependencies: [buildTask.id],
            swiftTests: [test])

        _ = try await executeWithSwiftPM(
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
            ])
    }
    _ = try await executeWithSwiftPM(
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
