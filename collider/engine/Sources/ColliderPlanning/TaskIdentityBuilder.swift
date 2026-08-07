import ColliderCore
import SystemPackage

struct TaskIdentityBuilder {
    func build(
        of task: TaskDeclaration,
        dependencies: [(task: TaskID, identity: ArtifactDigest)],
        services: TaskPlanningServices
    ) throws -> ArtifactDigest {
        var resolutions = TaskIdentityResolutions()
        return try identity(
            of: task,
            dependencies: dependencies,
            services: services,
            resolutions: &resolutions)
    }

    private func identity(
        of task: TaskDeclaration,
        dependencies: [(task: TaskID, identity: ArtifactDigest)],
        services: TaskPlanningServices,
        resolutions: inout TaskIdentityResolutions
    ) throws -> ArtifactDigest {
        var encoder = CanonicalDigestEncoder(
            identityPathMap: services.identityPathMap)
        encoder.append(tag: 1, string: task.id.rawValue)
        encoder.append(tag: 2, string: task.component.rawValue)
        for dependency in dependencies.sorted(by: {
            $0.task.rawValue < $1.task.rawValue
        }) {
            var dependencyEncoder = ActionIdentityEncoder(
                identityPathMap: services.identityPathMap)
            dependencyEncoder.append(tag: 1, string: dependency.task.rawValue)
            dependencyEncoder.append(tag: 2, bytes: dependency.identity.bytes)
            encoder.append(
                tag: 3,
                bytes: try dependencyEncoder.encodedBytes())
        }
        var artifactReferenceBytes: [UInt8] = []
        for reference in task.artifactReferences.sorted(by: {
            ($0.producer.rawValue, $0.slot.rawValue, $0.path.string)
                < ($1.producer.rawValue, $1.slot.rawValue, $1.path.string)
        }) {
            var referenceEncoder = ActionIdentityEncoder(
                identityPathMap: services.identityPathMap)
            referenceEncoder.append(tag: 1, string: reference.producer.rawValue)
            referenceEncoder.append(tag: 2, string: reference.slot.rawValue)
            referenceEncoder.append(tag: 3, string: reference.path.string)
            referenceEncoder.append(tag: 4, string: reference.kind.rawValue)
            let bytes = try referenceEncoder.encodedBytes()
            artifactReferenceBytes += lengthPrefix(bytes.count) + bytes
        }
        encoder.append(tag: 245, bytes: artifactReferenceBytes)

        var resultReferenceBytes: [UInt8] = []
        for reference in task.resultReferences.sorted(by: {
            ($0.producer.rawValue, $0.slot.rawValue)
                < ($1.producer.rawValue, $1.slot.rawValue)
        }) {
            var referenceEncoder = ActionIdentityEncoder(
                identityPathMap: services.identityPathMap)
            referenceEncoder.append(tag: 1, string: reference.producer.rawValue)
            referenceEncoder.append(tag: 2, string: reference.slot.rawValue)
            referenceEncoder.append(tag: 3, string: reference.valueType)
            let bytes = try referenceEncoder.encodedBytes()
            resultReferenceBytes += lengthPrefix(bytes.count) + bytes
        }
        encoder.append(tag: 246, bytes: resultReferenceBytes)

        var outputSlotBytes: [UInt8] = []
        for slot in task.outputSlots.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            var slotEncoder = ActionIdentityEncoder(
                identityPathMap: services.identityPathMap)
            slotEncoder.append(tag: 1, string: slot.id.rawValue)
            slotEncoder.append(tag: 2, string: slot.path.string)
            slotEncoder.append(tag: 3, string: slot.validation.rawValue)
            slotEncoder.append(tag: 4, string: slot.kind.rawValue)
            let bytes = try slotEncoder.encodedBytes()
            outputSlotBytes += lengthPrefix(bytes.count) + bytes
        }
        encoder.append(tag: 247, bytes: outputSlotBytes)

