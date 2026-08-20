import SystemPackage

public enum SwiftBuildConfiguration: String, Codable, Hashable, Sendable {
    case debug
    case release
}

public enum SwiftPMBuildSystem: String, Codable, Hashable, Sendable {
    case native
    case swiftbuild
}

public enum SwiftDebugInformationFormat: String, Codable, Hashable, Sendable {
    case dwarf
    case codeview
    case none
}

public enum SwiftBuildTarget: Hashable, Sendable {
    /// Uses SwiftPM's default host target. The identity names the resolved host
    /// platform without forcing a `--triple` argument.
    case host(identity: String)
    case triple(String)
    case swiftSDK(name: String, targetTriple: String)
}

public enum SwiftPMExecution: Hashable, Sendable {
    case host
    case oci(SwiftPMOCIExecution)
}

public enum SwiftPMInvocationExecutionFailure: Error, CustomStringConvertible, Sendable {
    case requiresOCIContext

    public var description: String {
        switch self {
        case .requiresOCIContext:
            "the requested SwiftPM executable action requires an OCI build context"
        }
    }
}

public struct SwiftPMOCIExecution: Hashable, Sendable {
    public let executionPlatform: ExecutionPlatform
    public let artifactTarget: ArtifactTarget
    public let image: ArtifactReference
    public let inputArtifacts: [ArtifactReference]
    public let hostname: String
    public let hostWorkingDirectory: FilePath
    public let mounts: [OCIMount]
    public let buildWorkspace: PersistentWorkspaceDeclaration?
    public let compilerCacheWorkspace: PersistentWorkspaceDeclaration?
    public let hostDependencyCache: FilePath
    public let processFilesystemPolicy: OCIProcessFilesystemPolicy
    public let executableRequirements: Set<OCIExecutableRequirement>
    public let resourceLimits: OCIResourceLimits
    public let containerEnvironment: [String: String]
    public let environmentProjection: EnvironmentProjection
    public let commandPrefix: [String]
    /// An installed unified SwiftPM executable used directly inside the OCI
    /// environment. Its command mode is selected with `SWIFTPM_EXEC_NAME`, so
    /// it does not need to be installed beside the Swift compiler driver.
    public let swiftPMExecutable: FilePath?

    public init(
        executionPlatform: ExecutionPlatform,
        artifactTarget: ArtifactTarget,
        image: ArtifactReference,
        inputArtifacts: [ArtifactReference] = [],
        hostname: String,
        hostWorkingDirectory: FilePath,
        mounts: [OCIMount],
        buildWorkspace: PersistentWorkspaceDeclaration? = nil,
        compilerCacheWorkspace: PersistentWorkspaceDeclaration? = nil,
        hostDependencyCache: FilePath,
        processFilesystemPolicy: OCIProcessFilesystemPolicy = .standard,
        executableRequirements: Set<OCIExecutableRequirement> = [],
        resourceLimits: OCIResourceLimits = .build,
        containerEnvironment: [String: String] = [:],
        environmentProjection: EnvironmentProjection = .none,
        commandPrefix: [String] = ["swiftpm"],
        swiftPMExecutable: FilePath? = nil
    ) {
        precondition(executionPlatform == .linuxARM64OCI)
        self.executionPlatform = executionPlatform
        self.artifactTarget = artifactTarget
        self.image = image
        self.inputArtifacts = inputArtifacts
        self.hostname = hostname
        self.hostWorkingDirectory = hostWorkingDirectory
        self.mounts = mounts
        self.buildWorkspace = buildWorkspace
        self.compilerCacheWorkspace = compilerCacheWorkspace
        self.hostDependencyCache = hostDependencyCache
        self.processFilesystemPolicy = processFilesystemPolicy
        self.executableRequirements = executableRequirements
        self.resourceLimits = resourceLimits
        self.containerEnvironment = containerEnvironment
        self.environmentProjection = environmentProjection
        self.commandPrefix = commandPrefix
        self.swiftPMExecutable = swiftPMExecutable
    }

