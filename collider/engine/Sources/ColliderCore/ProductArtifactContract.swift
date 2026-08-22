import SystemPackage

public struct ProductArtifactID: RawRepresentable, Codable, Hashable, Sendable,
    CustomStringConvertible
{
    public let rawValue: ArtifactDigest

    public init(rawValue: ArtifactDigest) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.description }
}

public enum ProductArtifactProducerTrustDomain: String, Codable, Hashable, Sendable {
    case localDeveloper = "local-developer"
    case nucleusBuilder = "nucleus-builder"
}

public enum ProductArtifactSourceAuthority: String, CaseIterable, Codable, Hashable,
    Sendable
{
    case localDevelopment = "local-development"
    case protectedMain = "protected-main"
}

public struct ProductArtifactProvenanceID: RawRepresentable, Codable, Hashable,
    Sendable, CustomStringConvertible
{
    public let rawValue: ArtifactDigest

    public init(rawValue: ArtifactDigest) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.description }
}

public struct ProductArtifactProvenance: Codable, Hashable, Sendable {
    public let baseCommit: String?
    public let branch: String?
    public let dirtyPaths: [String]
    public let sourceAuthority: ProductArtifactSourceAuthority

    public init(
        baseCommit: String?,
        branch: String?,
        dirtyPaths: [String],
        sourceAuthority: ProductArtifactSourceAuthority
    ) throws {
        self.baseCommit = baseCommit
        self.branch = branch
        self.dirtyPaths = Array(Set(dirtyPaths)).sorted()
        self.sourceAuthority = sourceAuthority
        try validate()
    }

    public func validate() throws {
        try requireCanonicalOrder(dirtyPaths, name: "dirty path")
        for path in dirtyPaths {
            try requirePortableRelativePath(path, allowsRoot: false)
        }
        if sourceAuthority == .protectedMain {
            guard let baseCommit, isFullGitCommit(baseCommit) else {
                throw ProductArtifactContractFailure(
                    "protected-main provenance requires an exact base commit")
            }
            guard branch == "refs/heads/main" else {
                throw ProductArtifactContractFailure(
                    "protected-main provenance requires refs/heads/main")
            }
            guard dirtyPaths.isEmpty else {
                throw ProductArtifactContractFailure(
                    "protected-main provenance cannot contain dirty paths")
            }
        }
    }

    public var identity: ProductArtifactProvenanceID {
        var encoder = IdentityEncoder()
        encoder.append("product-artifact-provenance")
        encoder.appendOptional(baseCommit) { $0.append($1) }
        encoder.appendOptional(branch) { $0.append($1) }
        encoder.appendSequence(dirtyPaths) { $0.append($1) }
        encoder.appendEnum(sourceAuthority)
        return ProductArtifactProvenanceID(rawValue: .sha256(encoder.bytes))
    }
}

public struct ProductArtifactSourceClosure: Codable, Hashable, Sendable {
    public let relativePath: String
    public let digest: ArtifactDigest

    public init(relativePath: String, digest: ArtifactDigest) {
        self.relativePath = relativePath
        self.digest = digest
    }
}

public struct ProductArtifactNamedIdentity: Codable, Hashable, Sendable {
    public let name: String
    public let digest: ArtifactDigest

    public init(name: String, digest: ArtifactDigest) {
        self.name = name
        self.digest = digest
    }
}

public enum ProductArtifactFileKind: String, Codable, Hashable, Sendable {
    case directory
    case regular
    case symbolicLink = "symbolic-link"
}

public struct ProductArtifactFile: Codable, Hashable, Sendable {
    public let relativePath: String
    public let kind: ProductArtifactFileKind
    public let digest: ArtifactDigest?
    public let ownerExecutable: Bool
    public let symbolicLinkTarget: String?

    public init(
        relativePath: String,
        kind: ProductArtifactFileKind,
        digest: ArtifactDigest? = nil,
        ownerExecutable: Bool = false,
        symbolicLinkTarget: String? = nil
    ) {
        self.relativePath = relativePath
        self.kind = kind
        self.digest = digest
        self.ownerExecutable = ownerExecutable
        self.symbolicLinkTarget = symbolicLinkTarget
    }
}

