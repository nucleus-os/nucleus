import SystemPackage

public enum SwiftBuildConfiguration: String, Hashable, Sendable {
    case debug
    case release
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
    public let image: ArtifactReference<FileArtifact>
    public let hostname: String
    public let hostWorkingDirectory: FilePath
    public let mounts: [OCIMount]
    public let temporaryDirectory: FilePath?
    public let processFilesystemPolicy: OCIProcessFilesystemPolicy
    public let intelBinaryTranslationPolicy: OCIIntelBinaryTranslationPolicy
    public let resourceLimits: OCIResourceLimits
    public let containerEnvironment: [String: String]
    public let commandPrefix: [String]

    public init(
        executionPlatform: ExecutionPlatform,
        artifactTarget: ArtifactTarget,
        image: ArtifactReference<FileArtifact>,
        hostname: String,
        hostWorkingDirectory: FilePath,
        mounts: [OCIMount],
        temporaryDirectory: FilePath? = nil,
        processFilesystemPolicy: OCIProcessFilesystemPolicy = .standard,
        intelBinaryTranslationPolicy: OCIIntelBinaryTranslationPolicy = .disabled,
        resourceLimits: OCIResourceLimits = .build,
        containerEnvironment: [String: String] = [:],
        commandPrefix: [String] = ["swiftpm"]
    ) {
        precondition(executionPlatform == .linuxARM64OCI)
        self.executionPlatform = executionPlatform
        self.artifactTarget = artifactTarget
        self.image = image
        self.hostname = hostname
        self.hostWorkingDirectory = hostWorkingDirectory
        self.mounts = mounts
        self.temporaryDirectory = temporaryDirectory
        self.processFilesystemPolicy = processFilesystemPolicy
        self.intelBinaryTranslationPolicy = intelBinaryTranslationPolicy
        self.resourceLimits = resourceLimits
        self.containerEnvironment = containerEnvironment
        self.commandPrefix = commandPrefix
    }

    public var imageID: FilePath { image.path }
}

/// The complete SwiftPM invocation context. `identityBytes` contains only the
/// settings that determine whether compilation artifacts may be reused.
public struct SwiftBuildContext: Hashable, Sendable {
    public static let defaultMaximumParallelism: UInt32 = 10
    public static let concurrentOCIMaximumParallelism: UInt32 = 8

    public let packageRoot: FilePath
    public let configuration: SwiftBuildConfiguration
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

    public init(
        packageRoot: FilePath,
        configuration: SwiftBuildConfiguration,
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
        execution: SwiftPMExecution = .host
    ) {
        precondition(packageRoot.isAbsolute && packageRoot.isLexicallyNormal)
        precondition(maximumParallelism > 0)
        self.packageRoot = packageRoot
        self.configuration = configuration
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
    }

    /// Stable canonical bytes used both in task identity and to derive the
    /// package scratch directory.
    public var identityBytes: [UInt8] {
        identityBytes(identityPathMap: .empty)
    }

    public func identityBytes(identityPathMap: IdentityPathMap) -> [UInt8] {
        var encoder = CanonicalDigestEncoder(identityPathMap: identityPathMap)
        encoder.append(tag: 13, string: packageRoot.string)
        encoder.append(tag: 1, string: configuration.rawValue)
        switch target {
        case .host(let identity):
            encoder.append(tag: 2, string: "host")
            encoder.append(tag: 3, string: identity)
        case .triple(let triple):
            encoder.append(tag: 2, string: "triple")
            encoder.append(tag: 3, string: triple)
        case .swiftSDK(let name, let targetTriple):
            encoder.append(tag: 2, string: "swift-sdk")
            encoder.append(tag: 3, string: name)
            encoder.append(tag: 10, string: targetTriple)
        }
        encoder.append(tag: 4, string: toolchainIdentity)
        encoder.append(tag: 5, string: sanitizer ?? "<none>")
        append(traits, tag: 6, into: &encoder)
        append(swiftFlags, tag: 7, into: &encoder)
        append(cFlags, tag: 8, into: &encoder)
        append(cxxFlags, tag: 9, into: &encoder)
        append(linkerFlags, tag: 11, into: &encoder)
        for toolset in toolsets {
            encoder.append(tag: 26, string: toolset.string)
        }
        encoder.append(
            tag: 12,
            integer: staticSwiftStandardLibrary ? 1 : 0)
        switch execution {
        case .host:
            encoder.append(tag: 14, string: "host")
        case .oci(let configuration):
            encoder.append(tag: 14, string: "oci")
            encoder.append(
                tag: 15,
                string: configuration.executionPlatform.operatingSystem.rawValue)
            encoder.append(
                tag: 16,
                string: configuration.executionPlatform.architecture.rawValue)
            encoder.append(
                tag: 17,
                string: configuration.artifactTarget.operatingSystem.rawValue)
            encoder.append(
                tag: 18,
                string: configuration.artifactTarget.architecture.rawValue)
            encoder.append(tag: 19, string: configuration.imageID.string)
            encoder.append(
                tag: 20,
                string: configuration.intelBinaryTranslationPolicy.rawValue)
            for mount in configuration.mounts {
                encoder.append(tag: 21, string: mount.source.string)
                encoder.append(tag: 22, string: mount.target)
                encoder.append(tag: 23, string: mount.access.rawValue)
            }
            for argument in configuration.commandPrefix {
                encoder.append(tag: 24, string: argument)
            }
        }
        return encoder.bytes
    }
}