    public var imageID: FilePath { image.path }
}

public struct EnvironmentProjection: Hashable, Sendable {
    public let names: Set<String>
    public let prefixes: Set<String>
    public let excludedNames: Set<String>

    public init(
        names: Set<String> = [],
        prefixes: Set<String> = [],
        excludedNames: Set<String> = []
    ) {
        self.names = names
        self.prefixes = prefixes
        self.excludedNames = excludedNames
    }

    public static let none = EnvironmentProjection()

    public func project(_ environment: [String: String]) -> [String: String] {
        environment.filter { name, _ in
            !excludedNames.contains(name)
                && (names.contains(name)
                    || prefixes.contains(where: name.hasPrefix))
        }
    }
}

/// The complete SwiftPM invocation context. `identityBytes` contains only the
/// settings that determine whether compilation artifacts may be reused.
public struct SwiftBuildContext: Hashable, Sendable {
    public static let defaultMaximumParallelism: UInt32 = 10
    public static let concurrentOCIMaximumParallelism: UInt32 = 12

    public let packageRoot: FilePath
    public let buildSystem: SwiftPMBuildSystem
    public let configuration: SwiftBuildConfiguration
    public let debugInformationFormat: SwiftDebugInformationFormat?
    public let target: SwiftBuildTarget
    public let toolchainIdentity: String
    public let sanitizer: String?
    public let traits: [String]
    public let swiftFlags: [String]
    public let cFlags: [String]
    public let cxxFlags: [String]
    public let linkerFlags: [String]
    public let toolsets: [FilePath]
    public let staticSwiftStandardLibrary: Bool
    public let maximumParallelism: UInt32
    public let execution: SwiftPMExecution
    /// Placement-only roots this context's identity resolves through.
    ///
    /// Absolute paths that merely say where the host keeps things must not
    /// reach an identity, or the same source at two locations compiles twice
    /// and shares nothing. The CI checkout and the authoritative checkout are
    /// exactly that pair, and so are one checkout before and after it moves.
    /// Empty means no canonicalization, which is correct only where no such
    /// root exists.
    public let identityPathMap: IdentityPathMap

    public init(
        packageRoot: FilePath,
        buildSystem: SwiftPMBuildSystem = .swiftbuild,
        configuration: SwiftBuildConfiguration,
        debugInformationFormat: SwiftDebugInformationFormat? = nil,
        target: SwiftBuildTarget,
        toolchainIdentity: String,
        sanitizer: String? = nil,
        traits: [String] = [],
        swiftFlags: [String] = [],
        cFlags: [String] = [],
        cxxFlags: [String] = [],
        linkerFlags: [String] = [],
        toolsets: [FilePath] = [],
        staticSwiftStandardLibrary: Bool = false,
        maximumParallelism: UInt32 = SwiftBuildContext.defaultMaximumParallelism,
        execution: SwiftPMExecution = .host,
        identityPathMap: IdentityPathMap = .empty
    ) {
        precondition(packageRoot.isAbsolute && packageRoot.isLexicallyNormal)
        precondition(maximumParallelism > 0)
        self.packageRoot = packageRoot
        self.buildSystem = buildSystem
        self.configuration = configuration
        self.debugInformationFormat = debugInformationFormat
        self.target = target
        self.toolchainIdentity = toolchainIdentity
        self.sanitizer = sanitizer
        self.traits = Array(Set(traits)).sorted()
        self.swiftFlags = swiftFlags
        self.cFlags = cFlags
        self.cxxFlags = cxxFlags
        self.linkerFlags = linkerFlags
        self.toolsets = toolsets
        self.staticSwiftStandardLibrary = staticSwiftStandardLibrary
        self.maximumParallelism = maximumParallelism
        self.execution = execution
        self.identityPathMap = identityPathMap
    }