public struct ProductArtifactExecutable: Codable, Hashable, Sendable {
    public let relativePath: String
    public let digest: ArtifactDigest
    public let format: String
    public let architecture: PlatformArchitecture
    public let dynamicLibraries: [String]

    public init(
        relativePath: String,
        digest: ArtifactDigest,
        format: String,
        architecture: PlatformArchitecture,
        dynamicLibraries: [String]
    ) {
        self.relativePath = relativePath
        self.digest = digest
        self.format = format
        self.architecture = architecture
        self.dynamicLibraries = Array(Set(dynamicLibraries)).sorted()
    }
}

public struct ProductArtifactExecutableDeclaration: Codable, Hashable, Sendable {
    public let relativePath: String
    public let format: String
    public let architecture: PlatformArchitecture
    public let dynamicLibraries: [String]

    public init(
        relativePath: String,
        format: String,
        architecture: PlatformArchitecture,
        dynamicLibraries: [String]
    ) {
        self.relativePath = relativePath
        self.format = format
        self.architecture = architecture
        self.dynamicLibraries = Array(Set(dynamicLibraries)).sorted()
    }
}

public enum ProductArtifactQualificationRole: String, Codable, CaseIterable,
    Hashable, Sendable
{
    case bundleIntegrity = "bundle-integrity"
    case nativeLinuxKernel = "native-linux-kernel"
    case nativeLinuxPerformance = "native-linux-performance"
    case physicalGPU = "physical-gpu"
    case physicalDRM = "physical-drm"
    case release
}

public struct ProductArtifactManifest: Codable, Hashable, Sendable {
    public let sourceClosure: ArtifactDigest
    public let submoduleClosures: [ProductArtifactSourceClosure]
    public let producingTask: TaskID
    public let runnerPlatform: RunnerPlatform
    public let executionPlatform: ExecutionPlatform
    public let artifactTarget: ArtifactTarget
    public let toolchainIdentity: ArtifactDigest
    public let swiftSDKIdentity: ArtifactDigest?
    public let nativeSDKIdentities: [ProductArtifactNamedIdentity]
    public let builderImageIdentity: ArtifactDigest?
    public let buildConfiguration: SwiftBuildConfiguration
    public let semanticBuildArguments: [String]
    public let targetFilesystemRoots: [String]
    public let archiveDigest: ArtifactDigest
    public let treeDigest: ArtifactDigest
    public let files: [ProductArtifactFile]
    public let executables: [ProductArtifactExecutable]
    public let producerTrustDomain: ProductArtifactProducerTrustDomain
    public let requiredQualificationRoles: [ProductArtifactQualificationRole]

    public init(
        sourceClosure: ArtifactDigest,
        submoduleClosures: [ProductArtifactSourceClosure],
        producingTask: TaskID,
        runnerPlatform: RunnerPlatform,
        executionPlatform: ExecutionPlatform,
        artifactTarget: ArtifactTarget,
        toolchainIdentity: ArtifactDigest,
        swiftSDKIdentity: ArtifactDigest? = nil,
        nativeSDKIdentities: [ProductArtifactNamedIdentity] = [],
        builderImageIdentity: ArtifactDigest? = nil,
        buildConfiguration: SwiftBuildConfiguration,
        semanticBuildArguments: [String],
        targetFilesystemRoots: [String] = [],
        archiveDigest: ArtifactDigest,
        treeDigest: ArtifactDigest,
        files: [ProductArtifactFile],
        executables: [ProductArtifactExecutable],
        producerTrustDomain: ProductArtifactProducerTrustDomain,
        requiredQualificationRoles: [ProductArtifactQualificationRole],
        identityPathMap: IdentityPathMap = .empty
    ) throws {
        self.sourceClosure = sourceClosure
        self.submoduleClosures = submoduleClosures.sorted {
            $0.relativePath < $1.relativePath
        }
        self.producingTask = producingTask
        self.runnerPlatform = runnerPlatform
        self.executionPlatform = executionPlatform
        self.artifactTarget = artifactTarget
        self.toolchainIdentity = toolchainIdentity
        self.swiftSDKIdentity = swiftSDKIdentity
        self.nativeSDKIdentities = nativeSDKIdentities.sorted { $0.name < $1.name }
        self.builderImageIdentity = builderImageIdentity
        self.buildConfiguration = buildConfiguration
        self.semanticBuildArguments = try semanticBuildArguments.map {
            try identityPathMap.canonicalizePortable($0)
        }
        self.targetFilesystemRoots = targetFilesystemRoots.sorted()
        self.archiveDigest = archiveDigest
        self.treeDigest = treeDigest
        self.files = files.sorted { $0.relativePath < $1.relativePath }
        self.executables = executables.sorted { $0.relativePath < $1.relativePath }
        self.producerTrustDomain = producerTrustDomain
        self.requiredQualificationRoles = Array(Set(requiredQualificationRoles)).sorted {
            $0.rawValue < $1.rawValue
        }
        try validate()
    }

