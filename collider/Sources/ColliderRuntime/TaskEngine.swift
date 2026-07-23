import ColliderCore
import Foundation
import SystemPackage

public struct TaskExecutionOptions: Sendable {
    public var dryRun: Bool
    public var explain: Bool
    public var verbose: Bool
    public var machineReadable: Bool

    public init(
        dryRun: Bool = false,
        explain: Bool = false,
        verbose: Bool = false,
        machineReadable: Bool = false
    ) {
        self.dryRun = dryRun
        self.explain = explain
        self.verbose = verbose
        self.machineReadable = machineReadable
    }
}

public struct TaskPlanEntry: Codable, Sendable {
    public let task: TaskID
    public let identity: ArtifactDigest
    public let isClean: Bool
    public let explanation: String

    public init(
        task: TaskID,
        identity: ArtifactDigest,
        isClean: Bool,
        explanation: String
    ) {
        self.task = task
        self.identity = identity
        self.isClean = isClean
        self.explanation = explanation
    }
}

public struct TaskExecutionReport: Codable, Sendable {
    public let plan: [TaskPlanEntry]
    public let executed: [TaskID]

    public init(plan: [TaskPlanEntry], executed: [TaskID]) {
        self.plan = plan
        self.executed = executed
    }
}

extension ColliderRuntime {
    public func execute(
        graph: TaskGraph,
        selected: [TaskID],
        stateRoot: FilePath,
        workflowLocks: [TaskLock] = [],
        run: RunHandle? = nil,
        registry: RunRegistry? = nil,
        options: TaskExecutionOptions = TaskExecutionOptions()
    ) async throws -> TaskExecutionReport {
        let ordered = try graph.orderedTasks(selecting: selected)
        try FileManager.default.createDirectory(
            atPath: stateRoot.string, withIntermediateDirectories: true)
        let eventRegistry = registry ?? logging?.registry
        let eventRun = run ?? logging?.run
        let workflowHeldLocks: [ColliderFileLock]
        if options.dryRun {
            workflowHeldLocks = []
        } else {
            workflowHeldLocks = try acquireTaskLocks(
                workflowLocks,
                stateRoot: stateRoot,
                run: eventRun,
                purpose: "workflow")
        }
        defer { withExtendedLifetime(workflowHeldLocks) {} }
        var identities: [TaskID: ArtifactDigest] = [:]
        var plan: [TaskPlanEntry] = []
        for task in ordered {
            let dependencyIdentities = try task.dependencies.map {
                guard let identity = identities[$0] else {
                    throw TaskGraphFailure.missing(task: task.id, dependency: $0)
                }
                return identity
            }
            let identity = try identity(of: task, dependencies: dependencyIdentities)
            identities[task.id] = identity
            let assessment = assess(task, identity: identity, stateRoot: stateRoot)
            plan.append(TaskPlanEntry(
                task: task.id, identity: identity,
                isClean: assessment.clean, explanation: assessment.reason))
        }
        if let eventRun, let eventRegistry {
            try await eventRegistry.recordPlan(plan, in: eventRun)
        }
        if options.dryRun {
            return TaskExecutionReport(plan: plan, executed: [])
        }
        if let eventRun, let eventRegistry {
            for entry in plan where entry.isClean {
                try await eventRegistry.record(
                    kind: .taskSkipped,
                    task: entry.task,
                    message: entry.explanation,
                    in: eventRun)
            }
        }
        var executed: [TaskID] = []
        for (index, task) in ordered.enumerated() where !plan[index].isClean {
            let taskStart = ContinuousClock().now
            let heldLocks = try acquireTaskLocks(
                task.locks,
                stateRoot: stateRoot,
                run: eventRun,
                task: task.id,
                purpose: "task")
            defer { withExtendedLifetime(heldLocks) {} }
            if let eventRun, let eventRegistry {
                try await eventRegistry.record(
                    kind: .taskStarted, task: task.id, in: eventRun)
            }
            do {
                try await perform(task, stage: task.id, options: options)
                try validate(task)
                try persist(
                    TaskStateRecord(
                        task: task.id,
                        identity: plan[index].identity,
                        outputs: task.outputs.map { $0.path.string },
                        completedAt: ISO8601DateFormatter().string(from: Date())),
                    stateRoot: stateRoot)
                executed.append(task.id)
                if let eventRun, let eventRegistry {
                    try await eventRegistry.recordTaskDuration(
                        elapsedNanoseconds(since: taskStart),
                        task: task.id,
                        in: eventRun)
                    if case .activateGeneration = task.operation {
                        try await eventRegistry.recordActiveArtifact(
                            plan[index].identity,
                            name: task.component.rawValue,
                            in: eventRun)
                    }
                    try await eventRegistry.record(
                        kind: .taskSucceeded, task: task.id, in: eventRun)
                }
            } catch {
                if let eventRun, let eventRegistry {
                    try? await eventRegistry.recordTaskDuration(
                        elapsedNanoseconds(since: taskStart),
                        task: task.id,
                        in: eventRun)
                    try? await eventRegistry.record(
                        kind: .taskFailed, task: task.id,
                        message: String(describing: error), in: eventRun)
                }
                throw error
            }
        }
        return TaskExecutionReport(plan: plan, executed: executed)
    }

    private func identity(
        of task: TaskDeclaration,
        dependencies: [ArtifactDigest]
    ) throws -> ArtifactDigest {
        var encoder = CanonicalDigestEncoder(schema: task.schemaVersion)
        encoder.append(tag: 1, string: task.id.rawValue)
        encoder.append(tag: 2, string: task.component.rawValue)
        encoder.append(tag: 89, string: task.cachePolicy.rawValue)
        for dependency in dependencies {
            encoder.append(tag: 3, bytes: dependency.bytes)
        }
        for input in task.inputs {
            switch input {
            case .value(let name, let bytes):
                encoder.append(tag: 10, string: name)
                encoder.append(tag: 11, bytes: bytes)
            case .environment(let name, let value):
                encoder.append(tag: 12, string: name)
                encoder.append(tag: 13, string: value ?? "<unset>")
            case .file(let path):
                encoder.append(tag: 14, string: path.string)
                encoder.append(tag: 15, bytes: try ArtifactHasher.digest(file: path).bytes)
            case .tree(let path):
                encoder.append(tag: 16, string: path.string)
                encoder.append(tag: 17, bytes: try ArtifactHasher.digest(tree: path).bytes)
            case .optionalTree(let path, let fallback):
                encoder.append(tag: 72, string: path.string)
                if FileManager.default.fileExists(atPath: path.string) {
                    encoder.append(
                        tag: 73,
                        bytes: try ArtifactHasher.digest(tree: path).bytes)
                } else {
                    encoder.append(tag: 74, bytes: fallback)
                }
            case .dependencyOutput(let path):
                encoder.append(tag: 71, string: path.string)
            case .tool(let executable):
                let tool = try resolvedToolIdentity(
                    executable,
                    environment: operationEnvironment(task.operation))
                encoder.append(tag: 18, string: tool.path.string)
                encoder.append(tag: 19, bytes: tool.digest.bytes)
            }
        }
        for output in task.outputs {
            encoder.append(tag: 40, string: output.path.string)
            encoder.append(tag: 41, string: output.validation.rawValue)
        }
        try encode(operation: task.operation, into: &encoder)
        return ArtifactHasher.digest(bytes: encoder.bytes)
    }