/// The shared construction contract for SwiftPM-backed task declarations.
public struct SwiftPMInvocation: Hashable, Sendable {
    public let context: SwiftBuildContext
    public let scratchPath: FilePath
    public let swiftExecutable: CommandSpec.Executable

    public init(
        context: SwiftBuildContext,
        scratchPath: FilePath,
        swiftExecutable: CommandSpec.Executable = .named("swift")
    ) {
        self.context = context
        self.scratchPath = scratchPath
        self.swiftExecutable = swiftExecutable
    }

    /// Typed artifacts required to execute this invocation. Logical SwiftPM
    /// requirements retain these producer edges so selection includes every
    /// prerequisite before the requirements are lowered into physical tasks.
    public var artifactReferences: [AnyArtifactReference] {
        var references: [AnyArtifactReference] = []
        if case .artifact(let compiler) = swiftExecutable {
            references.append(compiler)
        }
        if case .oci(let configuration) = context.execution {
            references.append(AnyArtifactReference(configuration.image))
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
        let inputs: [ArtifactInput]
        switch context.execution {
        case .host:
            inputs = []
        case .oci:
            inputs = [
                .file(context.packageRoot.appending("Package.swift")),
                .optionalTree(
                    packageRoot.appending("Sources"),
                    fallback: Array("no-sources-directory".utf8)),
            ]
        }
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
        let inputs: [ArtifactInput]
        switch context.execution {
        case .host:
            inputs = []
        case .oci:
            inputs = [
                .file(context.packageRoot.appending("Package.swift")),
                .optionalTree(
                    packageRoot.appending("Sources"),
                    fallback: Array("no-sources-directory".utf8)),
                .optionalTree(
                    packageRoot.appending("Tests"),
                    fallback: Array("no-tests-directory".utf8)),
            ]
        }
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
        var containerEnvironment: [String: String] = [:]
        for (name, value) in environment
        where containerEnvironmentVariable(name) {
            containerEnvironment[name] = value
        }
        containerEnvironment.merge(
            configuration.containerEnvironment,
            uniquingKeysWith: { _, configured in configured })
        return OCIExecution(
            executionPlatform: configuration.executionPlatform,
            artifactTarget: configuration.artifactTarget,
            imageID: configuration.imageID,
            hostname: configuration.hostname,
            workingDirectory: workingDirectory.string,
            hostWorkingDirectory: configuration.hostWorkingDirectory,
            mounts: configuration.mounts,
            temporaryDirectory: configuration.temporaryDirectory,
            networkPolicy: .externalDisabled,
            userPolicy: .builder,
            capabilityPolicy: .dropAll,
            privilegePolicy: .prohibitAcquisition,
            processFilesystemPolicy: configuration.processFilesystemPolicy,
            intelBinaryTranslationPolicy: configuration.intelBinaryTranslationPolicy,
            resourceLimits: configuration.resourceLimits,
            containerEnvironment: containerEnvironment,
            command: configuration.commandPrefix + processorAffinityArguments
                + [ociSwiftExecutable]
                + commandArguments(arguments),
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
        var containerEnvironment: [String: String] = [:]
        for (name, value) in environment
        where containerEnvironmentVariable(name) {
            containerEnvironment[name] = value
        }
        containerEnvironment.merge(
            configuration.containerEnvironment,
            uniquingKeysWith: { _, configured in configured })
        return OCIExecution(
            executionPlatform: configuration.executionPlatform,
            artifactTarget: configuration.artifactTarget,
            imageID: configuration.imageID,
            hostname: configuration.hostname,
            workingDirectory: workingDirectory.string,
            hostWorkingDirectory: configuration.hostWorkingDirectory,
            mounts: configuration.mounts,
            temporaryDirectory: configuration.temporaryDirectory,
            networkPolicy: .externalDisabled,
            userPolicy: .builder,
            capabilityPolicy: .dropAll,
            privilegePolicy: .prohibitAcquisition,
            processFilesystemPolicy: configuration.processFilesystemPolicy,
            intelBinaryTranslationPolicy: configuration.intelBinaryTranslationPolicy,
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
            "--build-system", "swiftbuild",
            "--configuration", context.configuration.rawValue,
            "--jobs", String(context.maximumParallelism),
            "--scratch-path", scratchPath.string,
            "--package-path", context.packageRoot.string,
        ]
        if case .triple(let triple) = context.target {
            arguments += ["--triple", triple]
        }
        if case .swiftSDK(let name, let targetTriple) = context.target {
            arguments += ["--swift-sdk", name, "--triple", targetTriple]
        }
        for toolset in context.toolsets {
            arguments += ["--toolset", toolset.string]
        }
        if context.staticSwiftStandardLibrary {
            arguments.append("--static-swift-stdlib")
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

private func containerEnvironmentVariable(_ name: String) -> Bool {
    if name == "NUCLEUS_NATIVE_SDK_ROOT" {
        return false
    }
    return name.hasPrefix("NUCLEUS_")
        || name.hasPrefix("SWIFTPM_")
        || name.hasPrefix("CCACHE_")
        || ["LANG", "LC_ALL", "TZ", "TERM"].contains(name)
}

private func append(
    _ values: [String],
    tag: UInt8,
    into encoder: inout CanonicalDigestEncoder
) {
    for value in values {
        encoder.append(tag: tag, string: value)
    }
}