    public var identity: ProductArtifactID {
        ProductArtifactID(rawValue: .sha256(identityBytes))
    }

    public func validate() throws {
        try requireDigest(sourceClosure, name: "source closure")
        try requireDigest(toolchainIdentity, name: "toolchain")
        if let swiftSDKIdentity {
            try requireDigest(swiftSDKIdentity, name: "Swift SDK")
        }
        if let builderImageIdentity {
            try requireDigest(builderImageIdentity, name: "builder image")
        }
        try requireDigest(archiveDigest, name: "archive")
        try requireDigest(treeDigest, name: "tree")
        guard !producingTask.rawValue.isEmpty else {
            throw ProductArtifactContractFailure("producing task identity is empty")
        }
        try requireCanonicalOrder(
            submoduleClosures.map(\.relativePath),
            name: "submodule closure path")
        for closure in submoduleClosures {
            try requirePortableRelativePath(closure.relativePath, allowsRoot: false)
            try requireDigest(closure.digest, name: "submodule closure")
        }
        try requireCanonicalOrder(
            nativeSDKIdentities.map(\.name),
            name: "native SDK name")
        for identity in nativeSDKIdentities {
            guard !identity.name.isEmpty else {
                throw ProductArtifactContractFailure("native SDK name is empty")
            }
            try requireDigest(identity.digest, name: "native SDK")
        }
        for argument in semanticBuildArguments {
            _ = try IdentityPathMap.empty.canonicalizePortable(argument)
        }
        try requireCanonicalOrder(
            targetFilesystemRoots,
            name: "target filesystem root")
        let targetRoots = try targetFilesystemRoots.map { value -> FilePath in
            let path = FilePath(value)
            guard path.isAbsolute, path.isLexicallyNormal, value != "/" else {
                throw ProductArtifactContractFailure(
                    "target filesystem root is not a canonical absolute path: \(value)")
            }
            return path
        }
        try requireCanonicalOrder(
            files.map(\.relativePath),
            name: "artifact file path")
        let filesByPath = Dictionary(
            uniqueKeysWithValues: files.map {
                ($0.relativePath, $0)
            })
        for file in files {
            try requirePortableRelativePath(file.relativePath, allowsRoot: false)
            switch file.kind {
            case .regular:
                guard let digest = file.digest, file.symbolicLinkTarget == nil else {
                    throw ProductArtifactContractFailure(
                        "regular artifact file has invalid metadata: \(file.relativePath)")
                }
                try requireDigest(digest, name: "artifact file")
            case .symbolicLink:
                guard file.digest == nil, file.symbolicLinkTarget?.isEmpty == false else {
                    throw ProductArtifactContractFailure(
                        "artifact symlink has invalid metadata: \(file.relativePath)")
                }
                if let target = file.symbolicLinkTarget {
                    let path = FilePath(target)
                    if path.isAbsolute {
                        guard path.isLexicallyNormal,
                            targetRoots.contains(where: { path.isContained(in: $0) })
                        else {
                            throw PortableIdentityPathFailure.unrecognizedAbsoluteHostPath(
                                target)
                        }
                    } else {
                        _ = try IdentityPathMap.empty.canonicalizePortable(target)
                    }
                }
            case .directory:
                guard file.digest == nil, file.symbolicLinkTarget == nil
                else {
                    throw ProductArtifactContractFailure(
                        "artifact directory has invalid metadata: \(file.relativePath)")
                }
            }
        }
        try requireCanonicalOrder(
            executables.map(\.relativePath),
            name: "executable path")
        for executable in executables {
            guard let file = filesByPath[executable.relativePath],
                file.kind == .regular,
                file.ownerExecutable,
                file.digest == executable.digest
            else {
                throw ProductArtifactContractFailure(
                    "executable does not match an executable artifact file: "
                        + executable.relativePath)
            }
            guard !executable.format.isEmpty else {
                throw ProductArtifactContractFailure(
                    "executable format is empty: \(executable.relativePath)")
            }
            try requireCanonicalOrder(
                executable.dynamicLibraries,
                name: "dynamic-library identity")
            for library in executable.dynamicLibraries {
                guard !library.isEmpty else {
                    throw ProductArtifactContractFailure(
                        "dynamic-library identity is empty: \(executable.relativePath)")
                }
                _ = try IdentityPathMap.empty.canonicalizePortable(library)
            }
        }
        try requireCanonicalOrder(
            requiredQualificationRoles.map(\.rawValue),
            name: "qualification role")
    }