    private func encode(
        operation: TaskOperation,
        into encoder: inout CanonicalDigestEncoder
    ) throws {
        switch operation {
        case .applyGitPatch(let patch):
            let tool = try resolvedToolIdentity(
                .named("git"),
                environment: patch.environment)
            encoder.append(tag: 65, string: patch.repository.string)
            encoder.append(tag: 66, string: patch.patch.string)
            encoder.append(tag: 67, string: tool.path.string)
            encoder.append(tag: 68, bytes: tool.digest.bytes)
            for (name, value) in artifactEnvironment(patch.environment) {
                encoder.append(tag: 69, string: name)
                encoder.append(tag: 70, string: value)
            }
        case .command(let command):
            switch command.executable {
            case .taskOutput(let path):
                encoder.append(tag: 20, string: path.string)
                encoder.append(tag: 47, string: "task-output")
            case .named, .path:
                let tool = try resolvedToolIdentity(
                    command.executable,
                    environment: command.environment)
                encoder.append(tag: 20, string: tool.path.string)
                encoder.append(tag: 42, bytes: tool.digest.bytes)
            }
            for argument in command.arguments { encoder.append(tag: 21, string: argument) }
            encoder.append(tag: 22, string: command.workingDirectory.string)
            for (name, value) in artifactEnvironment(command.environment) {
                encoder.append(tag: 23, string: name)
                encoder.append(tag: 24, string: value)
            }
            switch command.input {
            case .none:
                encoder.append(tag: 52, string: "none")
            case .terminal:
                encoder.append(tag: 52, string: "terminal")
            case .bytes(let bytes):
                encoder.append(tag: 52, string: "bytes")
                encoder.append(tag: 53, bytes: bytes)
            }
            encoder.append(tag: 25, integer: command.timeoutNanoseconds ?? 0)
        case .configureMeson(let setup):
            let tool = try resolvedToolIdentity(
                .named("meson"),
                environment: setup.environment)
            encoder.append(tag: 75, string: setup.source.string)
            encoder.append(tag: 76, string: setup.build.string)
            for argument in setup.arguments {
                encoder.append(tag: 77, string: argument)
            }
            encoder.append(tag: 78, string: tool.path.string)
            encoder.append(tag: 79, bytes: tool.digest.bytes)
            for (name, value) in artifactEnvironment(setup.environment) {
                encoder.append(tag: 80, string: name)
                encoder.append(tag: 81, string: value)
            }
        case .createDirectory(let path):
            encoder.append(tag: 26, string: path.string)
        case .copyFile(let source, let destination):
            encoder.append(tag: 50, string: source.string)
            encoder.append(tag: 51, string: destination.string)
        case .copyMatchingFile(let copy):
            encoder.append(tag: 61, string: copy.searchDirectory.string)
            encoder.append(tag: 62, string: copy.childDirectoryPrefix)
            encoder.append(tag: 63, string: copy.fileName)
            encoder.append(tag: 64, string: copy.destination.string)
        case .mergeStaticArchives(let merge):
            encoder.append(tag: 54, string: merge.sourceRoot.string)
            encoder.append(tag: 55, string: merge.output.string)
            for prefix in merge.excludedFilePrefixes {
                encoder.append(tag: 56, string: prefix)
            }
            for executable in [merge.archiver, merge.indexer] {
                let tool = try resolvedToolIdentity(
                    executable,
                    environment: merge.environment)
                encoder.append(tag: 57, string: tool.path.string)
                encoder.append(tag: 58, bytes: tool.digest.bytes)
            }
            for (name, value) in artifactEnvironment(merge.environment) {
                encoder.append(tag: 59, string: name)
                encoder.append(tag: 60, string: value)
            }
        case .removePath(let path):
            encoder.append(tag: 43, string: path.string)
        case .replaceSymlink(let path, let target):
            encoder.append(tag: 48, string: path.string)
            encoder.append(tag: 49, string: target)
        case .writeFile(let path, let bytes):
            encoder.append(tag: 44, string: path.string)
            encoder.append(tag: 45, bytes: bytes)
        case .syncGitCheckout(let synchronization):
            let tool = try resolvedToolIdentity(
                .named("git"),
                environment: synchronization.environment)
            encoder.append(tag: 118, string: synchronization.repository.string)
            encoder.append(tag: 119, string: synchronization.remote)
            switch synchronization.revision {
            case .branch(let branch):
                encoder.append(tag: 120, string: "branch")
                encoder.append(tag: 121, string: branch)
            case .tag(let tag):
                encoder.append(tag: 120, string: "tag")
                encoder.append(tag: 121, string: tag)
            case .commit(let commit):
                encoder.append(tag: 120, string: "commit")
                encoder.append(tag: 121, string: commit)
            }
            encoder.append(tag: 122, string: tool.path.string)
            encoder.append(tag: 123, bytes: tool.digest.bytes)
            for (name, value) in artifactEnvironment(
                synchronization.environment)
            {
                encoder.append(tag: 124, string: name)
                encoder.append(tag: 125, string: value)
            }
        case .validateGitCheckout(let validation):
            let tool = try resolvedToolIdentity(
                .named("git"),
                environment: validation.environment)
            encoder.append(tag: 82, string: validation.repository.string)
            encoder.append(tag: 83, string: validation.expectedCommit)
            encoder.append(tag: 84, integer: validation.requireClean ? 1 : 0)
            encoder.append(tag: 85, string: tool.path.string)
            encoder.append(tag: 86, bytes: tool.digest.bytes)
            for (name, value) in artifactEnvironment(validation.environment) {
                encoder.append(tag: 87, string: name)
                encoder.append(tag: 88, string: value)
            }
        case .prepareHostToolchainBuild(let preparation):
            encoder.append(tag: 126, string: preparation.workspace.string)
            encoder.append(tag: 127, string: preparation.stagingRoot.string)
            encoder.append(tag: 128, string: preparation.platform.rawValue)
        case .assembleHostToolchain(let assembly):
            encoder.append(tag: 129, string: assembly.workspace.string)
            encoder.append(tag: 130, string: assembly.stagingRoot.string)
            encoder.append(tag: 131, string: assembly.toolchain.string)
            encoder.append(tag: 132, string: assembly.platform.rawValue)
        case .validateHostToolchain(let validation):
            encoder.append(tag: 133, string: validation.toolchain.string)
            encoder.append(tag: 134, string: validation.platform.rawValue)
            encoder.append(tag: 135, string: validation.workDirectory.string)
            for (name, value) in artifactEnvironment(validation.environment) {
                encoder.append(tag: 136, string: name)
                encoder.append(tag: 137, string: value)
            }
        case .assembleAndroidSDK(let assembly):
            encoder.append(tag: 107, string: assembly.toolchain.string)
            encoder.append(tag: 108, string: assembly.installRoot.string)
            encoder.append(tag: 109, string: assembly.bundle.string)
            encoder.append(tag: 110, string: assembly.sourceID)
            for architecture in assembly.architectures {
                encoder.append(tag: 111, string: architecture)
            }
            encoder.append(tag: 112, integer: UInt64(assembly.apiLevel))
        case .validateAndroidRuntimeLinkage(let validation):
            encoder.append(tag: 113, string: validation.installRoot.string)
            encoder.append(tag: 114, string: validation.ndk.string)
            for architecture in validation.architectures {
                encoder.append(tag: 115, string: architecture)
            }
            for (name, value) in artifactEnvironment(validation.environment) {
                encoder.append(tag: 116, string: name)
                encoder.append(tag: 117, string: value)
            }
        case .validateAndroidHost(let validation):
            encoder.append(tag: 138, string: validation.library.string)
            encoder.append(tag: 139, string: validation.kotlinContract.string)
            encoder.append(tag: 140, string: validation.ndk.string)
            encoder.append(
                tag: 141,
                integer: UInt64(validation.minimumSwiftJavaThunkCount))
            for (name, value) in artifactEnvironment(validation.environment) {
                encoder.append(tag: 142, string: name)
                encoder.append(tag: 143, string: value)
            }
        case .wireAndroidSDK(let wiring):
            encoder.append(tag: 90, string: wiring.bundle.string)
            encoder.append(tag: 91, string: wiring.ndk.string)
            encoder.append(
                tag: 92,
                integer: UInt64(wiring.minimumNDKMajorVersion))
        case .validateAndroidSDK(let validation):
            encoder.append(tag: 93, string: validation.toolchain.string)
            encoder.append(tag: 94, string: validation.sdkSearchRoot.string)
            encoder.append(tag: 95, string: validation.bundleName)
            encoder.append(tag: 96, string: validation.ndk.string)
            encoder.append(tag: 97, string: validation.architecture)
            encoder.append(tag: 98, integer: UInt64(validation.apiLevel))
            encoder.append(tag: 99, string: validation.workDirectory.string)
            for (name, value) in artifactEnvironment(validation.environment) {
                encoder.append(tag: 100, string: name)
                encoder.append(tag: 101, string: value)
            }
        case .sanitizeLinkMetadata(let sanitization):
            encoder.append(tag: 102, string: sanitization.root.string)
            for option in sanitization.removedLinkerOptions {
                encoder.append(tag: 103, string: option)
            }
        case .publishSymlink(let publication):
            encoder.append(tag: 104, string: publication.path.string)
            encoder.append(tag: 105, string: publication.target)
            encoder.append(tag: 106, string: publication.displacedItem.string)
        case .publishDirectory(let publication):
            encoder.append(tag: 144, string: publication.prepared.string)
            encoder.append(tag: 145, string: publication.destination.string)
        case .pruneDirectories(let plan):
            encoder.append(tag: 146, string: plan.safetyRoot.string)
            for rule in plan.rules {
                encoder.append(tag: 147, string: rule.root.string)
                encoder.append(tag: 148, string: rule.current?.string ?? "")
                encoder.append(tag: 149, integer: UInt64(rule.retain))
                encoder.append(tag: 150, string: rule.naming.rawValue)
            }
        case .prepareChromiumSource(let preparation):
            for path in [
                preparation.workspace,
                preparation.sourceRoot,
                preparation.sourceGenerations,
                preparation.current,
                preparation.depotTools,
                preparation.automateScript,
            ] {
                encoder.append(tag: 151, string: path.string)
            }
            for value in [
                preparation.sourceID,
                preparation.cefBranch,
                preparation.cefCheckout,
                preparation.chromiumCheckout,
                preparation.depotToolsRevision,
            ] {
                encoder.append(tag: 152, string: value)
            }
            for stack in preparation.patchStacks {
                encoder.append(tag: 153, string: stack.repository.string)
                encoder.append(tag: 154, string: stack.directory.string)
            }
            for (name, value) in artifactEnvironment(
                preparation.environment)
            {
                encoder.append(tag: 155, string: name)
                encoder.append(tag: 156, string: value)
            }
        case .buildChromiumProduct(let build):
            encoder.append(tag: 157, string: build.product.rawValue)
            for path in [
                build.sourceRoot, build.output, build.depotTools,
            ] {
                encoder.append(tag: 158, string: path.string)
            }
            encoder.append(tag: 159, string: build.gnArguments ?? "")
            for target in build.targets {
                encoder.append(tag: 160, string: target)
            }
            encoder.append(tag: 161, integer: UInt64(build.jobs))
            for (name, value) in artifactEnvironment(build.environment) {
                encoder.append(tag: 162, string: name)
                encoder.append(tag: 163, string: value)
            }
        case .assembleBrowserArtifact(let assembly),
             .validateBrowserArtifact(let assembly):
            for path in [
                assembly.chromiumSource,
                assembly.buildOutput,
                assembly.distributionRoot,
                assembly.launcher,
                assembly.desktopTemplate,
            ] {
                encoder.append(tag: 164, string: path.string)
            }
            for (name, value) in artifactEnvironment(
                assembly.environment)
            {
                encoder.append(tag: 165, string: name)
                encoder.append(tag: 166, string: value)
            }
            if case .assembleBrowserArtifact = operation {
                encoder.append(tag: 167, string: "assemble")
            } else {
                encoder.append(tag: 167, string: "validate")
            }
        case .assembleCEFArtifact(let assembly),
             .validateCEFArtifact(let assembly):
            for path in [
                assembly.sourceRoot,
                assembly.chromiumSource,
                assembly.buildOutput,
                assembly.depotTools,
                assembly.distributionRoot,
            ] {
                encoder.append(tag: 168, string: path.string)
            }
            for value in [
                assembly.cefBranch,
                assembly.cefCheckout,
                assembly.chromiumVersion,
            ] {
                encoder.append(tag: 169, string: value)
            }
            for (name, value) in artifactEnvironment(
                assembly.environment)
            {
                encoder.append(tag: 170, string: name)
                encoder.append(tag: 171, string: value)
            }
            if case .assembleCEFArtifact = operation {
                encoder.append(tag: 172, string: "assemble")
            } else {
                encoder.append(tag: 172, string: "validate")
            }
        case .installBrowser(let installation):
            encoder.append(
                tag: 173,
                string: installation.distributionRoot.string)
            encoder.append(tag: 174, string: installation.prefix.string)
            encoder.append(
                tag: 175,
                string: installation.systemSandboxDirectory.string)
            for path in installation.widevineCandidates {
                encoder.append(tag: 176, string: path.string)
            }
            for (name, value) in artifactEnvironment(
                installation.environment)
            {
                encoder.append(tag: 177, string: name)
                encoder.append(tag: 178, string: value)
            }
        case .validateAptPackages(let validation):
            encoder.append(
                tag: 179,
                string: validation.packageList.string)
            for (name, value) in artifactEnvironment(
                validation.environment)
            {
                encoder.append(tag: 180, string: name)
                encoder.append(tag: 181, string: value)
            }
        case .download(let specification, let candidate):
            encoder.append(tag: 27, string: specification.url.absoluteString)
            encoder.append(tag: 28, bytes: specification.expectedDigest.bytes)
            encoder.append(tag: 29, string: candidate.string)
            for origin in specification.permittedRedirectOrigins.sorted() {
                encoder.append(tag: 31, string: origin)
            }
            encoder.append(tag: 32, integer: UInt64(specification.maximumResponseSize))
            for mediaType in specification.acceptedMediaTypes.sorted() {
                encoder.append(tag: 33, string: mediaType.lowercased())
            }
            encoder.append(tag: 34, integer: specification.requestTimeoutSeconds)
            encoder.append(tag: 35, integer: specification.inactivityTimeoutSeconds)
            encoder.append(tag: 36, integer: UInt64(specification.maximumRedirects))
            encoder.append(tag: 37, integer: UInt64(specification.maximumRetries))
            encoder.append(tag: 38, string: specification.resumption.rawValue)
        case .activateGeneration(let candidate, let generation, let active):
            for path in [candidate, generation, active] {
                encoder.append(tag: 30, string: path.string)
            }
        case .sequence(let operations):
            encoder.append(tag: 46, integer: UInt64(operations.count))
            for operation in operations {
                try encode(operation: operation, into: &encoder)
            }
        }
    }

    private func resolvedToolIdentity(
        _ executable: CommandSpec.Executable,
        environment: [String: String]
    ) throws -> (path: FilePath, digest: ArtifactDigest) {
        let cacheKey = String(describing: executable) + "\u{0}"
            + (environment["PATH"] ?? "")
        if let cached = toolIdentityCache[cacheKey] {
            return (cached.0, cached.1)
        }
        let path: FilePath
        switch executable {
        case .path(let value):
            path = value
        case .taskOutput(let value):
            throw RuntimeFailure.invalidOutput(
                "task-produced executable cannot be declared as an external tool: \(value)")
        case .named(let name):
            guard let resolved = resolveExecutable(name, path: environment["PATH"]) else {
                throw RuntimeFailure.toolNotFound(name)
            }
            path = resolved
        }
        let digest = try ArtifactHasher.digest(file: path)
        toolIdentityCache[cacheKey] = (path, digest)
        return (path, digest)
    }