    /// Stable canonical bytes used both in task identity and to derive the
    /// package scratch directory.
    public var identityBytes: [UInt8] {
        identityBytes(identityPathMap: identityPathMap)
    }

    public func identityBytes(identityPathMap: IdentityPathMap) -> [UInt8] {
        var encoder = IdentityEncoder(identityPathMap: identityPathMap)
        encoder.append(path: packageRoot)
        encoder.append(buildSystem.rawValue)
        encoder.append(configuration.rawValue)
        encoder.appendOptional(debugInformationFormat) {
            $0.append($1.rawValue)
        }
        switch target {
        case .host(let identity):
            encoder.append("host")
            encoder.append(identity)
        case .triple(let triple):
            encoder.append("triple")
            encoder.append(triple)
        case .swiftSDK(let name, let targetTriple):
            encoder.append("swift-sdk")
            encoder.append(name)
            encoder.append(targetTriple)
        }
        encoder.append(toolchainIdentity)
        encoder.appendOptional(sanitizer) { $0.append($1) }
        append(traits, into: &encoder)
        append(swiftFlags, into: &encoder)
        append(cFlags, into: &encoder)
        append(cxxFlags, into: &encoder)
        append(linkerFlags, into: &encoder)
        encoder.appendSequence(toolsets) { $0.append(path: $1) }
        encoder.append(staticSwiftStandardLibrary)
        switch execution {
        case .host:
            encoder.append("host")
        case .oci(let configuration):
            encoder.append("oci")
            encoder.append(configuration.executionPlatform.operatingSystem.rawValue)
            encoder.append(configuration.executionPlatform.architecture.rawValue)
            encoder.append(configuration.artifactTarget.operatingSystem.rawValue)
            encoder.append(configuration.artifactTarget.architecture.rawValue)
            encoder.append(path: configuration.imageID)
            encoder.appendSequence(configuration.inputArtifacts) {
                $0.append(path: $1.path)
            }
            encoder.appendSequence(
                configuration.executableRequirements.sorted {
                    if $0.architecture != $1.architecture {
                        return $0.architecture.rawValue < $1.architecture.rawValue
                    }
                    return $0.executable < $1.executable
                }
            ) { requirement, value in
                requirement.appendEnum(value.architecture)
                requirement.append(value.executable)
            }
            encoder.appendSequence(configuration.mounts) { mountEncoder, mount in
                mountEncoder.append(path: mount.source)
                mountEncoder.append(mount.target)
                mountEncoder.appendEnum(mount.purpose)
            }
            encoder.appendOptional(configuration.buildWorkspace) {
                append($1, into: &$0)
            }
            encoder.appendOptional(configuration.compilerCacheWorkspace) {
                append($1, into: &$0)
            }
            encoder.appendSequence(configuration.commandPrefix) { $0.append($1) }
            encoder.appendOptional(configuration.swiftPMExecutable) {
                $0.append(path: $1)
            }
            encoder.append(path: configuration.hostDependencyCache)
        }
        return encoder.bytes
    }
}

/// The shared construction contract for SwiftPM-backed task declarations.
public struct SwiftPMInvocation: Hashable, Sendable {
    public static let ociSwiftSDKDirectory = FilePath("/swift-sdks")

    public let context: SwiftBuildContext
    public let scratchPath: FilePath
    public let swiftExecutable: CommandSpec.Executable
    public let dependencyLock: FilePath?
    public let dependencyConfigurationFiles: [FilePath]
    public let sourceGraph: SwiftPackageSourceGraph

    public init(
        context: SwiftBuildContext,
        scratchPath: FilePath,
        swiftExecutable: CommandSpec.Executable = .named("swift"),
        dependencyLock: FilePath? = nil,
        dependencyConfigurationFiles: [FilePath] = [],
        sourceGraph: SwiftPackageSourceGraph? = nil
    ) {
        self.context = context
        self.scratchPath = scratchPath
        self.swiftExecutable = swiftExecutable
        self.dependencyLock = dependencyLock
        self.dependencyConfigurationFiles = Array(Set(dependencyConfigurationFiles)).sorted {
            $0.string < $1.string
        }
        self.sourceGraph = sourceGraph ?? .packageWide(context.packageRoot)
    }

