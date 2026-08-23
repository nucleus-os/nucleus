import ColliderCore
import ColliderEngine
import ColliderRuntime
import Foundation
import SystemPackage
import Testing

@testable import ColliderSwiftPM

private let fakeSwiftBinPathResponse = """
    scratch=
    query=false
    previous=
    for argument in "$@"; do
      if [ "$previous" = "--scratch-path" ]; then scratch="$argument"; fi
      if [ "$argument" = "--show-bin-path" ]; then query=true; fi
      previous="$argument"
    done
    if [ "$query" = true ]; then
      bin="$scratch/.fixture-bin"
      mkdir -p "$bin"
      printf fixture > "$bin/.fixture"
      printf '%s\n' "$bin"
      exit 0
    fi
    """

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
        ],
        locks: [.checkout("fixture-capacity")])

    let lowered = try SwiftPMLowering().lower([
        AssessedTaskDeclaration(
            task: prerequisite,
            isClean: false),
        AssessedTaskDeclaration(
            task: owner,
            isClean: false),
    ])

    #expect(lowered.count == 1)
    #expect(lowered[0].logicalOwners == [owner.id])
    #expect(lowered[0].prerequisites == [prerequisite.id])
    #expect(lowered[0].task.dependencies == [prerequisite.id])
    #expect(
        lowered[0].task.locks == [
            invocation.lock,
            .checkout("fixture-capacity"),
        ])
}

@Test func aProductBuildDoesNotWaitForAnActionDependingOnAnotherOwner() throws {
    let packageRoot = FilePath("/fixture/package")
    let invocation = SwiftPMInvocation(
        context: SwiftBuildContext(
            packageRoot: packageRoot,
            configuration: .debug,
            target: .host(identity: "arm64-macos"),
            toolchainIdentity: "fixture-toolchain"),
        scratchPath: FilePath("/fixture/scratch"))
    func product(_ name: String) -> SwiftProductRequirement {
        invocation.product(
            package: "fixture",
            product: name,
            packageRoot: packageRoot,
            environment: [:])
    }
    let assembler = TaskDeclaration(
        id: TaskID(rawValue: "fixture.assemble"),
        component: ComponentID(rawValue: "fixture"),
        swiftProducts: [product("Assembler")])
    let publication = TaskDeclaration(
        id: TaskID(rawValue: "fixture.publish"),
        component: ComponentID(rawValue: "fixture"),
        dependencies: [assembler.id])
    let qualifier = TaskDeclaration(
        id: TaskID(rawValue: "fixture.qualify"),
        component: ComponentID(rawValue: "fixture"),
        dependencies: [publication.id],
        swiftProducts: [product("Qualifier")])

    let lowered = try SwiftPMLowering().lower([
        AssessedTaskDeclaration(task: assembler, isClean: false),
        AssessedTaskDeclaration(task: publication, isClean: false),
        AssessedTaskDeclaration(task: qualifier, isClean: false),
    ])

    // One build per product, each owned by the task that asked for it. Neither
    // waits on the publication between them: that action cannot run until the
    // assembler's build has completed, so making it a prerequisite of the
    // qualifier's build would order the two builds behind each other.
    #expect(lowered.count == 2)
    #expect(
        Set(lowered.flatMap(\.logicalOwners)) == [assembler.id, qualifier.id])
    #expect(lowered.allSatisfy { $0.prerequisites.isEmpty })
}