    private func assess(
        _ task: TaskDeclaration,
        identity: ArtifactDigest,
        stateRoot: FilePath
    ) -> (clean: Bool, reason: String) {
        if task.cachePolicy == .always {
            return (false, "task is declared to run every time")
        }
        let path = statePath(task.id, root: stateRoot)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path.string)),
              let record = try? JSONDecoder().decode(TaskStateRecord.self, from: data)
        else { return (false, "no prior task state") }
        guard record.identity == identity else { return (false, "input identity changed") }
        do {
            try validate(task)
            return (true, "identity and outputs are valid")
        } catch {
            return (false, "output validation failed: \(error)")
        }
    }

    private func perform(
        _ task: TaskDeclaration,
        stage: TaskID,
        options: TaskExecutionOptions
    ) async throws {
        try await perform(
            task.operation,
            outputs: task.outputs,
            stage: stage,
            options: options)
    }

    private func perform(
        _ operation: TaskOperation,
        outputs: [OutputDeclaration],
        stage: TaskID,
        options: TaskExecutionOptions
    ) async throws {
        switch operation {
        case .applyGitPatch(let patch):
            func command(_ arguments: [String]) -> CommandSpec {
                CommandSpec(
                    executable: .named("git"),
                    arguments: ["-C", patch.repository.string, "apply"]
                        + arguments + [patch.patch.string],
                    workingDirectory: patch.repository,
                    environment: patch.environment,
                    output: .logged)
            }
            let forwardCheck = try await execute(
                command(["--check"]),
                stage: stage)
            if forwardCheck.status == 0 {
                let application = try await execute(command([]), stage: stage)
                guard application.status == 0 else {
                    throw RuntimeFailure.commandFailed(
                        status: application.status)
                }
            } else {
                let reverseCheck = try await execute(
                    command(["--reverse", "--check"]),
                    stage: stage)
                guard reverseCheck.status == 0 else {
                    throw RuntimeFailure.invalidOutput(
                        "patch is neither applicable nor already applied: "
                            + patch.patch.string)
                }
            }
        case .command(let command):
            if options.verbose {
                let line = rendered(command) + "\n"
                if let logging {
                    try await logging.registry.appendLog(
                        Array(line.utf8),
                        stage: stage,
                        in: logging.run)
                }
                try FileDescriptor.standardError.writeAll(Array(line.utf8))
            }
            let effectiveCommand = options.machineReadable
                ? CommandSpec(
                    executable: command.executable,
                    arguments: command.arguments,
                    workingDirectory: command.workingDirectory,
                    environment: command.environment,
                    input: command.input,
                    output: .logged,
                    timeoutNanoseconds: command.timeoutNanoseconds)
                : command
            let result = try await execute(effectiveCommand, stage: stage)
            guard result.status == 0 else {
                throw RuntimeFailure.commandFailed(status: result.status)
            }
        case .configureMeson(let setup):
            let reconfigure = FileManager.default.fileExists(
                atPath: setup.build.appending("build.ninja").string)
            try await perform(
                .command(CommandSpec(
                    executable: .named("meson"),
                    arguments: ["setup"]
                        + (reconfigure ? ["--reconfigure"] : [])
                        + [setup.build.string, setup.source.string]
                        + setup.arguments,
                    workingDirectory: setup.source,
                    environment: setup.environment)),
                outputs: outputs,
                stage: stage,
                options: options)
        case .createDirectory(let path):
            try FileManager.default.createDirectory(
                atPath: path.string, withIntermediateDirectories: true)
        case .copyFile(let source, let destination):
            try DurableFile.copy(from: source, to: destination)
        case .copyMatchingFile(let copy):
            let candidates = try FileManager.default.contentsOfDirectory(
                atPath: copy.searchDirectory.string)
                .filter { $0.hasPrefix(copy.childDirectoryPrefix) }
                .map {
                    copy.searchDirectory.appending($0).appending(copy.fileName)
                }
                .filter {
                    FileManager.default.fileExists(atPath: $0.string)
                }
                .sorted { $0.string.utf8.lexicographicallyPrecedes($1.string.utf8) }
            guard candidates.count == 1 else {
                throw RuntimeFailure.invalidOutput(
                    "expected one \(copy.fileName) under "
                        + "\(copy.searchDirectory)/\(copy.childDirectoryPrefix)*; found "
                        + (candidates.isEmpty
                            ? "none"
                            : candidates.map(\.string).joined(separator: ", ")))
            }
            try DurableFile.copy(
                from: candidates[0],
                to: copy.destination)
        case .mergeStaticArchives(let merge):
            let archives = try staticArchives(for: merge)
            guard !archives.isEmpty else {
                throw RuntimeFailure.invalidOutput(
                    "no static archives found under \(merge.sourceRoot)")
            }
            if FileManager.default.fileExists(atPath: merge.output.string) {
                try FileManager.default.removeItem(atPath: merge.output.string)
            }
            try FileManager.default.createDirectory(
                atPath: merge.output.removingLastComponent().string,
                withIntermediateDirectories: true)
            let mri = (
                ["create \(merge.output.string)"]
                    + archives.map { "addlib \($0.string)" }
                    + ["save", "end", ""]
            ).joined(separator: "\n")
            try await perform(
                .command(CommandSpec(
                    executable: merge.archiver,
                    arguments: ["-M"],
                    workingDirectory: merge.sourceRoot,
                    environment: merge.environment,
                    input: .bytes(Array(mri.utf8)))),
                outputs: outputs,
                stage: stage,
                options: options)
            try await perform(
                .command(CommandSpec(
                    executable: merge.indexer,
                    arguments: [merge.output.string],
                    workingDirectory: merge.sourceRoot,
                    environment: merge.environment)),
                outputs: outputs,
                stage: stage,
                options: options)
        case .removePath(let path):
            if FileManager.default.fileExists(atPath: path.string)
                || (try? FileManager.default.destinationOfSymbolicLink(
                    atPath: path.string)) != nil
            {
                try FileManager.default.removeItem(atPath: path.string)
            }
        case .replaceSymlink(let path, let target):
            if FileManager.default.fileExists(atPath: path.string)
                || (try? FileManager.default.destinationOfSymbolicLink(
                    atPath: path.string)) != nil
            {
                try FileManager.default.removeItem(atPath: path.string)
            }
            try FileManager.default.createDirectory(
                atPath: path.removingLastComponent().string,
                withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                atPath: path.string,
                withDestinationPath: target)
        case .writeFile(let path, let bytes):
            try DurableFile.write(Data(bytes), to: path)
        case .syncGitCheckout(let synchronization):
            try await syncGitCheckout(synchronization, stage: stage)
        case .validateGitCheckout(let validation):
            func git(_ arguments: [String]) async throws -> CommandResult {
                try await execute(CommandSpec(
                    executable: .named("git"),
                    arguments: ["-C", validation.repository.string]
                        + arguments,
                    workingDirectory: validation.repository,
                    environment: validation.environment,
                    output: .captured(limit: 1_024 * 1_024)),
                    stage: stage)
            }
            let revision = try await git(["rev-parse", "HEAD"])
            let actual = revision.standardOutput.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard revision.status == 0,
                  actual == validation.expectedCommit
            else {
                throw RuntimeFailure.invalidOutput(
                    "\(validation.repository) is at \(actual); expected "
                        + validation.expectedCommit)
            }
            if validation.requireClean {
                let status = try await git(["status", "--porcelain"])
                guard status.status == 0,
                      status.standardOutput.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty
                else {
                    throw RuntimeFailure.invalidOutput(
                    "\(validation.repository) has local changes")
                }
            }
        case .prepareHostToolchainBuild(let preparation):
            try prepareHostToolchainBuild(preparation)
        case .assembleHostToolchain(let assembly):
            try assembleHostToolchain(assembly)
        case .validateHostToolchain(let validation):
            try await validateHostToolchain(validation, stage: stage)
        case .assembleAndroidSDK(let assembly):
            try assembleAndroidSDK(assembly)
        case .validateAndroidRuntimeLinkage(let validation):
            try await validateAndroidRuntimeLinkage(validation, stage: stage)
        case .validateAndroidHost(let validation):
            try await validateAndroidHost(validation, stage: stage)
        case .wireAndroidSDK(let wiring):
            try wireAndroidSDK(wiring)
        case .validateAndroidSDK(let validation):
            try await validateAndroidSDK(validation, stage: stage)
        case .sanitizeLinkMetadata(let sanitization):
            try sanitizeLinkMetadata(sanitization)
        case .publishSymlink(let publication):
            try publishSymlink(publication)
        case .publishDirectory(let publication):
            try DirectoryLifecycle.publish(publication)
        case .pruneDirectories(let plan):
            try DirectoryLifecycle.prune(plan)
        case .prepareChromiumSource(let preparation):
            try await prepareChromiumSource(preparation, stage: stage)
        case .buildChromiumProduct(let build):
            try await buildChromiumProduct(build, stage: stage)
        case .assembleBrowserArtifact(let assembly):
            try await assembleBrowserArtifact(assembly, stage: stage)
        case .validateBrowserArtifact(let assembly):
            try await validateBrowserArtifact(assembly, stage: stage)
        case .assembleCEFArtifact(let assembly):
            try await assembleCEFArtifact(assembly, stage: stage)
        case .validateCEFArtifact(let assembly):
            try await validateCEFArtifact(assembly, stage: stage)
        case .installBrowser(let installation):
            try await installBrowser(installation, stage: stage)
        case .validateAptPackages(let validation):
            try await validateAptPackages(validation, stage: stage)
        case .download(let specification, let candidate):
            try await downloads.download(specification, to: candidate)
        case .activateGeneration(let candidate, let generation, let active):
            let candidateOutputs = outputs.compactMap { output -> OutputDeclaration? in
                let generationPrefix = generation.string.hasSuffix("/")
                    ? generation.string : generation.string + "/"
                if output.path == generation {
                    return OutputDeclaration(path: candidate, validation: output.validation)
                }
                guard output.path.string.hasPrefix(generationPrefix) else { return nil }
                let suffix = String(output.path.string.dropFirst(generationPrefix.count))
                return OutputDeclaration(
                    path: candidate.appending(suffix),
                    validation: output.validation)
            }
            guard !candidateOutputs.isEmpty else {
                throw RuntimeFailure.invalidOutput(
                    "generation task declares no candidate validation under \(generation)")
            }
            try validate(candidateOutputs)
            try GenerationPublisher.publish(
                candidate: candidate,
                generation: generation,
                active: active)
        case .sequence(let operations):
            for operation in operations {
                try await perform(
                    operation,
                    outputs: outputs,
                    stage: stage,
                    options: options)
            }
        }
    }

    private func syncGitCheckout(
        _ synchronization: GitCheckoutSync,
        stage: TaskID
    ) async throws {
        func git(
            _ arguments: [String],
            workingDirectory: FilePath
        ) async throws {
            let result = try await execute(
                CommandSpec(
                    executable: .named("git"),
                    arguments: arguments,
                    workingDirectory: workingDirectory,
                    environment: synchronization.environment),
                stage: stage)
            guard result.status == 0 else {
                throw RuntimeFailure.commandFailed(status: result.status)
            }
        }
        let gitMetadata = synchronization.repository.appending(".git")
        if !FileManager.default.fileExists(atPath: gitMetadata.string) {
            if FileManager.default.fileExists(
                atPath: synchronization.repository.string)
            {
                throw RuntimeFailure.invalidOutput(
                    "refusing to replace non-git checkout "
                        + synchronization.repository.string)
            }
            try FileManager.default.createDirectory(
                atPath: synchronization.repository
                    .removingLastComponent().string,
                withIntermediateDirectories: true)
            try await git(
                [
                    "clone",
                    synchronization.remote,
                    synchronization.repository.string,
                ],
                workingDirectory:
                    synchronization.repository.removingLastComponent())
        }
        switch synchronization.revision {
        case .branch(let branch):
            try await git(
                [
                    "-C", synchronization.repository.string,
                    "fetch", "origin", branch,
                ],
                workingDirectory: synchronization.repository)
            try await git(
                [
                    "-C", synchronization.repository.string,
                    "reset", "--hard", "FETCH_HEAD",
                ],
                workingDirectory: synchronization.repository)
        case .tag(let tag):
            try await git(
                [
                    "-C", synchronization.repository.string,
                    "fetch", "--tags", "origin", tag,
                ],
                workingDirectory: synchronization.repository)
            try await git(
                [
                    "-C", synchronization.repository.string,
                    "reset", "--hard", tag,
                ],
                workingDirectory: synchronization.repository)
        case .commit(let commit):
            try await git(
                [
                    "-C", synchronization.repository.string,
                    "fetch", "--depth", "1", "origin", commit,
                ],
                workingDirectory: synchronization.repository)
            try await git(
                [
                    "-C", synchronization.repository.string,
                    "reset", "--hard", commit,
                ],
                workingDirectory: synchronization.repository)
        }
        try await git(
            [
                "-C", synchronization.repository.string,
                "clean", "-fd",
            ],
            workingDirectory: synchronization.repository)
    }

    private func validateHostToolchain(
        _ validation: HostToolchainValidation,
        stage: TaskID
    ) async throws {
        let executables: [String]
        let products: [String]
        let targets: [String]
        switch validation.platform {
        case .linux:
            executables = [
                "swift", "swiftc", "clang", "clang++", "lldb",
                "lldb-argdumper", "lldb-dap", "lldb-server", "repl_swift",
                "sourcekit-lsp", "swift-format", "docc", "wasmkit",
            ]
            products = [
                "lib/liblldb.so",
                "lib/libIndexStore.so",
                "lib/libSwiftSourceKitClientPlugin.so",
                "lib/libSwiftSourceKitPlugin.so",
                "lib/swift/linux/Foundation.swiftmodule",
                "lib/swift/linux/FoundationEssentials.swiftmodule",
                "lib/swift/linux/FoundationInternationalization.swiftmodule",
                "lib/swift/linux/FoundationNetworking.swiftmodule",
                "lib/swift/linux/FoundationXML.swiftmodule",
                "lib/swift/linux/Dispatch.swiftmodule",
                "lib/swift/linux/libFoundation.so",
                "lib/swift/linux/libdispatch.so",
                "lib/swift_static/linux/Foundation.swiftmodule",
                "lib/swift_static/linux/Dispatch.swiftmodule",
                "lib/swift_static/linux/Glibc.swiftmodule",
                "lib/swift_static/linux/libFoundation.a",
                "lib/swift_static/linux/libdispatch.a",
                "lib/swift/embedded",
                "lib/swift_static/embedded",
                "share/docc/render",
            ]
            targets = [
                "aarch64", "arm", "avr", "bpf", "mips", "ppc32",
                "riscv32", "systemz", "wasm32", "x86",
            ]
        case .macOS:
            executables = [
                "swift", "swiftc", "swift-frontend", "clang", "lldb",
                "lldb-argdumper", "lldb-dap", "lldb-server", "repl_swift",
                "sourcekit-lsp", "swift-format", "docc", "wasmkit",
            ]
            products = [
                "lib/libIndexStore.dylib",
                "lib/libSwiftSourceKitClientPlugin.dylib",
                "lib/libSwiftSourceKitPlugin.dylib",
                "lib/swift/macosx",
                "lib/swift/iphoneos",
                "lib/swift/iphonesimulator",
                "lib/swift/appletvos",
                "lib/swift/appletvsimulator",
                "lib/swift/watchos",
                "lib/swift/watchsimulator",
                "lib/swift/xros",
                "lib/swift/xrsimulator",
                "lib/swift/embedded",
                "share/docc/render",
            ]
            targets = ["aarch64", "arm", "wasm32", "x86"]
        }
        for executable in executables {
            let path = validation.toolchain.appending("bin/\(executable)")
            guard FileManager.default.isExecutableFile(atPath: path.string) else {
                throw RuntimeFailure.invalidOutput(
                    "host toolchain executable is missing: \(path)")
            }
        }
        for product in products {
            let path = validation.toolchain.appending(product)
            guard FileManager.default.fileExists(atPath: path.string) else {
                throw RuntimeFailure.invalidOutput(
                    "host toolchain product is missing: \(path)")
            }
        }
        try removeExisting(validation.workDirectory)
        try FileManager.default.createDirectory(
            atPath: validation.workDirectory.string,
            withIntermediateDirectories: true)
        let home = validation.workDirectory.appending("home")
        let temporary = validation.workDirectory.appending("tmp")
        try FileManager.default.createDirectory(
            atPath: home.string, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: temporary.string, withIntermediateDirectories: true)
        var environment = validation.environment
        environment["HOME"] = home.string
        environment["TMPDIR"] = temporary.string
        environment["USER"] = environment["USER"] ?? "nucleus"
        environment["PATH"] = validation.toolchain.appending("bin").string
            + ":/usr/bin:/bin"
        environment["SWIFT_EXEC"] = validation.toolchain.appending(
            "bin/swiftc").string
        environment["SOURCEKIT_TOOLCHAIN_PATH"] = validation.toolchain.string
        let commandEnvironment = environment

        func checked(
            _ executable: String,
            _ arguments: [String],
            directory: FilePath? = nil,
            output: CommandSpec.Output = .logged
        ) async throws -> CommandResult {
            let result = try await execute(
                CommandSpec(
                    executable: .path(validation.toolchain.appending(
                        "bin/\(executable)")),
                    arguments: arguments,
                    workingDirectory: directory ?? validation.workDirectory,
                    environment: commandEnvironment,
                    output: output),
                stage: stage)
            guard result.status == 0 else {
                throw RuntimeFailure.commandFailed(status: result.status)
            }
            return result
        }
        let clang = validation.toolchain.appending("bin/clang")
        let targetOutput = try await execute(
            CommandSpec(
                executable: .path(clang),
                arguments: ["--print-targets"],
                workingDirectory: validation.toolchain,
                environment: commandEnvironment,
                output: .captured(limit: 4 * 1_024 * 1_024)),
            stage: stage)
        guard targetOutput.status == 0 else {
            throw RuntimeFailure.commandFailed(status: targetOutput.status)
        }
        for target in targets where
            !targetOutput.standardOutput.split(separator: "\n").contains(
                where: {
                    $0.trimmingCharacters(in: .whitespaces)
                        .hasPrefix(target + " ")
                })
        {
            throw RuntimeFailure.invalidOutput(
                "host Clang is missing LLVM target \(target)")
        }
        let source = validation.workDirectory.appending("smoke.swift")
        let binary = validation.workDirectory.appending("smoke")
        try DurableFile.write(
            Data(hostToolchainSmokeSource.utf8),
            to: source)
        let compile = try await execute(
            CommandSpec(
                executable: .path(validation.toolchain.appending("bin/swiftc")),
                arguments: [
                    "-parse-as-library", source.string, "-o", binary.string,
                ],
                workingDirectory: validation.workDirectory,
                environment: commandEnvironment),
            stage: stage)
        guard compile.status == 0 else {
            throw RuntimeFailure.commandFailed(status: compile.status)
        }
        let run = try await execute(
            CommandSpec(
                executable: .path(binary),
                arguments: [],
                workingDirectory: validation.workDirectory,
                environment: commandEnvironment),
            stage: stage)
        guard run.status == 0 else {
            throw RuntimeFailure.commandFailed(status: run.status)
        }
        for (executable, arguments) in [
            ("sourcekit-lsp", ["--help"]),
            ("swift-format", ["--version"]),
            ("docc", ["--help"]),
            ("wasmkit", ["--version"]),
        ] {
            let result = try await checked(
                executable,
                arguments,
                output: .combined(limit: 4 * 1_024 * 1_024))
            guard !result.standardOutput.isEmpty else {
                throw RuntimeFailure.invalidOutput(
                    "\(executable) produced no version/help output")
            }
        }

        let formatSource = validation.workDirectory.appending(
            "format/Unformatted.swift")
        try DurableFile.write(
            Data("struct Example{let value:Int}\n".utf8),
            to: formatSource)
        _ = try await checked(
            "swift-format",
            ["format", "--in-place", formatSource.string])
        let formatted = try String(
            contentsOfFile: formatSource.string,
            encoding: .utf8)
        guard formatted.contains("struct Example {"),
              formatted.contains("let value: Int")
        else {
            throw RuntimeFailure.invalidOutput(
                "swift-format did not format the validation source")
        }
        _ = try await checked(
            "swift-format",
            ["lint", "--strict", formatSource.string])

        let catalog = validation.workDirectory.appending(
            "docc/NucleusSmoke.docc")
        let archive = validation.workDirectory.appending(
            "docc/NucleusSmoke.doccarchive")
        try DurableFile.write(
            Data(
                "# Nucleus Smoke\n\nA functional Swift-DocC conversion test.\n"
                    .utf8),
            to: catalog.appending("NucleusSmoke.md"))
        _ = try await checked(
            "docc",
            [
                "convert", catalog.string,
                "--fallback-display-name", "Nucleus Smoke",
                "--fallback-bundle-identifier",
                "org.nucleustos.toolchain-smoke",
                "--fallback-bundle-version", "1",
                "--output-path", archive.string,
            ])
        guard isRegularFile(archive.appending("index.html")),
              isDirectory(archive.appending("data"))
        else {
            throw RuntimeFailure.invalidOutput(
                "DocC did not emit a valid documentation archive")
        }

        let wasm = validation.workDirectory.appending("wasmkit/empty.wasm")
        try DurableFile.write(
            Data([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]),
            to: wasm)
        _ = try await checked("wasmkit", ["run", wasm.string])
        let cxxPackage = validation.workDirectory.appending(
            "cxx-interop-test-runner")
        try DurableFile.write(
            Data(hostCXXTestManifest.utf8),
            to: cxxPackage.appending("Package.swift"))
        try DurableFile.write(
            Data(
                "public struct Example { public init() {} }\n".utf8),
            to: cxxPackage.appending("Sources/Example/Example.swift"))
        try DurableFile.write(
            Data(hostCXXTestSource.utf8),
            to: cxxPackage.appending(
                "Tests/ExampleTests/ExampleTests.swift"))
        _ = try await checked(
            "swift",
            ["test", "--package-path", cxxPackage.string],
            directory: cxxPackage)

        let lspPackage = validation.workDirectory.appending(
            "sourcekit-lsp/NucleusLSPPackage")
        try DurableFile.write(
            Data(hostLSPManifest.utf8),
            to: lspPackage.appending("Package.swift"))
        try DurableFile.write(
            Data(hostLSPLibrary.utf8),
            to: lspPackage.appending("Sources/Greeter/Greeter.swift"))
        try DurableFile.write(
            Data(hostLSPApplication.utf8),
            to: lspPackage.appending("Sources/App/main.swift"))
        _ = try await checked(
            "swift",
            ["build", "--package-path", lspPackage.string],
            directory: lspPackage)
        let library = lspPackage.appending(
            "Sources/Greeter/Greeter.swift")
        let rootURI = URL(fileURLWithPath: lspPackage.string).absoluteString
        let libraryURI = URL(fileURLWithPath: library.string).absoluteString
        let lspInput = try jsonRPCPayload([
            [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "processId": ProcessInfo.processInfo.processIdentifier,
                    "rootUri": rootURI,
                    "workspaceFolders": [
                        ["uri": rootURI, "name": "NucleusLSPPackage"],
                    ],
                    "capabilities": [
                        "textDocument": ["documentSymbol": [:]],
                    ],
                ],
            ],
            [
                "jsonrpc": "2.0",
                "method": "initialized",
                "params": [:],
            ],
            [
                "jsonrpc": "2.0",
                "method": "textDocument/didOpen",
                "params": [
                    "textDocument": [
                        "uri": libraryURI,
                        "languageId": "swift",
                        "version": 1,
                        "text": hostLSPLibrary,
                    ],
                ],
            ],
            [
                "jsonrpc": "2.0",
                "id": 2,
                "method": "textDocument/documentSymbol",
                "params": [
                    "textDocument": ["uri": libraryURI],
                ],
            ],
            [
                "jsonrpc": "2.0",
                "id": 3,
                "method": "shutdown",
                "params": [:],
            ],
            [
                "jsonrpc": "2.0",
                "method": "exit",
                "params": [:],
            ],
        ])
        let lsp = try await execute(
            CommandSpec(
                executable: .path(validation.toolchain.appending(
                    "bin/sourcekit-lsp")),
                arguments: [],
                workingDirectory: lspPackage,
                environment: commandEnvironment,
                input: .bytes(lspInput),
                output: .captured(limit: 16 * 1_024 * 1_024),
                timeoutNanoseconds: 120_000_000_000),
            stage: stage)
        guard lsp.status == 0 else {
            throw RuntimeFailure.commandFailed(status: lsp.status)
        }
        let messages = try jsonRPCMessages(lsp.standardOutput)
        guard messages.contains(where: {
            ($0["id"] as? Int) == 1 && $0["result"] != nil
        }),
        messages.contains(where: {
            ($0["id"] as? Int) == 2
                && (($0["result"] as? [Any])?.isEmpty == false)
        })
        else {
            throw RuntimeFailure.invalidOutput(
                "SourceKit-LSP did not return initialize and document symbols")
        }
        try FileManager.default.removeItem(
            atPath: validation.workDirectory.string)
    }

    private func validateAndroidSDK(
        _ validation: AndroidSDKValidation,
        stage: TaskID
    ) async throws {
        let targetMachine: String
        switch validation.architecture {
        case "aarch64":
            targetMachine = "AArch64"
        case "x86_64":
            targetMachine = "Advanced Micro Devices X86-64"
        default:
            throw RuntimeFailure.invalidOutput(
                "unsupported Android SDK validation architecture "
                    + validation.architecture)
        }
        let bundle = validation.sdkSearchRoot.appending(validation.bundleName)
        guard isDirectory(bundle) else {
            throw RuntimeFailure.invalidOutput(
                "Android Swift SDK bundle is missing: \(bundle)")
        }
        let swift = validation.toolchain.appending("bin/swift")
        guard FileManager.default.isExecutableFile(atPath: swift.string) else {
            throw RuntimeFailure.invalidOutput(
                "Swift executable is missing: \(swift)")
        }
        let readelf = try androidNDKReadELF(validation.ndk)
        let triple = validation.architecture
            + "-unknown-linux-android\(validation.apiLevel)"
        try removeExisting(validation.workDirectory)
        try FileManager.default.createDirectory(
            atPath: validation.workDirectory.string,
            withIntermediateDirectories: true)
        var succeeded = false
        defer {
            if succeeded {
                try? FileManager.default.removeItem(
                    atPath: validation.workDirectory.string)
            }
        }

        try DurableFile.write(
            Data(androidSDKConsumerManifest.utf8),
            to: validation.workDirectory.appending("Package.swift"))
        try DurableFile.write(
            Data(androidSDKConsumerSource.utf8),
            to: validation.workDirectory.appending("Sources/hello/hello.swift"))
        try DurableFile.write(
            Data(androidSDKConsumerPlugin.utf8),
            to: validation.workDirectory.appending(
                "Plugins/FoundationXMLHostPlugin/plugin.swift"))

        var environment = validation.environment
        environment["ANDROID_NDK_HOME"] = validation.ndk.string
        for mode in ["dynamic", "static"] {
            let build = validation.workDirectory.appending(".build-\(mode)")
            var arguments = [
                "build",
                "--package-path", validation.workDirectory.string,
                "--build-path", build.string,
                "--swift-sdks-path", validation.sdkSearchRoot.string,
                "--swift-sdk", triple,
            ]
            if mode == "static" {
                arguments.append("--static-swift-stdlib")
            }
            let result = try await execute(
                CommandSpec(
                    executable: .path(swift),
                    arguments: arguments,
                    workingDirectory: validation.workDirectory,
                    environment: environment),
                stage: stage)
            guard result.status == 0 else {
                throw RuntimeFailure.commandFailed(status: result.status)
            }
            let binary = try singleExecutable(named: "hello", under: build)
            let header = try await execute(
                CommandSpec(
                    executable: .path(readelf),
                    arguments: ["-h", binary.string],
                    workingDirectory: validation.workDirectory,
                    environment: environment,
                    output: .captured(limit: 1_024 * 1_024)),
                stage: stage)
            guard header.status == 0,
                  header.standardOutput.contains("Machine:"),
                  header.standardOutput.contains(targetMachine)
            else {
                throw RuntimeFailure.invalidOutput(
                    "\(mode) Android consumer has the wrong machine type: \(binary)")
            }
            _ = try singleExecutable(
                named: "FoundationXMLHostPlugin",
                under: build)
        }
        succeeded = true
    }

    private func validateAndroidRuntimeLinkage(
        _ validation: AndroidRuntimeLinkageValidation,
        stage: TaskID
    ) async throws {
        let readelf = try androidNDKReadELF(validation.ndk)
        let nm = readelf.removingLastComponent().appending("llvm-nm")
        guard FileManager.default.isExecutableFile(atPath: nm.string) else {
            throw RuntimeFailure.invalidOutput(
                "Android NDK llvm-nm is missing: \(nm)")
        }
        for architecture in validation.architectures {
            let library = validation.installRoot.appending(
                "install-\(architecture)/usr/lib/swift/android/libswiftCore.so")
            guard isRegularFile(library) else {
                throw RuntimeFailure.invalidOutput(
                    "Android libswiftCore is missing: \(library)")
            }
            let dynamic = try await execute(
                CommandSpec(
                    executable: .path(readelf),
                    arguments: ["-d", library.string],
                    workingDirectory: validation.installRoot,
                    environment: validation.environment,
                    output: .captured(limit: 4 * 1_024 * 1_024)),
                stage: stage)
            guard dynamic.status == 0,
                  dynamic.standardOutput.contains(
                    "Shared library: [libc++_shared.so]"),
                  !dynamic.standardOutput.contains(
                    "Shared library: [libstdc++")
            else {
                throw RuntimeFailure.invalidOutput(
                    "Android libswiftCore has an invalid C++ runtime dependency: "
                        + library.string)
            }
            let symbols = try await execute(
                CommandSpec(
                    executable: .path(nm),
                    arguments: ["--dynamic", "--demangle", library.string],
                    workingDirectory: validation.installRoot,
                    environment: validation.environment,
                    output: .captured(limit: 32 * 1_024 * 1_024)),
                stage: stage)
            guard symbols.status == 0,
                  !symbols.standardOutput.contains("std::__cxx11::")
            else {
                throw RuntimeFailure.invalidOutput(
                    "Android libswiftCore contains libstdc++ ABI symbols: "
                        + library.string)
            }
        }
    }

    private func validateAndroidHost(
        _ validation: AndroidHostValidation,
        stage: TaskID
    ) async throws {
        guard isRegularFile(validation.library) else {
            throw RuntimeFailure.invalidOutput(
                "Android host library is missing: \(validation.library)")
        }
        guard isRegularFile(validation.kotlinContract) else {
            throw RuntimeFailure.invalidOutput(
                "Android Kotlin JNI contract is missing: "
                    + validation.kotlinContract.string)
        }
        let readelf = try androidNDKReadELF(validation.ndk)
        func inspect(_ arguments: [String]) async throws -> String {
            let result = try await execute(
                CommandSpec(
                    executable: .path(readelf),
                    arguments: arguments + [validation.library.string],
                    workingDirectory: validation.library.removingLastComponent(),
                    environment: validation.environment,
                    output: .captured(limit: 64 * 1_024 * 1_024)),
                stage: stage)
            guard result.status == 0 else {
                throw RuntimeFailure.commandFailed(status: result.status)
            }
            return result.standardOutput
        }
        let header = try await inspect(["-h"])
        let dynamic = try await inspect(["-d"])
        let symbols = try await inspect(["-Ws"])
        var failures: [String] = []
        func require(_ condition: Bool, _ description: String) {
            if !condition { failures.append(description) }
        }
        require(header.contains("Machine:") && header.contains("AArch64"),
                "ELF machine is not AArch64")
        for library in ["libandroid.so", "libvulkan.so", "libSwiftJava.so"] {
            require(dynamic.contains("[\(library)]"),
                    "missing dynamic dependency \(library)")
        }
        require(!dynamic.contains("[libswiftCore.so]"),
                "must not link libswiftCore.so")
        require(symbols.contains("JNI_OnLoad"), "missing JNI_OnLoad export")
        let staticRuntimePattern =
            #"\sFUNC\s+LOCAL\s+PROTECTED\s+\d+\s+swift_retain(?:\s|$)"#
        require(
            symbols.range(
                of: staticRuntimePattern,
                options: .regularExpression) != nil,
            "missing static Swift runtime")

        let source = try String(
            contentsOf: URL(
                fileURLWithPath: validation.kotlinContract.string),
            encoding: .utf8)
        let expression = try NSRegularExpression(
            pattern: #"external\s+fun\s+([A-Za-z0-9_]+)"#)
        let range = NSRange(source.startIndex..., in: source)
        let functions = expression.matches(
            in: source, range: range).compactMap { match -> String? in
                guard let value = Range(match.range(at: 1), in: source) else {
                    return nil
                }
                return String(source[value])
            }
        require(!functions.isEmpty, "Kotlin contract declares no external functions")
        for function in functions {
            require(
                symbols.contains(
                    "Java_dev_nucleus_android_NucleusNative_\(function)"),
                "missing JNI export for NucleusNative.\(function)")
        }
        let thunkCount = symbols.components(
            separatedBy: "Java_dev_nucleus_android_AndroidHost__").count - 1
        require(
            thunkCount >= Int(validation.minimumSwiftJavaThunkCount),
            "found \(thunkCount) swift-java AndroidHost thunks; expected at least "
                + "\(validation.minimumSwiftJavaThunkCount)")
        guard failures.isEmpty else {
            throw RuntimeFailure.invalidOutput(
                "Android host validation failed:\n  "
                    + failures.joined(separator: "\n  "))
        }
    }

    private func validate(_ outputs: [OutputDeclaration]) throws {
        for output in outputs {
            let metadata = try output.path.stat(followTargetSymlink: false)
            switch output.validation {
            case .exists: break
            case .regularFile, .json:
                guard metadata.type == .regular else {
                    throw RuntimeFailure.invalidOutput(output.path.string)
                }
                if output.validation == .json {
                    _ = try JSONSerialization.jsonObject(
                        with: Data(contentsOf: URL(fileURLWithPath: output.path.string)))
                }
            case .executableFile:
                guard metadata.type == .regular,
                      metadata.permissions.contains(.ownerExecute)
                else { throw RuntimeFailure.invalidOutput(output.path.string) }
            case .nonEmptyDirectory:
                guard metadata.type == .directory,
                      !(try FileManager.default.contentsOfDirectory(
                        atPath: output.path.string)).isEmpty
                else { throw RuntimeFailure.invalidOutput(output.path.string) }
            }
        }
    }

    private func validate(_ task: TaskDeclaration) throws {
        try validate(task.outputs)
        try validateArtifactOutputs(task.operation)
    }

    private func validateArtifactOutputs(_ operation: TaskOperation) throws {
        switch operation {
        case .download(let specification, let candidate):
            let actual = try ArtifactHasher.digest(file: candidate)
            guard actual == specification.expectedDigest else {
                throw RuntimeFailure.invalidOutput(
                    "download digest mismatch for \(candidate): expected "
                        + "\(specification.expectedDigest), got \(actual)")
            }
        case .sequence(let operations):
            for operation in operations {
                try validateArtifactOutputs(operation)
            }
        default:
            break
        }
    }

    private func persist(_ record: TaskStateRecord, stateRoot: FilePath) throws {
        let path = statePath(record.task, root: stateRoot)
        try DurableFile.writeJSON(record, to: path)
    }
}