    private var identityBytes: [UInt8] {
        var encoder = IdentityEncoder()
        encoder.append("product-artifact")
        encoder.append(digest: sourceClosure)
        encoder.appendSequence(submoduleClosures) { entry, closure in
            entry.append(closure.relativePath)
            entry.append(digest: closure.digest)
        }
        encoder.append(producingTask.rawValue)
        encoder.append(platform: runnerPlatform)
        encoder.append(platform: executionPlatform)
        encoder.append(target: artifactTarget)
        encoder.append(digest: toolchainIdentity)
        encoder.appendOptional(swiftSDKIdentity) { $0.append(digest: $1) }
        encoder.appendSequence(nativeSDKIdentities) { entry, identity in
            entry.append(identity.name)
            entry.append(digest: identity.digest)
        }
        encoder.appendOptional(builderImageIdentity) { $0.append(digest: $1) }
        encoder.appendEnum(buildConfiguration)
        encoder.appendSequence(semanticBuildArguments) { $0.append($1) }
        encoder.appendSequence(targetFilesystemRoots) { $0.append($1) }
        encoder.append(digest: archiveDigest)
        encoder.append(digest: treeDigest)
        encoder.appendSequence(files) { entry, file in
            entry.append(file.relativePath)
            entry.appendEnum(file.kind)
            entry.appendOptional(file.digest) { $0.append(digest: $1) }
            entry.append(file.ownerExecutable)
            entry.appendOptional(file.symbolicLinkTarget) { $0.append($1) }
        }
        encoder.appendSequence(executables) { entry, executable in
            entry.append(executable.relativePath)
            entry.append(digest: executable.digest)
            entry.append(executable.format)
            entry.appendEnum(executable.architecture)
            entry.appendSequence(executable.dynamicLibraries) { $0.append($1) }
        }
        encoder.appendEnum(producerTrustDomain)
        encoder.appendSequence(requiredQualificationRoles) { $0.appendEnum($1) }
        return encoder.bytes
    }
}

public struct ProductArtifactEnvelope: Codable, Hashable, Sendable {
    public let identity: ProductArtifactID
    public let provenanceIdentity: ProductArtifactProvenanceID
    public let manifest: ProductArtifactManifest
    public let provenance: ProductArtifactProvenance

    public init(
        manifest: ProductArtifactManifest,
        provenance: ProductArtifactProvenance
    ) throws {
        try manifest.validate()
        try provenance.validate()
        identity = manifest.identity
        provenanceIdentity = provenance.identity
        self.manifest = manifest
        self.provenance = provenance
    }