@Test func ociLoweringMaterializesLockedDependenciesOnTheHost() throws {
    let packageRoot = FilePath("/fixture/package")
    let scratch = FilePath("/fixture/scratch")
    let lock = packageRoot.appending("Package.resolved")
    let mirrors = packageRoot.appending(".swiftpm/configuration/mirrors.json")
    var imageBuilder = TaskBuilder(
        id: TaskID(rawValue: "fixture.image"),
        component: ComponentID(rawValue: "fixture"))
    let image: ArtifactReference = try imageBuilder.output(
        "image-id",
        path: FilePath("/fixture/image-id"),
        validation: .regularFile)
    let imageTask = imageBuilder.build()
    let invocation = SwiftPMInvocation(
        context: SwiftBuildContext(
            packageRoot: packageRoot,
            configuration: .release,
            target: .host(identity: "aarch64-unknown-linux-gnu"),
            toolchainIdentity: "fixture-toolchain",
            execution: .oci(
                SwiftPMOCIExecution(
                    executionPlatform: .linuxARM64OCI,
                    artifactTarget: .linuxARM64,
                    image: image,
                    hostname: "fixture",
                    hostWorkingDirectory: packageRoot,
                    mounts: [],
                    hostDependencyCache: FilePath("/fixture/cache"),
                    containerEnvironment: [:]))),
        scratchPath: scratch,
        dependencyLock: lock,
        dependencyConfigurationFiles: [mirrors])
    let owner = TaskBuilder(
        id: TaskID(rawValue: "fixture.product"),
        component: ComponentID(rawValue: "fixture")
    ).build(
        swiftProducts: [
            invocation.product(
                package: "fixture",
                product: "FixtureProduct",
                packageRoot: packageRoot,
                environment: [:])
        ],
        locks: [.checkout("fixture-oci-capacity")])

    let lowered = try SwiftPMLowering().lower([
        AssessedTaskDeclaration(task: imageTask, isClean: false),
        AssessedTaskDeclaration(task: owner, isClean: false),
    ])
    let host = try #require(
        lowered.first {
            $0.task.action?.requirements.executionPlatform == .macOSARM64Native
        })
    let container = try #require(
        lowered.first {
            $0.task.action?.requirements.executionPlatform == .linuxARM64OCI
        })

    #expect(lowered.count == 2)
    #expect(host.task.action?.requirements.networkAccess == .unrestricted)
    #expect(
        container.task.action?.requirements.networkAccess
            == ActionNetworkAccess.none)
    #expect(
        container.task.action?.requirements.effects.contains(
            ActionEffect(.readWrite, scope: .scratch(scratch))) == true)
    #expect(container.prerequisites.contains(host.task.id))
    #expect(host.task.inputs.contains(.file(mirrors)))
    #expect(container.task.inputs.contains(.file(mirrors)))
    #expect(host.task.locks.contains(.checkout("fixture-oci-capacity")))
    #expect(container.task.locks.contains(.checkout("fixture-oci-capacity")))
    let execution = try invocation.ociExecution(
        arguments: ["build"],
        workingDirectory: packageRoot,
        environment: [:])
    #expect(execution.command.contains("--only-use-versions-from-resolved-file"))
}

@Test func loweringConsumesAnArtifactBackedSwiftCompiler() throws {
    let packageRoot = FilePath("/fixture/package")
    var compilerBuilder = TaskBuilder(
        id: TaskID(rawValue: "fixture.swift-compiler"),
        component: ComponentID(rawValue: "fixture"))
    let compiler: ExecutableReference = try compilerBuilder.executableOutput(
        "swift",
        path: FilePath("/fixture/toolchain/bin/swift"))
    let compilerTask = compilerBuilder.build()
    let invocation = SwiftPMInvocation(
        context: SwiftBuildContext(
            packageRoot: packageRoot,
            configuration: .release,
            target: .swiftSDK(
                name: "fixture-android",
                targetTriple: "aarch64-unknown-linux-android24"),
            toolchainIdentity: "fixture-toolchain"),
        scratchPath: FilePath("/fixture/scratch"),
        swiftExecutable: compiler.executable)
    let owner = TaskDeclaration(
        id: TaskID(rawValue: "fixture.android-product"),
        component: ComponentID(rawValue: "fixture"),
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
            task: compilerTask,
            isClean: false),
        AssessedTaskDeclaration(
            task: owner,
            isClean: false),
    ])

    #expect(lowered.count == 1)
    #expect(lowered[0].task.dependencies == [compilerTask.id])
    #expect(lowered[0].prerequisites == [compilerTask.id])
    #expect(lowered[0].task.artifactReferences.count == 1)
    #expect(!lowered[0].task.inputs.contains(.tool(compiler.executable)))
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
        \(fakeSwiftBinPathResponse)
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

