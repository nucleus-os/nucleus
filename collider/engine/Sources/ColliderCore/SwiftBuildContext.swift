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

public struct SwiftPMOCIExecution: Hashable, Sendable {
    public let executionPlatform: ExecutionPlatform
    public let artifactTarget: ArtifactTarget
    public let imageID: FilePath
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
        imageID: FilePath,
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
        self.imageID = imageID
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
}

/// Every setting that determines whether SwiftPM compilation artifacts may be
/// reused by another task.
public struct SwiftBuildContext: Hashable, Sendable {
    public static let defaultMaximumParallelism: UInt32 = 10

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
        var encoder = CanonicalDigestEncoder()
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
        encoder.append(tag: 25, integer: UInt64(maximumParallelism))
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

    public init(
        context: SwiftBuildContext,
        scratchPath: FilePath
    ) {
        self.context = context
        self.scratchPath = scratchPath
    }

    public var identityInput: ArtifactInput {
        .value(name: "swift-build-context", bytes: context.identityBytes)
    }

    public var postcondition: PathPostcondition {
        PathPostcondition(
            path: scratchPath,
            validation: .nonEmptyDirectory)
    }

    public var lock: TaskLock {
        .shared(scratchPath.appending(".collider.lock"))
    }

    public var productsRoot: FilePath {
        scratchPath.appending("out/Products")
    }

    public var configurationProducts: FilePath {
        switch context.target {
        case .host:
            productsRoot.appending(capitalizedConfiguration)
        case .triple, .swiftSDK:
            productsRoot.appending(
                "\(capitalizedConfiguration)-\(context.target.productsSuffix)")
        }
    }

    public var generatedModuleMaps: FilePath {
        switch context.target {
        case .host:
            scratchPath.appending(
                "out/Intermediates.noindex/GeneratedModuleMaps")
        case .triple, .swiftSDK:
            scratchPath.appending(
                "out/Intermediates.noindex/GeneratedModuleMaps-\(context.target.productsSuffix)")
        }
    }

    public func executable(_ product: String) -> FilePath {
        configurationProducts.appending(product)
    }