    /// Typed artifacts required to execute this invocation. Logical SwiftPM
    /// requirements retain these producer edges so selection includes every
    /// prerequisite before the requirements are lowered into physical tasks.
    public var artifactReferences: [ArtifactReference] {
        var references: [ArtifactReference] = []
        if case .artifact(let compiler) = swiftExecutable {
            references.append(compiler)
        }
        if case .oci(let configuration) = context.execution {
            references.append(configuration.image)
            references.append(contentsOf: configuration.inputArtifacts)
        }
        return references
    }

    public var identityInput: ArtifactInput {
        .swiftBuildContext(context)
    }

    public var postcondition: PathPostcondition {
        PathPostcondition(
            path: productsDirectory,
            validation: .nonEmptyDirectory)
    }

    public var lock: TaskLock {
        .shared(scratchPath.appending(".collider.lock"))
    }

    /// Stable Collider-owned access to SwiftPM's public binary output path.
    /// The SwiftPM action replaces this link from `swift build --show-bin-path`
    /// after every successful invocation.
    public var productsDirectory: FilePath {
        scratchPath.appending(".collider/products")
    }

    public var executionScratchPath: FilePath {
        guard case .oci(let configuration) = context.execution,
            configuration.buildWorkspace != nil
        else { return scratchPath }
        let identity = ArtifactDigest.sha256(context.identityBytes).hexadecimal
        return FilePath("/swiftpm-workspace").appending(identity)
    }

    public func executable(_ product: String) -> FilePath {
        productsDirectory.appending(product)
    }

    public func product(
        package: String,
        product: String,
        packageRoot: FilePath,
        environment: [String: String],
        prebuildTargets: [String] = [],
        expectedOutputs: [PathPostcondition] = []
    ) -> SwiftProductRequirement {
        let inputs =
            sourceGraph.inputs(forProduct: product)
            + (dependencyLock.map { [.file($0)] } ?? [])
            + dependencyConfigurationFiles.map(ArtifactInput.file)
        return SwiftProductRequirement(
            package: package,
            product: product,
            packageRoot: context.packageRoot,
            invocation: self,
            inputs: inputs,
            environment: environment,
            prebuildTargets: prebuildTargets,
            expectedOutputs: expectedOutputs)
    }

    public func testProduct(
        package: String,
        testProduct: String,
        packageRoot: FilePath,
        environment: [String: String],
        arguments: [String] = [],
        expectedBuildOutputs: [PathPostcondition] = []
    ) -> SwiftTestRequirement {
        let inputs =
            sourceGraph.testInputs
            + (dependencyLock.map { [.file($0)] } ?? [])
            + dependencyConfigurationFiles.map(ArtifactInput.file)
        return SwiftTestRequirement(
            package: package,
            testProduct: testProduct,
            packageRoot: context.packageRoot,
            invocation: self,
            inputs: inputs,
            environment: environment,
            arguments: arguments,
            expectedBuildOutputs: expectedBuildOutputs)
    }

    public func command(
        arguments: [String],
        workingDirectory: FilePath,
        environment: [String: String],
        output: CommandSpec.Output = .inherited
    ) -> CommandSpec {
        return CommandSpec(
            executable: swiftExecutable,
            arguments: commandArguments(arguments),
            workingDirectory: workingDirectory,
            environment: environment,
            output: output)
    }