@Test func hostSwiftPMDoesNotReceiveTargetSDKSourceIdentities() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-host-swift-environment-\(UUID().uuidString)")
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

    let observedRuntime = directory.appendingPathComponent("runtime-source-identity")
    let observedGenerator = directory.appendingPathComponent("generator-source-identity")
    let swift = tools.appendingPathComponent("swift")
    let script = """
        #!/bin/sh
        set -eu
        \(fakeSwiftBinPathResponse)
        printf '%s' "${NUCLEUS_SWIFT_SOURCE_ID-unset}" > "\(observedRuntime.path)"
        printf '%s' "${NUCLEUS_SWIFT_SDK_GENERATOR_SOURCE_ID-unset}" > "\(observedGenerator.path)"
        mkdir -p "\(scratch.path)"
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
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.host-environment"),
        component: ComponentID(rawValue: "fixture"),
        swiftProducts: [
            SwiftProductRequirement(
                package: "fixture",
                product: "FixtureProduct",
                packageRoot: packageRoot,
                invocation: invocation,
                inputs: [],
                environment: [
                    "PATH": "\(tools.path):/usr/bin:/bin",
                    "NUCLEUS_SWIFT_SOURCE_ID": "target-sdk-source",
                    "NUCLEUS_SWIFT_SDK_GENERATOR_SOURCE_ID": "generator-source",
                ])
        ])

    _ = try await executeWithSwiftPM(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))

    #expect(
        try String(contentsOf: observedRuntime, encoding: .utf8)
            == "unset")
    #expect(
        try String(contentsOf: observedGenerator, encoding: .utf8)
            == "unset")
}

@Test func warmHostBuildStillDelegatesToSwiftPM() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-warm-host-swift-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let package = directory.appendingPathComponent("package")
    let tools = directory.appendingPathComponent("tools")
    let scratch = directory.appendingPathComponent("scratch")
    let commands = directory.appendingPathComponent("commands")
    try FileManager.default.createDirectory(
        at: package, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: tools, withIntermediateDirectories: true)
    try Data("// swift-tools-version: 6.4\n".utf8).write(
        to: package.appendingPathComponent("Package.swift"))
    try commitFixtureCheckout(package)
    let swift = tools.appendingPathComponent("swift")
    let script = """
        #!/bin/sh
        set -eu
        \(fakeSwiftBinPathResponse)
        printf '%s\n' "$1" >> "\(commands.path)"
        mkdir -p "\(scratch.path)"
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
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.warm-host-build"),
        component: ComponentID(rawValue: "fixture"),
        swiftProducts: [
            invocation.product(
                package: "fixture",
                product: "FixtureProduct",
                packageRoot: packageRoot,
                environment: ["PATH": "\(tools.path):/usr/bin:/bin"])
        ])
    let graph = try TaskGraph([task])
    let stateRoot = FilePath(directory.appendingPathComponent("state").path)

    _ = try await executeWithSwiftPM(
        graph: graph,
        selected: [task.id],
        stateRoot: stateRoot)
    _ = try await executeWithSwiftPM(
        graph: graph,
        selected: [task.id],
        stateRoot: stateRoot)

    #expect(
        try String(contentsOf: commands, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init) == ["build", "build"])
}

@Test func synthesizedSwiftBuildNamesEveryProductItBuilds() async throws {
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
        \(fakeSwiftBinPathResponse)
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
    // SwiftPM builds one named product or the whole package, so products
    // sharing a context are built one at a time rather than by an invocation
    // that names none of them and builds everything.
    #expect(received.count == 2)
    #expect(received.allSatisfy { $0.first == "build" })
    #expect(
        received.map { line -> String in
            guard let index = line.firstIndex(of: "--product"),
                line.index(after: index) < line.endIndex
            else { return "" }
            return line[line.index(after: index)]
        }.sorted() == ["FirstProduct", "SecondProduct"])
    #expect(report.swiftPMInvocationCount == 2)
    #expect(report.selectedInputHashingDurationNanoseconds > 0)
    #expect(report.executionDurationNanoseconds > 0)
}

