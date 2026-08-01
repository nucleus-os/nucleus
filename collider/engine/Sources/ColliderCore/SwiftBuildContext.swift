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

/// Every setting that determines whether SwiftPM compilation artifacts may be
/// reused by another task.
public struct SwiftBuildContext: Hashable, Sendable {
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
    public let staticSwiftStandardLibrary: Bool

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
        staticSwiftStandardLibrary: Bool = false
    ) {
        precondition(packageRoot.isAbsolute && packageRoot.isLexicallyNormal)
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
        self.staticSwiftStandardLibrary = staticSwiftStandardLibrary
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
        encoder.append(
            tag: 12,
            integer: staticSwiftStandardLibrary ? 1 : 0)
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
        productsRoot.appending(
            "\(capitalizedConfiguration)-\(context.target.productsSuffix)")
    }

    public var generatedModuleMaps: FilePath {
        scratchPath.appending(
            "out/Intermediates.noindex/GeneratedModuleMaps-\(context.target.productsSuffix)")
    }

    public func executable(_ product: String) -> FilePath {
        configurationProducts.appending(product)
    }

    public func product(
        package: String,
        product: String,
        packageRoot: FilePath,
        environment: [String: String],
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
            expectedOutputs: expectedOutputs)
    }

    public func testProduct(
        package: String,
        testProduct: String,
        packageRoot: FilePath,
        environment: [String: String],
        arguments: [String] = []
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
            arguments: arguments)
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
        if case .swiftSDK(_, let triple) = context.target,
            triple.contains("android")
        {
            environment["NUCLEUS_TARGET_PLATFORM"] = "android"
        } else {
            environment.removeValue(forKey: "NUCLEUS_TARGET_PLATFORM")
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
            "--scratch-path", scratchPath.string,
            "--package-path", context.packageRoot.string,
        ]
        if case .triple(let triple) = context.target {
            arguments += ["--triple", triple]
        }
        if case .swiftSDK(let name, let targetTriple) = context.target {
            arguments += ["--swift-sdk", name, "--triple", targetTriple]
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
    public let expectedOutputs: [PathPostcondition]

    public init(
        package: String,
        product: String,
        packageRoot: FilePath,
        invocation: SwiftPMInvocation,
        inputs: [ArtifactInput],
        environment: [String: String],
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

    public init(
        package: String,
        testProduct: String,
        packageRoot: FilePath,
        invocation: SwiftPMInvocation,
        inputs: [ArtifactInput],
        environment: [String: String],
        arguments: [String] = []
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