private func artifactEnvironment(
    _ environment: [String: String]
) -> [(key: String, value: String)] {
    let volatile = Set([
        "NUCLEUS_RUN_DIR",
        "NUCLEUS_RUN_LOG",
        "TERM",
    ])
    return environment
        .filter { !volatile.contains($0.key) }
        .sorted { $0.key < $1.key }
}

private func rendered(_ command: CommandSpec) -> String {
    let executable = switch command.executable {
    case .named(let name): name
    case .path(let path): path.string
    case .taskOutput(let path): path.string
    }
    return ([executable] + command.arguments).map { argument in
        if argument.isEmpty { return "''" }
        if argument.allSatisfy({ $0.isLetter || $0.isNumber || "-._/:=+".contains($0) }) {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }.joined(separator: " ")
}

private func elapsedNanoseconds(
    since start: ContinuousClock.Instant
) -> UInt64 {
    let components = start.duration(to: ContinuousClock().now).components
    let seconds = UInt64(max(0, components.seconds))
    let nanoseconds = UInt64(max(0, components.attoseconds / 1_000_000_000))
    return seconds &* 1_000_000_000 &+ nanoseconds
}

public enum RuntimeFailure: Error, CustomStringConvertible, Sendable {
    case commandFailed(status: Int32)
    case invalidOutput(String)
    case toolNotFound(String)
    case outputLimitExceeded(Int)

    public var description: String {
        switch self {
        case .commandFailed(let status): "child command failed with status \(status)"
        case .invalidOutput(let path): "task produced an invalid output at \(path)"
        case .toolNotFound(let name): "declared task tool '\(name)' was not found"
        case .outputLimitExceeded(let limit): "captured output exceeded \(limit) bytes"
        }
    }
}

private func operationEnvironment(_ operation: TaskOperation) -> [String: String] {
    switch operation {
    case .applyGitPatch(let patch):
        patch.environment
    case .command(let command):
        command.environment
    case .configureMeson(let setup):
        setup.environment
    case .mergeStaticArchives(let merge):
        merge.environment
    case .syncGitCheckout(let synchronization):
        synchronization.environment
    case .validateGitCheckout(let validation):
        validation.environment
    case .prepareHostToolchainBuild, .assembleHostToolchain:
        [:]
    case .validateHostToolchain(let validation):
        validation.environment
    case .assembleAndroidSDK:
        [:]
    case .validateAndroidRuntimeLinkage(let validation):
        validation.environment
    case .validateAndroidHost(let validation):
        validation.environment
    case .wireAndroidSDK:
        [:]
    case .validateAndroidSDK(let validation):
        validation.environment
    case .sanitizeLinkMetadata:
        [:]
    case .publishSymlink:
        [:]
    case .publishDirectory, .pruneDirectories:
        [:]
    case .prepareChromiumSource(let preparation):
        preparation.environment
    case .buildChromiumProduct(let build):
        build.environment
    case .assembleBrowserArtifact(let assembly),
         .validateBrowserArtifact(let assembly):
        assembly.environment
    case .assembleCEFArtifact(let assembly),
         .validateCEFArtifact(let assembly):
        assembly.environment
    case .installBrowser(let installation):
        installation.environment
    case .validateAptPackages(let validation):
        validation.environment
    case .sequence(let operations):
        operations.lazy.map(operationEnvironment).first(where: { !$0.isEmpty }) ?? [:]
    default:
        [:]
    }
}

private func prepareHostToolchainBuild(
    _ preparation: HostToolchainBuildPreparation
) throws {
    try removeExisting(preparation.stagingRoot)
    try FileManager.default.createDirectory(
        atPath: preparation.stagingRoot.string,
        withIntermediateDirectories: true)
    try DurableFile.write(
        Data("schema=3\n".utf8),
        to: preparation.stagingRoot.appending(".nucleus-owned"))
    guard preparation.platform == .linux else { return }
    let llvmLibrary = preparation.workspace.appending(
        "build/buildbot_linux/llvm-linux-x86_64/lib")
    let buildSwiftLibrary = preparation.workspace.appending(
        "build/buildbot_linux/swift-linux-x86_64/lib/swift/linux")
    let installSwiftLibrary = preparation.stagingRoot.appending(
        "usr/lib/swift/linux")
    try FileManager.default.createDirectory(
        atPath: buildSwiftLibrary.string,
        withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        atPath: installSwiftLibrary.string,
        withIntermediateDirectories: true)
    for library in [
        "libc++.so", "libc++.so.1", "libc++.so.1.0",
        "libc++abi.so", "libc++abi.so.1", "libc++abi.so.1.0",
        "libunwind.so", "libunwind.so.1", "libunwind.so.1.0",
    ] {
        try replaceSymlink(
            llvmLibrary.appending(library).string,
            at: buildSwiftLibrary.appending(library))
        try replaceSymlink(
            "../../\(library)",
            at: installSwiftLibrary.appending(library))
    }
    let compilerConfiguration = """
    -L<CFGDIR>/../lib

    """
    for name in ["clang.cfg", "clang++.cfg"] {
        try DurableFile.write(
            Data(compilerConfiguration.utf8),
            to: preparation.stagingRoot.appending("usr/bin/\(name)"))
    }
}

private func assembleHostToolchain(
    _ assembly: HostToolchainAssembly
) throws {
    let staged = assembly.stagingRoot.appending("usr")
    guard isDirectory(staged) else {
        throw RuntimeFailure.invalidOutput(
            "upstream Swift build did not produce \(staged)")
    }
    try removeExisting(assembly.toolchain)
    try FileManager.default.createDirectory(
        atPath: assembly.toolchain.removingLastComponent().string,
        withIntermediateDirectories: true)
    try FileManager.default.moveItem(
        atPath: staged.string,
        toPath: assembly.toolchain.string)
    try? FileManager.default.removeItem(
        atPath: assembly.stagingRoot.appending(".nucleus-owned").string)
    guard assembly.platform == .linux else { return }

    let library = assembly.toolchain.appending("lib")
    let cfxmlStatic = library.appending(
        "swift_static/linux/lib_CFXMLInterface.a")
    guard isRegularFile(cfxmlStatic) else {
        throw RuntimeFailure.invalidOutput(
            "host FoundationXML support archive is missing: \(cfxmlStatic)")
    }
    try copyReplacing(
        from: cfxmlStatic,
        to: library.appending("swift/linux/lib_CFXMLInterface.a"))
    let staticArguments = library.appending(
        "swift_static/linux/static-stdlib-args.lnk")
    guard isRegularFile(staticArguments) else {
        throw RuntimeFailure.invalidOutput(
            "host static Swift link metadata is missing: \(staticArguments)")
    }
    var arguments = try String(
        contentsOfFile: staticArguments.string,
        encoding: .utf8)
    if !arguments.contains("-lswift_StringProcessing") {
        if !arguments.hasSuffix("\n") { arguments.append("\n") }
        arguments += """
        -Xlinker --start-group
        -lFoundation
        -lFoundationEssentials
        -lFoundationInternationalization
        -lFoundationNetworking
        -lFoundationXML
        -l_CFXMLInterface
        -lCoreFoundation
        -l_FoundationICU
        -l_FoundationCShims
        -l_FoundationCollections
        -lswift_StringProcessing
        -lswift_RegexParser
        -lswiftRegexBuilder
        -lswift_Concurrency
        -lswiftObservation
        -lswiftSynchronization
        -lswiftSwiftOnoneSupport
        -Xlinker --end-group

        """
    } else if !arguments.contains("-l_CFXMLInterface") {
        arguments += "\n-l_CFXMLInterface\n"
    }
    if !arguments.contains("-lxml2") {
        arguments += "\n-lxml2\n"
    }
    try DurableFile.write(Data(arguments.utf8), to: staticArguments)
    let testingInterop = assembly.workspace.appending(
        "build/buildbot_linux/swifttesting-linux-x86_64/lib/"
            + "lib_TestingInterop.so")
    if isRegularFile(testingInterop) {
        try copyReplacing(
            from: testingInterop,
            to: library.appending("swift/linux/lib_TestingInterop.so"))
    }
}

private func assembleAndroidSDK(_ assembly: AndroidSDKAssembly) throws {
    guard !assembly.architectures.isEmpty else {
        throw RuntimeFailure.invalidOutput(
            "Android SDK assembly requires at least one architecture")
    }
    let triples = try Dictionary(
        uniqueKeysWithValues: assembly.architectures.map { architecture in
            switch architecture {
            case "aarch64", "x86_64":
                (
                    architecture,
                    "\(architecture)-unknown-linux-android\(assembly.apiLevel)")
            default:
                throw RuntimeFailure.invalidOutput(
                    "unsupported Android SDK architecture \(architecture)")
            }
        })
    let fileManager = FileManager.default
    try removeExisting(assembly.bundle)
    let variant = assembly.bundle.appending("swift-android")
    let resources = variant.appending("swift-resources")
    let resourcesUSR = resources.appending("usr")
    let resourcesLibrary = resourcesUSR.appending("lib")
    try fileManager.createDirectory(
        atPath: variant.appending("ndk-sysroot").string,
        withIntermediateDirectories: true)
    try fileManager.createDirectory(
        atPath: resourcesLibrary.appending("swift").string,
        withIntermediateDirectories: true)

    try writeJSON([
        "schemaVersion": "1.0",
        "artifacts": [
            "swift-\(assembly.sourceID)_android": [
                "variants": [["path": "swift-android"]],
                "version": "0.1",
                "type": "swiftSDK",
            ],
        ],
    ], to: assembly.bundle.appending("info.json"))
    try writeJSON([
        "cCompiler": ["extraCLIOptions": ["-fPIC"]],
        "swiftCompiler": [
            "extraCLIOptions": ["-Xclang-linker", "-fuse-ld=lld"],
        ],
        "linker": ["extraCLIOptions": ["-z", "max-page-size=16384"]],
        "schemaVersion": "1.0",
    ], to: variant.appending("swift-toolset.json"))
    try writeJSON([
        "DisplayName": "Swift Android SDK",
        "Version": "0.1",
        "VersionMap": [:],
        "CanonicalName": "linux-android",
    ], to: resources.appending("SDKSettings.json"))
    let targetTriples = Dictionary(uniqueKeysWithValues:
        assembly.architectures.map { architecture in
            (
                triples[architecture]!,
                [
                    "sdkRootPath": "ndk-sysroot",
                    "swiftResourcesPath":
                        "swift-resources/usr/lib/swift-\(architecture)",
                    "swiftStaticResourcesPath":
                        "swift-resources/usr/lib/swift_static-\(architecture)",
                    "toolsetPaths": ["swift-toolset.json"],
                ] as [String: Any]
            )
        })
    try writeJSON([
        "schemaVersion": "4.0",
        "targetTriples": targetTriples,
    ], to: variant.appending("swift-sdk.json"))

    let firstArchitecture = assembly.architectures[0]
    let firstUSR = assembly.installRoot.appending(
        "install-\(firstArchitecture)/usr")
    guard isDirectory(firstUSR) else {
        throw RuntimeFailure.invalidOutput(
            "Android SDK install tree is missing: \(firstUSR)")
    }
    try copyDirectoryContents(
        from: firstUSR.appending("include"),
        to: resourcesUSR.appending("include"))
    for relativePath in ["share/swift", "lib/cmake", "lib/pkgconfig"] {
        let source = firstUSR.appending(relativePath)
        if fileManager.fileExists(atPath: source.string) {
            try copyReplacing(
                from: source,
                to: resourcesUSR.appending(relativePath))
        }
    }
    let toolchainSwiftHeaders = assembly.toolchain.appending("include/swift")
    let toolchainModuleMap = assembly.toolchain.appending(
        "include/module.modulemap")
    guard isDirectory(toolchainSwiftHeaders),
          isRegularFile(toolchainModuleMap)
    else {
        throw RuntimeFailure.invalidOutput(
            "host Swift bridging headers are missing under \(assembly.toolchain)")
    }
    try copyReplacing(
        from: toolchainSwiftHeaders,
        to: resourcesUSR.appending("include/swift"))
    try copyReplacing(
        from: toolchainModuleMap,
        to: resourcesUSR.appending("include/module.modulemap"))

    for architecture in assembly.architectures {
        let installUSR = assembly.installRoot.appending(
            "install-\(architecture)/usr")
        let swiftDestination = resourcesLibrary.appending(
            "swift-\(architecture)")
        let staticDestination = resourcesLibrary.appending(
            "swift_static-\(architecture)")
        let swiftSource = installUSR.appending("lib/swift")
        let staticSource = installUSR.appending("lib/swift_static")
        guard isDirectory(swiftSource.appending("android")),
              isDirectory(staticSource.appending("android"))
        else {
            throw RuntimeFailure.invalidOutput(
                "Swift Android resources are missing for \(architecture)")
        }
        try copyReplacing(from: swiftSource, to: swiftDestination)
        try copyReplacing(from: staticSource, to: staticDestination)
        try replaceSymlink(
            "../swift/clang",
            at: swiftDestination.appending("clang"))
        try replaceSymlink(
            "../swift/clang",
            at: staticDestination.appending("clang"))

        for archive in ["libswiftCxx.a", "libswiftCxxStdlib.a"] {
            let source = swiftDestination.appending("android/\(archive)")
            guard isRegularFile(source) else {
                throw RuntimeFailure.invalidOutput(
                    "Swift C++ interoperability archive is missing: \(source)")
            }
            try copyReplacing(
                from: source,
                to: staticDestination.appending("android/\(archive)"))
        }
        let cfxml = staticDestination.appending(
            "android/lib_CFXMLInterface.a")
        guard isRegularFile(cfxml) else {
            throw RuntimeFailure.invalidOutput(
                "FoundationXML support archive is missing: \(cfxml)")
        }
        try copyReplacing(
            from: cfxml,
            to: swiftDestination.appending("android/lib_CFXMLInterface.a"))
        let staticArguments = staticDestination.appending(
            "android/static-stdlib-args.lnk")
        guard isRegularFile(staticArguments) else {
            throw RuntimeFailure.invalidOutput(
                "static Swift link arguments are missing: \(staticArguments)")
        }
        var arguments = try String(
            contentsOfFile: staticArguments.string,
            encoding: .utf8)
        if !arguments.contains("-l_CFXMLInterface") {
            if !arguments.hasSuffix("\n") {
                arguments.append("\n")
            }
            arguments += """
            -lFoundationXML
            -l_CFXMLInterface
            -lxml2
            -lz
            -llzma
            -liconv

            """
            try DurableFile.write(
                Data(arguments.utf8),
                to: staticArguments)
        }
        let libraryRoot = installUSR.appending("lib")
        for name in try fileManager.contentsOfDirectory(
            atPath: libraryRoot.string).sorted()
        where name.hasSuffix(".a")
        {
            let source = libraryRoot.appending(name)
            guard isRegularFile(source) else { continue }
            try copyReplacing(
                from: source,
                to: resourcesLibrary.appending(name))
            try copyReplacing(
                from: source,
                to: staticDestination.appending("android/\(name)"))
        }
    }
    try rewriteAndroidSDKMetadata(
        under: resourcesLibrary,
        originalPrefix: firstUSR.string)
}

private func writeJSON(_ object: Any, to path: FilePath) throws {
    var data = try JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys])
    data.append(0x0a)
    try DurableFile.write(data, to: path)
}