@Test func duplicateProductOwnersRetainExactSwiftPMSelection() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-swift-duplicate-product-\(UUID().uuidString)")
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
    try commitFixtureCheckout(package)

    let arguments = directory.appendingPathComponent("arguments")
    let swift = tools.appendingPathComponent("swift")
    let script = """
        #!/bin/sh
        set -eu
        \(fakeSwiftBinPathResponse)
        printf '%s ' "$@" >> "\(arguments.path)"
        printf '\n' >> "\(arguments.path)"
        mkdir -p "\(scratch.path)"
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
    let tasks = (0..<2).map { index in
        TaskDeclaration(
            id: TaskID(rawValue: "fixture.owner-\(index)"),
            component: ComponentID(rawValue: "fixture"),
            swiftProducts: [
                invocation.product(
                    package: "fixture",
                    product: "SharedProduct",
                    packageRoot: packageRoot,
                    environment: ["PATH": "\(tools.path):/usr/bin:/bin"])
            ])
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
    #expect(Array(received[0].suffix(2)) == ["--product", "SharedProduct"])
    #expect(report.swiftPMInvocationCount == 1)
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
        "#!/bin/sh\nset -eu\n\(fakeSwiftBinPathResponse)\nprintf '%s ' \"$@\" >> '\(arguments.path)'\nprintf '\\n' >> '\(arguments.path)'\nmkdir -p '\(scratch.path)'\n"
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
        "#!/bin/sh\nset -eu\n\(fakeSwiftBinPathResponse)\nprintf '%s ' \"$@\" >> '\(arguments.path)'\nprintf '\\n' >> '\(arguments.path)'\nmkdir -p '\(scratch.path)'\n"
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

@Test func swiftTestDoesNotRequireASeparateBuildTask() async throws {
    func commands(testDeclaresBuildOutput: Bool) async throws -> [String] {
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
            testDeclaresBuildOutput
            ? "mkdir -p \"\(executable.deletingLastPathComponent().path)\"; "
                + "printf test > \"\(executable.path)\"; chmod 755 \"\(executable.path)\""
            : ":"
        let script = """
            #!/bin/sh
            set -eu
            \(fakeSwiftBinPathResponse)
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
            expectedBuildOutputs: testDeclaresBuildOutput ? [output] : [])
        let buildTask = TaskDeclaration(
            id: TaskID(rawValue: "fixture.build"),
            component: ComponentID(rawValue: "fixture"),
            swiftProducts: [product])
        let testTask = TaskDeclaration(
            id: TaskID(rawValue: "fixture.test"),
            component: ComponentID(rawValue: "fixture"),
            swiftTests: [test])

        _ = try await executeWithSwiftPM(
            graph: TaskGraph([buildTask, testTask]),
            selected: [testTask.id],
            stateRoot: FilePath(directory.appendingPathComponent("state").path))
        return try String(contentsOf: arguments, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    #expect(try await commands(testDeclaresBuildOutput: false) == ["test"])
    #expect(try await commands(testDeclaresBuildOutput: true) == ["test"])
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
        "#!/bin/sh\nset -eu\n\(fakeSwiftBinPathResponse)\nprintf '%s\\n' \"$*\" >> \"\(arguments.path)\"\n"
            .utf8
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

@Test func dependencyTaskNameSurvivesRelocatingTheCheckoutAndCache() throws {
    func loweredDependencyTaskID(
        workspace: FilePath,
        cache: FilePath
    ) throws -> TaskID {
        let packageRoot = workspace.appending("package")
        let placement = IdentityPathMap(roots: [
            IdentityPathRoot(name: "workspace", path: workspace),
            IdentityPathRoot(name: "cache", path: cache),
        ])
        var imageBuilder = TaskBuilder(
            id: TaskID(rawValue: "fixture.image"),
            component: ComponentID(rawValue: "fixture"))
        let image: ArtifactReference = try imageBuilder.output(
            "image-id",
            path: cache.appending("image-id"),
            validation: .regularFile)
        let invocation = SwiftPMInvocation(
            context: SwiftBuildContext(
                packageRoot: packageRoot,
                configuration: .release,
                target: .host(identity: "aarch64-unknown-linux-gnu"),
                toolchainIdentity: "fixture-toolchain",
                execution: .oci(
                    SwiftPMOCIExecution(
                        executionPlatform: .linuxARM64OCI,
                        artifactTarget: .linuxARM64,
                        image: image,
                        hostname: "fixture",
                        hostWorkingDirectory: packageRoot,
                        mounts: [],
                        hostDependencyCache: cache.appending("swiftpm"),
                        containerEnvironment: [:])),
                identityPathMap: placement),
            scratchPath: cache.appending("scratch"),
            dependencyLock: packageRoot.appending("Package.resolved"))
        let owner = TaskBuilder(
            id: TaskID(rawValue: "fixture.product"),
            component: ComponentID(rawValue: "fixture")
        ).build(
            swiftProducts: [
                invocation.product(
                    package: "fixture",
                    product: "FixtureProduct",
                    packageRoot: packageRoot,
                    environment: [:])
            ])
        let lowered = try SwiftPMLowering().lower([
            AssessedTaskDeclaration(task: imageBuilder.build(), isClean: false),
            AssessedTaskDeclaration(task: owner, isClean: false),
        ])
        return try #require(
            lowered.first {
                $0.task.action?.requirements.executionPlatform == .macOSARM64Native
            }
        ).task.id
    }

    let authoritative = try loweredDependencyTaskID(
        workspace: FilePath("/Library/Nucleus/checkout"),
        cache: FilePath("/Library/Nucleus/store/cache"))
    let automated = try loweredDependencyTaskID(
        workspace: FilePath("/Users/builder/actions/_work/nucleus/nucleus"),
        cache: FilePath("/Library/Nucleus/store/cache"))

    #expect(authoritative == automated)
}

/// A package Collider builds always lives in a working copy, and its source
/// identity comes from Git rather than from a directory walk. A fixture that
/// executes a real lowering has to be a checkout for the same reason.
private func commitFixtureCheckout(_ package: URL) throws {
    func git(_ arguments: [String]) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = package
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        _ = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
    try git(["init", "--quiet"])
    try git(["config", "user.name", "Collider Tests"])
    try git(["config", "user.email", "collider@example.invalid"])
    try git(["add", "--all"])
    try git(["commit", "--quiet", "--message", "fixture"])
}