    public func ociExecution(
        arguments: [String],
        workingDirectory: FilePath,
        environment: [String: String],
        output: CommandSpec.Output = .logged
    ) throws -> OCIExecution {
        guard case .oci(let configuration) = context.execution else {
            throw SwiftPMInvocationExecutionFailure.requiresOCIContext
        }
        var containerEnvironment = configuration.environmentProjection.project(
            environment)
        containerEnvironment.merge(
            configuration.containerEnvironment,
            uniquingKeysWith: { _, configured in configured })
        configurePersistentWorkspaceEnvironment(
            &containerEnvironment,
            configuration: configuration)
        let swiftPMCommand = ociSwiftPMCommand(
            arguments: arguments,
            configuration: configuration)
        if let executableName = swiftPMCommand.executableName {
            containerEnvironment["SWIFTPM_EXEC_NAME"] = executableName
        }
        return OCIExecution(
            executionPlatform: configuration.executionPlatform,
            artifactTarget: configuration.artifactTarget,
            imageID: configuration.imageID,
            hostname: configuration.hostname,
            workingDirectory: workingDirectory.string,
            hostWorkingDirectory: configuration.hostWorkingDirectory,
            mounts: ociMounts(configuration),
            persistentWorkspaceMounts: ociPersistentWorkspaceMounts(configuration),
            userPolicy: .builder,
            capabilityPolicy: .dropAll,
            privilegePolicy: .prohibitAcquisition,
            processFilesystemPolicy: configuration.processFilesystemPolicy,
            executableRequirements: configuration.executableRequirements,
            resourceLimits: configuration.resourceLimits,
            containerEnvironment: containerEnvironment,
            command: configuration.commandPrefix + processorAffinityArguments
                + [swiftPMCommand.executable]
                + swiftPMCommand.arguments,
            environment: environment,
            output: output)
    }

    private var ociSwiftExecutable: String {
        switch swiftExecutable {
        case .named(let name), .operationalNamed(let name):
            name
        case .path(let path), .taskOutput(let path):
            path.string
        case .artifact(let reference):
            reference.path.string
        }
    }

    private func ociSwiftPMCommand(
        arguments: [String],
        configuration: SwiftPMOCIExecution
    ) -> (executable: String, executableName: String?, arguments: [String]) {
        guard let executable = configuration.swiftPMExecutable,
            let subcommand = arguments.first
        else {
            return (ociSwiftExecutable, nil, commandArguments(arguments))
        }
        return (
            executable.string,
            "swift-\(subcommand)",
            contextArguments + arguments.dropFirst()
        )
    }

    public func ociExecutableExecution(
        executable: FilePath,
        arguments: [String],
        workingDirectory: FilePath,
        environment: [String: String]
    ) throws -> OCIExecution {
        guard case .oci(let configuration) = context.execution else {
            throw SwiftPMInvocationExecutionFailure.requiresOCIContext
        }
        return ociExecutableExecution(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            configuration: configuration)
    }

    private func ociExecutableExecution(
        executable: FilePath,
        arguments: [String],
        workingDirectory: FilePath,
        environment: [String: String],
        configuration: SwiftPMOCIExecution
    ) -> OCIExecution {
        var containerEnvironment = configuration.environmentProjection.project(
            environment)
        containerEnvironment.merge(
            configuration.containerEnvironment,
            uniquingKeysWith: { _, configured in configured })
        configurePersistentWorkspaceEnvironment(
            &containerEnvironment,
            configuration: configuration)
        return OCIExecution(
            executionPlatform: configuration.executionPlatform,
            artifactTarget: configuration.artifactTarget,
            imageID: configuration.imageID,
            hostname: configuration.hostname,
            workingDirectory: workingDirectory.string,
            hostWorkingDirectory: configuration.hostWorkingDirectory,
            mounts: ociMounts(configuration),
            persistentWorkspaceMounts: ociPersistentWorkspaceMounts(configuration),
            userPolicy: .builder,
            capabilityPolicy: .dropAll,
            privilegePolicy: .prohibitAcquisition,
            processFilesystemPolicy: configuration.processFilesystemPolicy,
            executableRequirements: configuration.executableRequirements,
            resourceLimits: configuration.resourceLimits,
            containerEnvironment: containerEnvironment,
            command: configuration.commandPrefix + processorAffinityArguments
                + [executable.string] + arguments,
            environment: environment,
            output: .logged)
    }