        var resultSlotBytes: [UInt8] = []
        for slot in task.resultSlots.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            var slotEncoder = ActionIdentityEncoder(
                identityPathMap: services.identityPathMap)
            slotEncoder.append(tag: 1, string: slot.id.rawValue)
            slotEncoder.append(tag: 2, string: slot.valueType)
            let bytes = try slotEncoder.encodedBytes()
            resultSlotBytes += lengthPrefix(bytes.count) + bytes
        }
        encoder.append(tag: 248, bytes: resultSlotBytes)

        for requirement in task.swiftProducts.sorted(by: {
            $0.qualifiedProduct < $1.qualifiedProduct
        }) {
            encoder.append(tag: 221, string: requirement.qualifiedProduct)
            encoder.append(
                tag: 222,
                bytes: requirement.invocation.context.identityBytes(
                    identityPathMap: services.identityPathMap))
            for target in requirement.prebuildTargets {
                encoder.append(tag: 109, string: target)
            }
            for output in requirement.expectedOutputs {
                encoder.append(tag: 223, string: output.path.string)
                encoder.append(tag: 224, string: output.validation.rawValue)
            }
        }
        for requirement in task.swiftTests.sorted(by: {
            $0.qualifiedProduct < $1.qualifiedProduct
        }) {
            encoder.append(tag: 225, string: requirement.qualifiedProduct)
            encoder.append(
                tag: 226,
                bytes: requirement.invocation.context.identityBytes(
                    identityPathMap: services.identityPathMap))
            for argument in requirement.arguments {
                encoder.append(tag: 227, string: argument)
            }
            for output in requirement.expectedBuildOutputs {
                encoder.append(tag: 107, string: output.path.string)
                encoder.append(tag: 108, string: output.validation.rawValue)
            }
        }

        for input in identityInputs(of: task) {
            switch input {
            case .value(let name, let bytes):
                encoder.append(tag: 10, string: name)
                encoder.append(tag: 11, bytes: bytes)
            case .string(let name, let value):
                encoder.append(tag: 77, string: name)
                encoder.append(tag: 78, string: value)
            case .environment(let name, let value):
                encoder.append(tag: 12, string: name)
                encoder.append(tag: 13, string: value ?? "<unset>")
            case .swiftBuildContext(let context):
                encoder.append(tag: 75, string: "swift-build-context")
                encoder.append(
                    tag: 76,
                    bytes: context.identityBytes(
                        identityPathMap: services.identityPathMap))
            case .file(let path):
                encoder.append(tag: 14, string: path.string)
                encoder.append(
                    tag: 15,
                    bytes: try resolutions.fileDigest(path, services: services).bytes)
            case .tree(let path):
                encoder.append(tag: 16, string: path.string)
                encoder.append(
                    tag: 17,
                    bytes: try resolutions.treeDigest(path, services: services).bytes)
            case .sourceCheckout(let path):
                encoder.append(tag: 20, string: path.string)
                encoder.append(
                    tag: 21,
                    bytes: try resolutions.sourceCheckoutDigest(
                        path,
                        services: services
                    ).bytes)
            case .optionalSourceCheckout(let path, let fallback):
                encoder.append(tag: 79, string: path.string)
                if let digest = try resolutions.optionalSourceCheckoutDigest(
                    path,
                    services: services)
                {
                    encoder.append(tag: 80, bytes: digest.bytes)
                } else {
                    encoder.append(tag: 81, bytes: fallback)
                }
            case .tool(let executable):
                let environment =
                    task.swiftProducts.first?.environment
                    ?? task.action?.environment ?? [:]
                let tool = try resolutions.semanticToolIdentity(
                    executable,
                    environment: environment,
                    services: services)
                encoder.append(tag: 18, string: tool.path.string)
                encoder.append(tag: 19, bytes: tool.digest.bytes)
            }
        }
        for output in task.outputs {
            encoder.append(tag: 40, string: output.path.string)
            encoder.append(tag: 41, string: output.validation.rawValue)
        }
        for postcondition in task.postconditions {
            encoder.append(tag: 218, string: postcondition.path.string)
            encoder.append(tag: 219, string: postcondition.validation.rawValue)
        }
        try encode(
            action: task.action,
            into: &encoder,
            services: services,
            resolutions: &resolutions)
        return services.digestBytes(encoder.bytes)
    }

    private func identityInputs(of task: TaskDeclaration) -> [ArtifactInput] {
        var inputs = task.inputs
        for requirement in task.swiftProducts.sorted(by: {
            $0.qualifiedProduct < $1.qualifiedProduct
        }) {
            for input in requirement.inputs where !inputs.contains(input) {
                inputs.append(input)
            }
        }
        for requirement in task.swiftTests.sorted(by: {
            $0.qualifiedProduct < $1.qualifiedProduct
        }) {
            for input in requirement.inputs where !inputs.contains(input) {
                inputs.append(input)
            }
        }
        return inputs
    }

    private func encode(
        action: AnyColliderAction?,
        into encoder: inout CanonicalDigestEncoder,
        services: TaskPlanningServices,
        resolutions: inout TaskIdentityResolutions
    ) throws {
        guard let action else {
            encoder.append(tag: 235, string: "no-action")
            return
        }
        encoder.append(tag: 235, string: action.kind.rawValue)
        encoder.append(
            tag: 236,
            bytes: try action.identity(using: services.identityPathMap))
        let execution = action.requirements.executionPlatform
        encoder.append(tag: 249, string: execution.environment.rawValue)
        encoder.append(tag: 250, string: execution.operatingSystem.rawValue)
        encoder.append(tag: 251, string: execution.architecture.rawValue)
        if let artifact = action.requirements.artifactTarget {
            encoder.append(tag: 252, string: artifact.operatingSystem.rawValue)
            encoder.append(tag: 253, string: artifact.architecture.rawValue)
            encoder.append(tag: 254, string: artifact.abi ?? "")
            encoder.append(
                tag: 255,
                integer: UInt64(artifact.androidAPILevel ?? 0))
        } else {
            encoder.append(tag: 252, string: "no-artifact-target")
        }
        for tool in action.requirements.tools.filter({
            $0.role == .semantic
        }).sorted(by: { $0.name < $1.name }) {
            switch tool.executable {
            case .artifact(let reference):
                encoder.append(tag: 239, string: tool.name)
                encoder.append(tag: 240, string: reference.producer.rawValue)
                encoder.append(tag: 241, string: reference.slot.rawValue)
                encoder.append(tag: 238, string: reference.kind.rawValue)
            case .named, .operationalNamed, .path, .taskOutput:
                let identity = try resolutions.semanticToolIdentity(
                    tool.executable,
                    environment: action.environment,
                    services: services)
                encoder.append(tag: 239, string: tool.name)
                encoder.append(tag: 240, string: identity.path.string)
                encoder.append(tag: 241, bytes: identity.digest.bytes)
            }
        }
        let effects = action.requirements.effects.sorted {
            let left = $0.scope.root.string + "\u{0}" + $0.access.rawValue
            let right = $1.scope.root.string + "\u{0}" + $1.access.rawValue
            return left.utf8.lexicographicallyPrecedes(right.utf8)
        }
        for effect in effects {
            encoder.append(tag: 242, string: effect.access.rawValue)
            let scope: String
            switch effect.scope {
            case .input: scope = "input"
            case .checkout: scope = "checkout"
            case .scratch: scope = "scratch"
            case .output: scope = "output"
            case .publication: scope = "publication"
            case .unrestricted: scope = "unrestricted"
            }
            encoder.append(tag: 243, string: scope)
            encoder.append(tag: 244, string: effect.scope.root.string)
        }
        for (name, value) in artifactEnvironment(action.environment) {
            encoder.append(tag: 237, string: name)
            encoder.append(tag: 238, string: value)
        }
    }
}