    public func validate() throws {
        try manifest.validate()
        try provenance.validate()
        guard identity == manifest.identity else {
            throw ProductArtifactContractFailure(
                "product artifact identity does not match its manifest")
        }
        guard provenanceIdentity == provenance.identity else {
            throw ProductArtifactContractFailure(
                "product artifact provenance identity does not match its record")
        }
    }
}

public struct ProductArtifactQualificationCapability: Codable, Hashable, Sendable {
    public let runnerPlatform: RunnerPlatform
    public let executionPlatform: ExecutionPlatform
    public let physicalHardware: Bool
    public let binaryTranslation: Bool

    public init(
        runnerPlatform: RunnerPlatform,
        executionPlatform: ExecutionPlatform,
        physicalHardware: Bool,
        binaryTranslation: Bool
    ) {
        self.runnerPlatform = runnerPlatform
        self.executionPlatform = executionPlatform
        self.physicalHardware = physicalHardware
        self.binaryTranslation = binaryTranslation
    }

    public func validate(for role: ProductArtifactQualificationRole) throws {
        switch role {
        case .bundleIntegrity:
            return
        case .nativeLinuxKernel, .nativeLinuxPerformance, .release,
            .physicalGPU, .physicalDRM:
            guard runnerPlatform.operatingSystem == .linux,
                executionPlatform.environment == .native,
                executionPlatform.operatingSystem == .linux,
                runnerPlatform.architecture == executionPlatform.architecture,
                !binaryTranslation
            else {
                throw ProductArtifactContractFailure(
                    "\(role.rawValue) requires untranslated native Linux execution")
            }
        }
        if role == .physicalGPU || role == .physicalDRM {
            guard physicalHardware else {
                throw ProductArtifactContractFailure(
                    "\(role.rawValue) requires physical hardware")
            }
        }
    }

    public func validate(
        for role: ProductArtifactQualificationRole,
        artifactTarget: ArtifactTarget
    ) throws {
        try validate(for: role)
        guard
            role == .bundleIntegrity
                || (artifactTarget.operatingSystem == executionPlatform.operatingSystem
                    && artifactTarget.architecture == executionPlatform.architecture)
        else {
            throw ProductArtifactContractFailure(
                "\(role.rawValue) execution does not match the artifact target")
        }
    }
}

public struct ProductArtifactQualificationRecordID: RawRepresentable, Codable,
    Hashable, Sendable, CustomStringConvertible
{
    public let rawValue: ArtifactDigest

    public init(rawValue: ArtifactDigest) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.description }
}

public struct ProductArtifactQualificationRecord: Codable, Hashable, Sendable {
    public let identity: ProductArtifactQualificationRecordID
    public let artifact: ProductArtifactID
    public let provenance: ProductArtifactProvenanceID
    public let role: ProductArtifactQualificationRole
    public let capability: ProductArtifactQualificationCapability
    public let evidenceDigest: ArtifactDigest
    public let qualifierTrustDomain: String

    public init(
        envelope: ProductArtifactEnvelope,
        role: ProductArtifactQualificationRole,
        capability: ProductArtifactQualificationCapability,
        evidenceDigest: ArtifactDigest,
        qualifierTrustDomain: String
    ) throws {
        try envelope.validate()
        try capability.validate(
            for: role,
            artifactTarget: envelope.manifest.artifactTarget)
        try requireDigest(envelope.identity.rawValue, name: "product artifact")
        try requireDigest(evidenceDigest, name: "qualification evidence")
        guard !qualifierTrustDomain.isEmpty else {
            throw ProductArtifactContractFailure("qualifier trust domain is empty")
        }
        artifact = envelope.identity
        provenance = envelope.provenanceIdentity
        self.role = role
        self.capability = capability
        self.evidenceDigest = evidenceDigest
        self.qualifierTrustDomain = qualifierTrustDomain
        identity = Self.identity(
            artifact: envelope.identity,
            provenance: envelope.provenanceIdentity,
            role: role,
            capability: capability,
            evidenceDigest: evidenceDigest,
            qualifierTrustDomain: qualifierTrustDomain)
    }