    private var processorAffinityArguments: [String] {
        let lastProcessor = context.maximumParallelism - 1
        return ["taskset", "--cpu-list", "0-\(lastProcessor)"]
    }

    public func commandArguments(_ arguments: [String]) -> [String] {
        guard let subcommand = arguments.first else {
            return contextArguments
        }
        return [subcommand] + contextArguments + arguments.dropFirst()
    }

    private var contextArguments: [String] {
        var arguments = [
            "--build-system", context.buildSystem.rawValue,
            "--configuration", context.configuration.rawValue,
            "--jobs", String(context.maximumParallelism),
            "--scratch-path", executionScratchPath.string,
            "--package-path", context.packageRoot.string,
        ]
        if let debugInformationFormat = context.debugInformationFormat {
            arguments += ["-debug-info-format", debugInformationFormat.rawValue]
        }
        if case .triple(let triple) = context.target {
            arguments += ["--triple", triple]
        }
        if case .swiftSDK(let name, let targetTriple) = context.target {
            if case .oci = context.execution {
                arguments += [
                    "--swift-sdks-path", Self.ociSwiftSDKDirectory.string,
                ]
            }
            arguments += ["--swift-sdk", name, "--triple", targetTriple]
        }
        for toolset in context.toolsets {
            arguments += ["--toolset", toolset.string]
        }
        if context.staticSwiftStandardLibrary {
            arguments.append("--static-swift-stdlib")
        }
        if dependencyLock != nil {
            arguments.append("--only-use-versions-from-resolved-file")
        }
        if let sanitizer = context.sanitizer {
            arguments += ["--sanitize", sanitizer]
        }
        if !context.traits.isEmpty {
            arguments += ["--traits", context.traits.joined(separator: ",")]
        }
        for flag in context.swiftFlags {
            arguments += ["-Xswiftc", flag]
        }
        for flag in context.cFlags {
            arguments += ["-Xcc", flag]
        }
        for flag in context.cxxFlags {
            arguments += ["-Xcxx", flag]
        }
        for flag in context.linkerFlags {
            arguments += ["-Xlinker", flag]
        }
        return arguments
    }

    private func ociMounts(_ configuration: SwiftPMOCIExecution) -> [OCIMount] {
        guard configuration.buildWorkspace != nil else { return configuration.mounts }
        return configuration.mounts + [
            OCIMount(
                source: scratchPath,
                target: "/swiftpm-input",
                access: .readOnly),
            OCIMount(
                boundedExport: productsDirectory,
                target: "/swiftpm-products"),
        ]
    }

    private func ociPersistentWorkspaceMounts(
        _ configuration: SwiftPMOCIExecution
    ) -> [OCIPersistentWorkspaceMount] {
        var mounts: [OCIPersistentWorkspaceMount] = []
        if let workspace = configuration.buildWorkspace {
            mounts.append(
                OCIPersistentWorkspaceMount(
                    workspace: workspace,
                    target: "/swiftpm-workspace",
                    access: .readWrite))
        }
        if let workspace = configuration.compilerCacheWorkspace {
            mounts.append(
                OCIPersistentWorkspaceMount(
                    workspace: workspace,
                    target: "/ccache",
                    access: .readWrite))
        }
        return mounts
    }

    private func configurePersistentWorkspaceEnvironment(
        _ environment: inout [String: String],
        configuration: SwiftPMOCIExecution
    ) {
        guard configuration.buildWorkspace != nil else { return }
        environment["NUCLEUS_SWIFTPM_INPUT"] = "/swiftpm-input"
        environment["NUCLEUS_SWIFTPM_SCRATCH"] = executionScratchPath.string
        environment["NUCLEUS_SWIFTPM_PRODUCTS"] = "/swiftpm-products"
        environment["NUCLEUS_SWIFTPM_HOST_PRODUCTS"] = productsDirectory.string
    }
}