    public func product(
        package: String,
        product: String,
        packageRoot: FilePath,
        environment: [String: String],
        prebuildTargets: [String] = [],
        expectedOutputs: [PathPostcondition] = []
    ) -> SwiftProductRequirement {
        SwiftProductRequirement(
            package: package,
            product: product,
            packageRoot: context.packageRoot,
            invocation: self,
            inputs: [
                .file(context.packageRoot.appending("Package.swift")),
                .optionalTree(
                    packageRoot.appending("Sources"),
                    fallback: Array("no-sources-directory".utf8)),
            ],
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
        SwiftTestRequirement(
            package: package,
            testProduct: testProduct,
            packageRoot: context.packageRoot,
            invocation: self,
            inputs: [
                .file(context.packageRoot.appending("Package.swift")),
                .optionalTree(
                    packageRoot.appending("Sources"),
                    fallback: Array("no-sources-directory".utf8)),
                .optionalTree(
                    packageRoot.appending("Tests"),
                    fallback: Array("no-tests-directory".utf8)),
            ],
            environment: environment,
            arguments: arguments,
            expectedBuildOutputs: expectedBuildOutputs)
    }

    public func generatedSwiftHeader(_ module: String) -> FilePath {
        generatedModuleMaps.appending("\(module)-Swift.h")
    }

    public func command(
        arguments: [String],
        workingDirectory: FilePath,
        environment: [String: String]
    ) -> CommandSpec {
        return CommandSpec(
            executable: .named("swift"),
            arguments: commandArguments(arguments),
            workingDirectory: workingDirectory,
            environment: commandEnvironment(environment))
    }

    public func operation(
        arguments: [String],
        workingDirectory: FilePath,
        environment: [String: String]
    ) -> TaskOperation {
        switch context.execution {
        case .host:
            return .command(
                command(
                    arguments: arguments,
                    workingDirectory: workingDirectory,
                    environment: environment))
        case .oci(let configuration):
            var containerEnvironment: [String: String] = [:]
            for (name, value) in commandEnvironment(environment)
            where containerEnvironmentVariable(name) {
                containerEnvironment[name] = value
            }
            containerEnvironment.merge(
                configuration.containerEnvironment,
                uniquingKeysWith: { _, configured in configured })
            return .runOCI(
                OCIExecution(
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
                    command: configuration.commandPrefix + processorAffinityArguments + ["swift"]
                        + commandArguments(arguments),
                    environment: environment,
                    output: .logged))
        }
    }

    /// Executes a built product in the same host or OCI context that produced it.
    public func operation(
        executable: FilePath,
        arguments: [String],
        workingDirectory: FilePath,
        environment: [String: String]
    ) -> TaskOperation {
        switch context.execution {
        case .host:
            return .command(
                CommandSpec(
                    executable: .taskOutput(executable),
                    arguments: arguments,
                    workingDirectory: workingDirectory,
                    environment: commandEnvironment(environment)))
        case .oci(let configuration):
            var containerEnvironment: [String: String] = [:]
            for (name, value) in commandEnvironment(environment)
            where containerEnvironmentVariable(name) {
                containerEnvironment[name] = value
            }
            containerEnvironment.merge(
                configuration.containerEnvironment,
                uniquingKeysWith: { _, configured in configured })
            return .runOCI(
                OCIExecution(
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
                    output: .logged))
        }
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

    public func commandEnvironment(
        _ environment: [String: String]
    ) -> [String: String] {
        var environment = environment
        environment["NUCLEUS_SWIFTPM_SCRATCH_PATH"] = scratchPath.string
        environment["NUCLEUS_SWIFTPM_GENERATED_MODULE_MAPS_PATH"] =
            generatedModuleMaps.string
        if let sanitizer = context.sanitizer {
            environment["NUCLEUS_SWIFTPM_SANITIZER"] = sanitizer
        } else {
            environment.removeValue(forKey: "NUCLEUS_SWIFTPM_SANITIZER")
        }
        return environment
    }

    private var capitalizedConfiguration: String {
        let configuration = context.configuration.rawValue
        return configuration.prefix(1).uppercased()
            + configuration.dropFirst()
    }

    private var contextArguments: [String] {
        var arguments = [
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

extension SwiftBuildTarget {
    fileprivate var productsSuffix: String {
        switch self {
        case .host(let identity):
            let parts = identity.split(separator: "-", maxSplits: 1)
            precondition(
                parts.count == 2,
                "host Swift target identity must be <architecture>-<platform>")
            return "\(productsPlatform(String(parts[1])))-\(parts[0])"
        case .triple(let triple):
            return targetProductsSuffix(forTriple: triple)
        case .swiftSDK(_, let targetTriple):
            return targetProductsSuffix(forTriple: targetTriple)
        }
    }
}

private func targetProductsSuffix(forTriple triple: String) -> String {
    let parts = triple.split(separator: "-")
    precondition(
        parts.count >= 3,
        "Swift target triple must contain architecture, vendor, and platform")
    let platforms = parts.dropFirst(2)
    let platform: String
    if platforms.contains(where: { $0.hasPrefix("android") }) {
        platform = "android"
    } else if let macOS = platforms.first(where: { $0.hasPrefix("macos") }) {
        platform = String(macOS)
    } else {
        platform = String(
            platforms.first(where: { $0 == "linux" }) ?? parts[2])
    }
    return "\(productsPlatform(platform))-\(parts[0])"
}

private func containerEnvironmentVariable(_ name: String) -> Bool {
    name.hasPrefix("NUCLEUS_")
        || name.hasPrefix("SWIFTPM_")
        || name.hasPrefix("CCACHE_")
        || ["LANG", "LC_ALL", "TZ", "TERM"].contains(name)
}

private func productsPlatform(_ platform: String) -> String {
    platform == "macos" ? "macosx" : platform
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