    public func validate() throws {
        try capability.validate(for: role)
        try requireDigest(artifact.rawValue, name: "product artifact")
        try requireDigest(provenance.rawValue, name: "product artifact provenance")
        try requireDigest(evidenceDigest, name: "qualification evidence")
        guard !qualifierTrustDomain.isEmpty else {
            throw ProductArtifactContractFailure("qualifier trust domain is empty")
        }
        guard
            identity
                == Self.identity(
                    artifact: artifact,
                    provenance: provenance,
                    role: role,
                    capability: capability,
                    evidenceDigest: evidenceDigest,
                    qualifierTrustDomain: qualifierTrustDomain)
        else {
            throw ProductArtifactContractFailure(
                "qualification record identity does not match its evidence")
        }
    }

    private static func identity(
        artifact: ProductArtifactID,
        provenance: ProductArtifactProvenanceID,
        role: ProductArtifactQualificationRole,
        capability: ProductArtifactQualificationCapability,
        evidenceDigest: ArtifactDigest,
        qualifierTrustDomain: String
    ) -> ProductArtifactQualificationRecordID {
        var encoder = IdentityEncoder()
        encoder.append("product-artifact-qualification")
        encoder.append(digest: artifact.rawValue)
        encoder.append(digest: provenance.rawValue)
        encoder.appendEnum(role)
        encoder.append(platform: capability.runnerPlatform)
        encoder.append(platform: capability.executionPlatform)
        encoder.append(capability.physicalHardware)
        encoder.append(capability.binaryTranslation)
        encoder.append(digest: evidenceDigest)
        encoder.append(qualifierTrustDomain)
        return ProductArtifactQualificationRecordID(
            rawValue: .sha256(encoder.bytes))
    }
}

public struct ProductArtifactContractFailure: Error, CustomStringConvertible,
    Sendable
{
    public let description: String

    public init(_ description: String) {
        self.description = "product artifact contract failed: \(description)"
    }
}

private func isFullGitCommit(_ value: String) -> Bool {
    value.count == 40
        && value.utf8.allSatisfy { byte in
            switch byte {
            case 48...57, 97...102: true
            default: false
            }
        }
}

private func requireDigest(_ digest: ArtifactDigest, name: String) throws {
    guard digest.algorithm == .sha256, digest.bytes.count == 32 else {
        throw ProductArtifactContractFailure(
            "\(name) identity is not a SHA-256 digest")
    }
}

private func requireCanonicalOrder(_ values: [String], name: String) throws {
    guard values == Array(Set(values)).sorted() else {
        throw ProductArtifactContractFailure(
            "\(name) values are not unique and canonically ordered")
    }
}

private func requirePortableRelativePath(
    _ value: String,
    allowsRoot: Bool
) throws {
    let path = FilePath(value)
    guard !value.isEmpty, !path.isAbsolute, path.isLexicallyNormal,
        !path.components.contains(where: { $0.string == ".." }),
        allowsRoot || value != "."
    else {
        throw ProductArtifactContractFailure(
            "path is not a canonical portable relative path: \(value)")
    }
    _ = try IdentityPathMap.empty.canonicalizePortable(value)
}

extension IdentityEncoder {
    public mutating func append(digest: ArtifactDigest) {
        appendEnum(digest.algorithm)
        append(bytes: digest.bytes)
    }

    fileprivate mutating func append(platform: RunnerPlatform) {
        appendEnum(platform.operatingSystem)
        appendEnum(platform.architecture)
    }

    fileprivate mutating func append(platform: ExecutionPlatform) {
        appendEnum(platform.environment)
        appendEnum(platform.operatingSystem)
        appendEnum(platform.architecture)
    }

    fileprivate mutating func append(target: ArtifactTarget) {
        appendEnum(target.operatingSystem)
        appendEnum(target.architecture)
        appendOptional(target.abi) { $0.append($1) }
        appendOptional(target.androidAPILevel) { $0.append(UInt64($1)) }
    }
}