private func copyDirectoryContents(
    from source: FilePath,
    to destination: FilePath
) throws {
    guard isDirectory(source) else {
        throw RuntimeFailure.invalidOutput(
            "copy source directory is missing: \(source)")
    }
    let fileManager = FileManager.default
    try fileManager.createDirectory(
        atPath: destination.string,
        withIntermediateDirectories: true)
    for name in try fileManager.contentsOfDirectory(
        atPath: source.string).sorted()
    {
        try copyReplacing(
            from: source.appending(name),
            to: destination.appending(name))
    }
}

private func copyReplacing(
    from source: FilePath,
    to destination: FilePath
) throws {
    try removeExisting(destination)
    try FileManager.default.createDirectory(
        atPath: destination.removingLastComponent().string,
        withIntermediateDirectories: true)
    try FileManager.default.copyItem(
        atPath: source.string,
        toPath: destination.string)
}

private func rewriteAndroidSDKMetadata(
    under library: FilePath,
    originalPrefix: String
) throws {
    guard let enumerator = FileManager.default.enumerator(
        at: URL(fileURLWithPath: library.string),
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles])
    else { return }
    for case let url as URL in enumerator {
        guard try url.resourceValues(
            forKeys: [.isRegularFileKey]).isRegularFile == true
        else { continue }
        var contents: String
        switch url.pathExtension {
        case "pc":
            contents = try String(contentsOf: url, encoding: .utf8)
            let lines = contents.split(
                separator: "\n",
                omittingEmptySubsequences: false).map { line -> String in
                if line.hasPrefix("prefix=") {
                    return "prefix=${pcfiledir}/../.."
                }
                if line.hasPrefix("exec_prefix=") {
                    return "exec_prefix=${prefix}"
                }
                if line.hasPrefix("libdir=") {
                    return "libdir=${exec_prefix}/lib"
                }
                if line.hasPrefix("includedir=") {
                    return "includedir=${prefix}/include"
                }
                return String(line)
            }
            let rewritten = lines.joined(separator: "\n")
            if rewritten != contents {
                try DurableFile.write(
                    Data(rewritten.utf8),
                    to: FilePath(url.path))
            }
        case "cmake":
            contents = try String(contentsOf: url, encoding: .utf8)
            let rewritten = contents.replacingOccurrences(
                of: originalPrefix,
                with: "${_IMPORT_PREFIX}")
            if rewritten != contents {
                try DurableFile.write(
                    Data(rewritten.utf8),
                    to: FilePath(url.path))
            }
        default:
            continue
        }
    }
}

