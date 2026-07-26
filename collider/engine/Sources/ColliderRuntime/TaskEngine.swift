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
        var encoder = CanonicalDigestEncoder()
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
            encoder.append(tag: 130, string: assembly.archive.string)
            encoder.append(tag: 131, string: assembly.toolchain.string)
            encoder.append(tag: 132, string: assembly.platform.rawValue)
            for (name, value) in artifactEnvironment(assembly.environment) {
                encoder.append(tag: 185, string: name)
                encoder.append(tag: 186, string: value)
            }
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
            for repair in sanitization.cmakeDependencyRepairs {
                encoder.append(
                    tag: 204, string: repair.configurationFileName)
                encoder.append(tag: 205, string: repair.package)
                encoder.append(tag: 206, string: repair.version)
                encoder.append(
                    tag: 207,
                    integer: repair.configurationOnly ? 1 : 0)
            }
            for replacement in sanitization.replacements {
                encoder.append(tag: 208, string: replacement.fileName)
                encoder.append(tag: 209, string: replacement.original)
                encoder.append(tag: 210, string: replacement.replacement)
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
        case .verifyAOSPSourceLock(let verification):
            encode(
                aospSource: verification.specification,
                into: &encoder)
            encoder.append(tag: 182, string: "verify")
            encoder.append(tag: 185, string: verification.launcher.string)
            encoder.append(tag: 185, string: verification.report.string)
            let git = try resolvedToolIdentity(
                .named("git"),
                environment: verification.environment)
            encoder.append(tag: 187, string: git.path.string)
            encoder.append(tag: 188, bytes: git.digest.bytes)
            for (name, value) in artifactEnvironment(
                verification.environment)
            {
                encoder.append(tag: 189, string: name)
                encoder.append(tag: 190, string: value)
            }
        case .prepareAOSPSource(let preparation):
            encode(
                aospSource: preparation.specification,
                into: &encoder)
            encoder.append(tag: 182, string: "prepare")
            encoder.append(tag: 185, string: preparation.launcher.string)
            encoder.append(tag: 185, string: preparation.source.string)
            for stack in preparation.patchStacks {
                encoder.append(tag: 191, string: stack.repositoryPath)
                for patch in stack.patches {
                    encoder.append(tag: 192, string: patch.path)
                    encoder.append(tag: 193, string: patch.file.string)
                }
            }
            // Sync concurrency and retry limits affect execution only, not the
            // materialized source identity.
            for executable in [
                CommandSpec.Executable.named("git"),
                CommandSpec.Executable.named("python3"),
            ] {
                let tool = try resolvedToolIdentity(
                    executable,
                    environment: preparation.environment)
                encoder.append(tag: 187, string: tool.path.string)
                encoder.append(tag: 188, bytes: tool.digest.bytes)
            }
            for (name, value) in artifactEnvironment(
                preparation.environment)
            {
                encoder.append(tag: 189, string: name)
                encoder.append(tag: 190, string: value)
            }
        case .prepareAOSPSigningIdentity(let preparation):
            encoder.append(tag: 191, string: preparation.destination.string)
            encoder.append(tag: 192, string: preparation.subject)
            let tool = try resolvedToolIdentity(
                .named("openssl"),
                environment: preparation.environment)
            encoder.append(tag: 193, string: tool.path.string)
            encoder.append(tag: 194, bytes: tool.digest.bytes)
            for (name, value) in artifactEnvironment(
                preparation.environment)
            {
                encoder.append(tag: 195, string: name)
                encoder.append(tag: 196, string: value)
            }
        case .compileAOSPProduct(let build),
             .signAOSPProduct(let build),
             .assembleAOSPProductImages(let build),
             .validateAOSPProduct(let build),
             .publishAOSPProduct(let build):
            let pipelineStage: String
            switch operation {
            case .compileAOSPProduct:
                pipelineStage = "compile"
            case .signAOSPProduct:
                pipelineStage = "sign"
            case .assembleAOSPProductImages:
                pipelineStage = "assemble-images"
            case .validateAOSPProduct:
                pipelineStage = "validate"
            case .publishAOSPProduct:
                pipelineStage = "publish"
            default:
                preconditionFailure("unreachable AOSP product operation")
            }
            encoder.append(tag: 196, string: pipelineStage)
            for path in [
                build.productSource,
                build.source,
                build.repoLauncher,
                build.sourceProvenance,
                build.buildRoot,
                build.signingIdentity,
            ] {
                encoder.append(tag: 197, string: path.string)
            }
            for value in [
                build.product,
                build.release,
                build.variant,
                build.buildNumber,
            ] {
                encoder.append(tag: 198, string: value)
            }
            // Build concurrency affects scheduling, not product contents.
            for value in [
                build.buildTimestamp,
                UInt64(build.expectedPlatformSDK),
                UInt64(build.expectedVendorAPILevel),
            ] {
                encoder.append(tag: 199, integer: value)
            }
            for (name, value) in artifactEnvironment(build.environment) {
                encoder.append(tag: 202, string: name)
                encoder.append(tag: 203, string: value)
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

    private func encode(
        aospSource specification: AOSPSourceSpecification,
        into encoder: inout CanonicalDigestEncoder
    ) {
        let platform = specification.platform
        for value in [
            platform.release,
            platform.revision,
            platform.manifestURL,
            platform.manifestTagObject,
            platform.manifestCommit,
            platform.superprojectURL,
            platform.superprojectRevision,
            platform.superprojectCommit,
        ] {
            encoder.append(tag: 183, string: value)
        }
        encoder.append(
            tag: 184,
            bytes: platform.defaultManifestDigest.bytes)
        let repo = specification.repo
        for value in [
            repo.launcherVersion,
            repo.repositoryURL,
            repo.revision,
            repo.tagObject,
            repo.commit,
        ] {
            encoder.append(tag: 183, string: value)
        }
        encoder.append(tag: 184, bytes: repo.launcherDigest.bytes)
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
            try await validateGitCheckout(validation, stage: stage)
        case .prepareHostToolchainBuild(let preparation):
            try prepareHostToolchainBuild(preparation)
        case .assembleHostToolchain(let assembly):
            try await assembleHostToolchain(assembly, stage: stage)
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
        case .verifyAOSPSourceLock(let verification):
            try await verifyAOSPSourceLock(
                verification,
                stage: stage)
        case .prepareAOSPSource(let preparation):
            try await prepareAOSPSource(
                preparation,
                stage: stage)
        case .prepareAOSPSigningIdentity(let preparation):
            try await prepareAOSPSigningIdentity(
                preparation,
                stage: stage)
        case .compileAOSPProduct(let build):
            try await compileAOSPProduct(build, stage: stage)
        case .signAOSPProduct(let build):
            try await signAOSPProduct(build, stage: stage)
        case .assembleAOSPProductImages(let build):
            try await assembleAOSPProductImages(build, stage: stage)
        case .validateAOSPProduct(let build):
            try await validateAOSPProduct(build, stage: stage)
        case .publishAOSPProduct(let build):
            try await publishAOSPProduct(build, stage: stage)
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


    private func validate(_ outputs: [OutputDeclaration]) throws {
        for output in outputs {
            switch output.validation {
            case .exists:
                _ = try output.path.stat(followTargetSymlink: false)
            case .regularFile, .json:
                let metadata = try output.path.stat()
                guard metadata.type == .regular else {
                    throw RuntimeFailure.invalidOutput(output.path.string)
                }
                if output.validation == .json {
                    _ = try JSONSerialization.jsonObject(
                        with: Data(contentsOf: URL(fileURLWithPath: output.path.string)))
                }
            case .executableFile:
                let metadata = try output.path.stat()
                guard metadata.type == .regular,
                      metadata.permissions.contains(.ownerExecute)
                else { throw RuntimeFailure.invalidOutput(output.path.string) }
            case .nonEmptyDirectory:
                let metadata = try output.path.stat()
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
    case .prepareHostToolchainBuild:
        [:]
    case .assembleHostToolchain(let assembly):
        assembly.environment
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
    case .verifyAOSPSourceLock(let verification):
        verification.environment
    case .prepareAOSPSource(let preparation):
        preparation.environment
    case .prepareAOSPSigningIdentity(let preparation):
        preparation.environment
    case .compileAOSPProduct(let build),
         .signAOSPProduct(let build),
         .assembleAOSPProductImages(let build),
         .validateAOSPProduct(let build),
         .publishAOSPProduct(let build):
        build.environment
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