/// One product that a task needs from the canonical Swift package. Recipes
/// declare requirements; ColliderRuntime unions them into one SwiftPM request.
public struct SwiftProductRequirement: Hashable, Sendable {
    public let package: String
    public let product: String
    public let packageRoot: FilePath
    public let invocation: SwiftPMInvocation
    public let inputs: [ArtifactInput]
    public let environment: [String: String]
    public let prebuildTargets: [String]
    public let expectedOutputs: [PathPostcondition]

    public init(
        package: String,
        product: String,
        packageRoot: FilePath,
        invocation: SwiftPMInvocation,
        inputs: [ArtifactInput],
        environment: [String: String],
        prebuildTargets: [String] = [],
        expectedOutputs: [PathPostcondition] = []
    ) {
        precondition(
            packageRoot == invocation.context.packageRoot,
            "Swift product requirement uses a different package root")
        precondition(!package.isEmpty, "Swift package identity is empty")
        precondition(!product.isEmpty, "Swift product name is empty")
        self.package = package
        self.product = product
        self.packageRoot = packageRoot
        self.invocation = invocation
        self.inputs = inputs
        self.environment = environment
        self.prebuildTargets = prebuildTargets
        self.expectedOutputs = expectedOutputs
    }

    public var qualifiedProduct: String {
        "\(package):\(product)"
    }
}

/// One independently attributed test product. Collider unions compilation for
/// these requirements, then runs each selected product without rebuilding it.
public struct SwiftTestRequirement: Hashable, Sendable {
    public let package: String
    public let testProduct: String
    public let packageRoot: FilePath
    public let invocation: SwiftPMInvocation
    public let inputs: [ArtifactInput]
    public let environment: [String: String]
    public let arguments: [String]
    public let expectedBuildOutputs: [PathPostcondition]

    public init(
        package: String,
        testProduct: String,
        packageRoot: FilePath,
        invocation: SwiftPMInvocation,
        inputs: [ArtifactInput],
        environment: [String: String],
        arguments: [String] = [],
        expectedBuildOutputs: [PathPostcondition] = []
    ) {
        precondition(
            packageRoot == invocation.context.packageRoot,
            "Swift test requirement uses a different package root")
        precondition(!package.isEmpty, "Swift package identity is empty")
        precondition(!testProduct.isEmpty, "Swift test product name is empty")
        self.package = package
        self.testProduct = testProduct
        self.packageRoot = packageRoot
        self.invocation = invocation
        self.inputs = inputs
        self.environment = environment
        self.arguments = arguments
        self.expectedBuildOutputs = expectedBuildOutputs
    }

    public var qualifiedProduct: String {
        "\(package):\(testProduct)"
    }
}

private func append(
    _ values: [String],
    into encoder: inout IdentityEncoder
) {
    // Compiler flags, not opaque strings: each one may carry a path.
    encoder.appendSequence(values) { $0.append(argument: $1) }
}

private func append(
    _ workspace: PersistentWorkspaceDeclaration,
    into encoder: inout IdentityEncoder
) {
    encoder.append(workspace.identity.key)
    encoder.appendEnum(workspace.identity.artifactTarget.operatingSystem)
    encoder.appendEnum(workspace.identity.artifactTarget.architecture)
    encoder.appendOptional(workspace.identity.artifactTarget.abi) { $0.append($1) }
    encoder.appendOptional(workspace.identity.artifactTarget.androidAPILevel) {
        $0.append(UInt64($1))
    }
    encoder.append(workspace.identity.role)
    encoder.append(workspace.capacityBytes)
    encoder.appendEnum(workspace.filesystem)
    encoder.appendEnum(workspace.journal.mode)
    encoder.append(workspace.journal.sizeBytes)
}