private func jsonRPCPayload(
    _ messages: [[String: Any]]
) throws -> [UInt8] {
    var payload = Data()
    for message in messages {
        let body = try JSONSerialization.data(
            withJSONObject: message,
            options: [.sortedKeys])
        payload.append(Data("Content-Length: \(body.count)\r\n\r\n".utf8))
        payload.append(body)
    }
    return Array(payload)
}

private func jsonRPCMessages(
    _ output: String
) throws -> [[String: Any]] {
    let data = Data(output.utf8)
    let separator = Data("\r\n\r\n".utf8)
    var offset = data.startIndex
    var messages: [[String: Any]] = []
    while offset < data.endIndex {
        guard let headerRange = data.range(
            of: separator,
            in: offset..<data.endIndex),
              let header = String(
                data: data[offset..<headerRange.lowerBound],
                encoding: .utf8),
              let lengthLine = header.split(separator: "\r\n").first(
                where: {
                    $0.lowercased().hasPrefix("content-length:")
                }),
              let length = Int(lengthLine.split(
                separator: ":", maxSplits: 1)[1]
                .trimmingCharacters(in: .whitespaces))
        else {
            throw RuntimeFailure.invalidOutput(
                "SourceKit-LSP emitted invalid JSON-RPC framing")
        }
        let bodyStart = headerRange.upperBound
        let bodyEnd = bodyStart + length
        guard bodyEnd <= data.endIndex,
              let message = try JSONSerialization.jsonObject(
                with: data[bodyStart..<bodyEnd]) as? [String: Any]
        else {
            throw RuntimeFailure.invalidOutput(
                "SourceKit-LSP emitted an invalid JSON-RPC body")
        }
        messages.append(message)
        offset = bodyEnd
    }
    return messages
}