private struct TaskIdentityResolutions {
    private enum OptionalDigestResolution {
        case missing
        case digest(ArtifactDigest)
    }

    private struct EnvironmentEntry: Hashable {
        let name: String
        let value: String
    }

    private struct SemanticToolKey: Hashable {
        let executable: CommandSpec.Executable
        let environment: [EnvironmentEntry]
    }

    private var fileDigests: [FilePath: ArtifactDigest] = [:]
    private var treeDigests: [FilePath: ArtifactDigest] = [:]
    private var sourceCheckoutDigests: [FilePath: ArtifactDigest] = [:]
    private var optionalSourceCheckoutDigests: [FilePath: OptionalDigestResolution] = [:]
    private var semanticTools: [SemanticToolKey: ToolIdentitySnapshot] = [:]

    mutating func fileDigest(
        _ path: FilePath,
        services: TaskPlanningServices
    ) throws -> ArtifactDigest {
        if let digest = fileDigests[path] { return digest }
        let digest = try services.digestFile(path)
        fileDigests[path] = digest
        return digest
    }

    mutating func treeDigest(
        _ path: FilePath,
        services: TaskPlanningServices
    ) throws -> ArtifactDigest {
        if let digest = treeDigests[path] { return digest }
        let digest = try services.digestTree(path)
        treeDigests[path] = digest
        return digest
    }

    mutating func sourceCheckoutDigest(
        _ path: FilePath,
        services: TaskPlanningServices
    ) throws -> ArtifactDigest {
        if let digest = sourceCheckoutDigests[path] { return digest }
        let digest = try services.digestSourceCheckout(path)
        sourceCheckoutDigests[path] = digest
        return digest
    }

    mutating func optionalSourceCheckoutDigest(
        _ path: FilePath,
        services: TaskPlanningServices
    ) throws -> ArtifactDigest? {
        if let resolution = optionalSourceCheckoutDigests[path] {
            switch resolution {
            case .missing: return nil
            case .digest(let digest): return digest
            }
        }
        let digest = try services.optionalSourceCheckoutDigest(path)
        optionalSourceCheckoutDigests[path] =
            digest.map(OptionalDigestResolution.digest) ?? .missing
        return digest
    }

    mutating func semanticToolIdentity(
        _ executable: CommandSpec.Executable,
        environment: [String: String],
        services: TaskPlanningServices
    ) throws -> ToolIdentitySnapshot {
        let key = SemanticToolKey(
            executable: executable,
            environment: environment.map(EnvironmentEntry.init).sorted {
                $0.name < $1.name
            })
        if let identity = semanticTools[key] { return identity }
        let identity = try services.semanticToolIdentity(executable, environment)
        semanticTools[key] = identity
        return identity
    }
}

private func artifactEnvironment(
    _ environment: [String: String]
) -> [(key: String, value: String)] {
    let volatile = Set(["TERM", "PATH"])
    return
        environment
        .filter { !volatile.contains($0.key) }
        .sorted { $0.key < $1.key }
}

private func lengthPrefix(_ count: Int) -> [UInt8] {
    let value = UInt64(count)
    return (0..<8).reversed().map { shift in
        UInt8(truncatingIfNeeded: value >> UInt64(shift * 8))
    }
}