private let hostToolchainSmokeSource = """
import Foundation
import FoundationXML

@main
struct NucleusToolchainSmoke {
    static func main() {
        let parser = XMLParser(data: Data("<nucleus/>".utf8))
        precondition(parser.parse())
    }
}
"""

private let hostCXXTestManifest = """
// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "CxxInteropTestRunner",
    products: [.library(name: "Example", targets: ["Example"])],
    targets: [
        .target(name: "Example"),
        .testTarget(
            name: "ExampleTests",
            dependencies: ["Example"],
            swiftSettings: [.interoperabilityMode(.Cxx)]),
    ]
)
"""

private let hostCXXTestSource = """
import Testing
import Example

@Test func exampleExists() {
    _ = Example()
}
"""

private let hostLSPManifest = """
// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "NucleusLSPPackage",
    products: [.library(name: "Greeter", targets: ["Greeter"])],
    targets: [
        .target(name: "Greeter"),
        .executableTarget(name: "App", dependencies: ["Greeter"]),
    ]
)
"""

private let hostLSPLibrary = """
public struct Greeter {
    public init() {}
    public func message() -> String { "hello" }
}
"""

private let hostLSPApplication = """
import Greeter

let greeter = Greeter()
print(greeter.message())
"""

private let androidSDKConsumerManifest = """
// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "AndroidSDKConsumer",
    products: [.executable(name: "hello", targets: ["hello"])],
    targets: [
        .executableTarget(
            name: "hello",
            swiftSettings: [.interoperabilityMode(.Cxx)],
            plugins: ["FoundationXMLHostPlugin"]),
        .plugin(name: "FoundationXMLHostPlugin", capability: .buildTool()),
    ]
)
"""

private let androidSDKConsumerSource = """
import Foundation
import FoundationNetworking
import FoundationXML
import CxxStdlib

@main
struct Hello {
    static func main() {
        let url = URL(string: "https://example.com")!
        let parser = XMLParser(data: Data("<nucleus/>".utf8))
        precondition(parser.parse())
        let cxxString = std.string("nucleus")
        precondition(cxxString.size() == 7)
        print(url.host ?? "missing-host")
    }
}
"""

private let androidSDKConsumerPlugin = """
import Foundation
import FoundationXML
import PackagePlugin

@main
struct FoundationXMLHostPlugin: BuildToolPlugin {
    func createBuildCommands(
        context: PluginContext,
        target: Target
    ) throws -> [Command] {
        let parser = XMLParser(data: Data("<host-tool/>".utf8))
        precondition(parser.parse())
        return []
    }
}
"""

private func androidNDKReadELF(_ ndk: FilePath) throws -> FilePath {
    let prebuilt = ndk.appending("toolchains/llvm/prebuilt")
    let candidates = try directoryChildren(prebuilt).map {
        $0.appending("bin/llvm-readelf")
    }.filter {
        FileManager.default.isExecutableFile(atPath: $0.string)
    }
    guard candidates.count == 1, let readelf = candidates.first else {
        throw RuntimeFailure.invalidOutput(
            "expected one llvm-readelf under \(prebuilt); found "
                + "\(candidates.count)")
    }
    return readelf
}

private func singleExecutable(
    named name: String,
    under directory: FilePath
) throws -> FilePath {
    guard let enumerator = FileManager.default.enumerator(
        at: URL(fileURLWithPath: directory.string),
        includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey],
        options: [.skipsHiddenFiles])
    else {
        throw RuntimeFailure.invalidOutput(
            "build output is missing: \(directory)")
    }
    var matches: [FilePath] = []
    for case let url as URL in enumerator where url.lastPathComponent == name {
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isExecutableKey])
        if values.isRegularFile == true, values.isExecutable == true {
            matches.append(FilePath(url.path))
        }
    }
    guard matches.count == 1, let executable = matches.first else {
        throw RuntimeFailure.invalidOutput(
            "expected one executable named \(name) under \(directory); found "
                + "\(matches.count)")
    }
    return executable
}

private func sanitizeLinkMetadata(
    _ sanitization: LinkMetadataSanitization
) throws {
    guard let enumerator = FileManager.default.enumerator(
        at: URL(fileURLWithPath: sanitization.root.string),
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles])
    else {
        throw RuntimeFailure.invalidOutput(
            "link metadata root is missing: \(sanitization.root)")
    }
    for case let url as URL in enumerator {
        let path = url.path
        guard path.hasSuffix(".pc")
                || path.hasSuffix(".la")
                || path.contains("/cmake/"),
              try url.resourceValues(
                forKeys: [.isRegularFileKey]).isRegularFile == true
        else { continue }
        var contents = try String(contentsOf: url, encoding: .utf8)
        let original = contents
        for option in sanitization.removedLinkerOptions {
            for expression in [
                "$<LINK_ONLY:\(option)>",
                "\\$<LINK_ONLY:\(option)>",
                "\\\\$<LINK_ONLY:\(option)>",
            ] {
                contents = contents.replacingOccurrences(
                    of: expression, with: "")
            }
            contents = contents.replacingOccurrences(of: option, with: "")
        }
        if contents != original {
            try DurableFile.write(Data(contents.utf8), to: FilePath(path))
        }
    }
}

private func publishSymlink(_ publication: SymlinkPublication) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
        atPath: publication.path.removingLastComponent().string,
        withIntermediateDirectories: true)
    if let existing = try? fileManager.destinationOfSymbolicLink(
        atPath: publication.path.string)
    {
        if existing == publication.target {
            return
        }
        try fileManager.removeItem(atPath: publication.path.string)
        try fileManager.createSymbolicLink(
            atPath: publication.path.string,
            withDestinationPath: publication.target)
        return
    }
    var displaced = false
    if fileManager.fileExists(atPath: publication.path.string) {
        guard !fileManager.fileExists(
            atPath: publication.displacedItem.string)
        else {
            throw RuntimeFailure.invalidOutput(
                "cannot preserve \(publication.path); displacement already exists "
                    + "at \(publication.displacedItem)")
        }
        try fileManager.moveItem(
            atPath: publication.path.string,
            toPath: publication.displacedItem.string)
        displaced = true
    }
    do {
        try fileManager.createSymbolicLink(
            atPath: publication.path.string,
            withDestinationPath: publication.target)
    } catch {
        if displaced {
            try? fileManager.moveItem(
                atPath: publication.displacedItem.string,
                toPath: publication.path.string)
        }
        throw error
    }
}

private func wireAndroidSDK(_ wiring: AndroidSDKWiring) throws {
    let fileManager = FileManager.default
    let sourceProperties = wiring.ndk.appending("source.properties")
    let properties: String
    do {
        properties = try String(
            contentsOfFile: sourceProperties.string,
            encoding: .utf8)
    } catch {
        throw RuntimeFailure.invalidOutput(
            "Android NDK source.properties is missing: \(sourceProperties)")
    }
    guard let revision = properties.split(whereSeparator: \.isNewline)
        .first(where: { $0.hasPrefix("Pkg.Revision = ") })?
        .dropFirst("Pkg.Revision = ".count)
        .split(separator: ".")
        .first,
          let major = UInt32(revision),
          major >= wiring.minimumNDKMajorVersion
    else {
        throw RuntimeFailure.invalidOutput(
            "Android NDK \(wiring.ndk) must be version "
                + "\(wiring.minimumNDKMajorVersion) or newer")
    }

    let prebuiltRoot = wiring.ndk.appending("toolchains/llvm/prebuilt")
    let hostDirectories = try directoryChildren(prebuiltRoot).filter {
        isDirectory($0.appending("sysroot/usr/include"))
            && isDirectory($0.appending("sysroot/usr/lib"))
            && isDirectory($0.appending("lib/clang"))
    }
    guard hostDirectories.count == 1, let prebuilt = hostDirectories.first else {
        throw RuntimeFailure.invalidOutput(
            "expected one complete Android NDK LLVM prebuilt under "
                + "\(prebuiltRoot); found \(hostDirectories.count)")
    }

    let variant = wiring.bundle.appending("swift-android")
    let resources = variant.appending("swift-resources")
    let resourcesLibrary = resources.appending("usr/lib")
    guard isDirectory(resourcesLibrary) else {
        throw RuntimeFailure.invalidOutput(
            "Swift Android resources are missing: \(resourcesLibrary)")
    }

    let sysroot = variant.appending("ndk-sysroot")
    let legacyToolchain = variant.appending("ndk-toolchain")
    try removeExisting(sysroot)
    try removeExisting(legacyToolchain)
    let sysrootLibraries = sysroot.appending("usr/lib")
    try fileManager.createDirectory(
        atPath: sysrootLibraries.string,
        withIntermediateDirectories: true)
    try replaceSymlink(
        prebuilt.appending("sysroot/usr/include").string,
        at: sysroot.appending("usr/include"))
    for libraryDirectory in try directoryChildren(
        prebuilt.appending("sysroot/usr/lib"))
    {
        try replaceSymlink(
            libraryDirectory.string,
            at: sysrootLibraries.appending(libraryDirectory.lastComponent!.string))
    }

    let clangVersions = try directoryChildren(prebuilt.appending("lib/clang"))
        .filter(isDirectory)
        .sorted(by: versionPathOrdering)
    guard let clangResources = clangVersions.last else {
        throw RuntimeFailure.invalidOutput(
            "Android NDK Clang resources are missing under \(prebuilt)/lib/clang")
    }
    try replaceSymlink(
        clangResources.string,
        at: resourcesLibrary.appending("swift/clang"))

    for resourceDirectory in try directoryChildren(resourcesLibrary) {
        let directoryName = resourceDirectory.lastComponent!.string
        let family: String
        if directoryName.hasPrefix("swift_static-") {
            family = "swift_static"
        } else if directoryName.hasPrefix("swift-") {
            family = "swift"
        } else {
            continue
        }
        let android = resourceDirectory.appending("android")
        guard isDirectory(android) else { continue }
        for architectureDirectory in try directoryChildren(android) {
            let source = architectureDirectory.appending("swiftrt.o")
            guard isRegularFile(source) else { continue }
            let destinationDirectory = sysrootLibraries
                .appending(family)
                .appending("android")
                .appending(architectureDirectory.lastComponent!.string)
            try fileManager.createDirectory(
                atPath: destinationDirectory.string,
                withIntermediateDirectories: true)
            let destination = destinationDirectory.appending("swiftrt.o")
            try replaceSymlink(
                relativePath(from: destinationDirectory, to: source),
                at: destination)
        }
    }
}

private func directoryChildren(_ directory: FilePath) throws -> [FilePath] {
    try FileManager.default.contentsOfDirectory(atPath: directory.string)
        .sorted()
        .map(directory.appending)
}

private func isDirectory(_ path: FilePath) -> Bool {
    var directory: ObjCBool = false
    return FileManager.default.fileExists(
        atPath: path.string,
        isDirectory: &directory) && directory.boolValue
}

private func isRegularFile(_ path: FilePath) -> Bool {
    var directory: ObjCBool = false
    return FileManager.default.fileExists(
        atPath: path.string,
        isDirectory: &directory) && !directory.boolValue
}

private func removeExisting(_ path: FilePath) throws {
    if FileManager.default.fileExists(atPath: path.string)
        || (try? FileManager.default.destinationOfSymbolicLink(
            atPath: path.string)) != nil
    {
        try FileManager.default.removeItem(atPath: path.string)
    }
}

private func replaceSymlink(_ target: String, at path: FilePath) throws {
    try removeExisting(path)
    try FileManager.default.createDirectory(
        atPath: path.removingLastComponent().string,
        withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        atPath: path.string,
        withDestinationPath: target)
}

private func relativePath(from directory: FilePath, to destination: FilePath) -> String {
    let base = URL(fileURLWithPath: directory.string).standardizedFileURL.pathComponents
    let target = URL(fileURLWithPath: destination.string).standardizedFileURL.pathComponents
    var common = 0
    while common < base.count, common < target.count,
          base[common] == target[common]
    {
        common += 1
    }
    return (
        Array(repeating: "..", count: base.count - common)
            + Array(target.dropFirst(common))
    ).joined(separator: "/")
}

private func versionPathOrdering(_ lhs: FilePath, _ rhs: FilePath) -> Bool {
    func components(_ path: FilePath) -> [Int] {
        path.lastComponent!.string.split(separator: ".").map {
            Int($0) ?? -1
        }
    }
    return components(lhs).lexicographicallyPrecedes(components(rhs))
}

private func staticArchives(
    for merge: StaticArchiveMerge
) throws -> [FilePath] {
    guard let enumerator = FileManager.default.enumerator(
        at: URL(fileURLWithPath: merge.sourceRoot.string),
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles])
    else {
        throw RuntimeFailure.invalidOutput(merge.sourceRoot.string)
    }
    var archives: [FilePath] = []
    for case let url as URL in enumerator {
        guard url.pathExtension == "a",
              url.path != merge.output.string,
              !merge.excludedFilePrefixes.contains(where: {
                  url.lastPathComponent.hasPrefix($0)
              }),
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        else { continue }
        guard !url.path.contains("\n") else {
            throw RuntimeFailure.invalidOutput(
                "static archive path contains a newline: \(url.path)")
        }
        archives.append(FilePath(url.path))
    }
    return archives.sorted { $0.string.utf8.lexicographicallyPrecedes($1.string.utf8) }
}

private func resolveExecutable(_ name: String, path: String?) -> FilePath? {
    guard let path else { return nil }
    for directory in path.split(separator: ":", omittingEmptySubsequences: false) {
        let candidate = FilePath(String(directory)).appending(name)
        if FileManager.default.isExecutableFile(atPath: candidate.string) {
            return candidate
        }
    }
    return nil
}

private func statePath(_ task: TaskID, root: FilePath) -> FilePath {
    root.appending(task.rawValue.map {
        $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-"
    }.reduce(into: "") { $0.append($1) } + ".json")
}

private func safeLockName(_ value: String) -> String {
    value.map {
        $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-"
    }.reduce(into: "") { $0.append($1) }
}

private func acquireTaskLocks(
    _ locks: [TaskLock],
    stateRoot: FilePath,
    run: RunHandle?,
    task: TaskID? = nil,
    purpose: String
) throws -> [ColliderFileLock] {
    let locksRoot = stateRoot.removingLastComponent().appending("locks")
    return try locks.sorted(by: lockOrdering).map { lock in
        let path: FilePath
        let detail: String
        switch lock {
        case .checkout(let name):
            path = locksRoot.appending(safeLockName(name) + ".lock")
            detail = "checkout mutation \(name)"
        case .shared(let sharedPath):
            path = sharedPath
            detail = "shared mutation"
        }
        return try ColliderFileLock(
            path: path,
            purpose: "\(purpose) \(detail)",
            owner: LockOwner(
                run: run?.id.rawValue,
                task: task?.rawValue))
    }
}

private func lockOrdering(_ lhs: TaskLock, _ rhs: TaskLock) -> Bool {
    func key(_ lock: TaskLock) -> String {
        switch lock {
        case .checkout(let value): "checkout:\(value)"
        case .shared(let path): "shared:\(path.string)"
        }
    }
    return key(lhs) < key(rhs)
}
