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
        var encoder = IdentityEncoder(
            identityPathMap: services.identityPathMap)
        encoder.append(task.id.rawValue)
        encoder.append(task.component.rawValue)
        encoder.appendSequence(dependencies.sorted { $0.task.rawValue < $1.task.rawValue }) {
            dependencyEncoder, dependency in
            dependencyEncoder.append(dependency.task.rawValue)
            dependencyEncoder.append(bytes: dependency.identity.bytes)
        }
        let artifactReferences = task.artifactReferences.sorted {
            ($0.producer.rawValue, $0.slot.rawValue, $0.path.string)
                < ($1.producer.rawValue, $1.slot.rawValue, $1.path.string)
        }
        encoder.appendSequence(artifactReferences) { referenceEncoder, reference in
            referenceEncoder.append(reference.producer.rawValue)
            referenceEncoder.append(reference.slot.rawValue)
            referenceEncoder.append(path: reference.path)
            referenceEncoder.append(reference.validation.rawValue)
        }
        encoder.appendSequence(task.outputSlots.sorted { $0.id.rawValue < $1.id.rawValue }) {
            slotEncoder, slot in
            slotEncoder.append(slot.id.rawValue)
            slotEncoder.append(path: slot.path)
            slotEncoder.append(slot.validation.rawValue)
        }

        encoder.appendSequence(
            task.swiftProducts.sorted(by: {
                $0.qualifiedProduct < $1.qualifiedProduct
            })
        ) { requirementEncoder, requirement in
            requirementEncoder.append(requirement.qualifiedProduct)
            requirementEncoder.append(
                bytes: requirement.invocation.context.identityBytes(
                    identityPathMap: services.identityPathMap))
            requirementEncoder.appendSequence(requirement.prebuildTargets) { $0.append($1) }
            requirementEncoder.appendSequence(requirement.expectedOutputs) {
                outputEncoder, output in
                outputEncoder.append(path: output.path)
                outputEncoder.append(output.validation.rawValue)
            }
        }
        encoder.appendSequence(
            task.swiftTests.sorted(by: {
                $0.qualifiedProduct < $1.qualifiedProduct
            })
        ) { requirementEncoder, requirement in
            requirementEncoder.append(requirement.qualifiedProduct)
            requirementEncoder.append(
                bytes: requirement.invocation.context.identityBytes(
                    identityPathMap: services.identityPathMap))
            requirementEncoder.appendSequence(requirement.arguments) { $0.append($1) }
            requirementEncoder.appendSequence(requirement.expectedBuildOutputs) {
                outputEncoder, output in
                outputEncoder.append(path: output.path)
                outputEncoder.append(output.validation.rawValue)
            }
        }

        try encoder.appendSequence(identityInputs(of: task)) { inputEncoder, input in
            switch input {
            case .value(let name, let bytes):
                inputEncoder.append(name)
                inputEncoder.append(bytes: bytes)
            case .string(let name, let value):
                inputEncoder.append(name)
                inputEncoder.append(value)
            case .environment(let name, let value):
                inputEncoder.append(name)
                inputEncoder.appendOptional(value) { $0.append($1) }
            case .swiftBuildContext(let context):
                inputEncoder.append("swift-build-context")
                inputEncoder.append(
                    bytes: context.identityBytes(
                        identityPathMap: services.identityPathMap))
            case .file(let path):
                inputEncoder.append(path: path)
                inputEncoder.append(
                    bytes: try resolutions.fileDigest(path, services: services).bytes)
            case .tree(let path):
                inputEncoder.append(path: path)
                inputEncoder.append(
                    bytes: try resolutions.treeDigest(path, services: services).bytes)
            case .sourceCheckout(let path):
                inputEncoder.append(path: path)
                inputEncoder.append(
                    bytes: try resolutions.sourceCheckoutDigest(
                        path,
                        services: services
                    ).bytes)
            case .sourceCheckoutClosure(let paths):
                inputEncoder.appendSequence(paths.sorted { $0.string < $1.string }) {
                    $0.append(path: $1)
                }
                inputEncoder.append(
                    bytes: try resolutions.sourceCheckoutClosureDigest(
                        paths,
                        services: services
                    ).bytes)
            case .tool(let executable):
                let environment =
                    task.swiftProducts.first?.environment
                    ?? task.action?.environment ?? [:]
                let tool = try resolutions.semanticToolIdentity(
                    executable,
                    environment: environment,
                    services: services)
                inputEncoder.append(path: tool.path)
                inputEncoder.append(bytes: tool.digest.bytes)
            }
        }
        encoder.appendSequence(task.outputs) { outputEncoder, output in
            outputEncoder.append(path: output.path)
            outputEncoder.append(output.validation.rawValue)
        }
        encoder.appendSequence(task.postconditions) { postconditionEncoder, postcondition in
            postconditionEncoder.append(path: postcondition.path)
            postconditionEncoder.append(postcondition.validation.rawValue)
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
        into encoder: inout IdentityEncoder,
        services: TaskPlanningServices,
        resolutions: inout TaskIdentityResolutions
    ) throws {
        guard let action else {
            encoder.append("no-action")
            return
        }
        encoder.append(action.kind.rawValue)
        encoder.append(bytes: action.identity(using: services.identityPathMap))
        let execution = action.requirements.executionPlatform
        encoder.append(execution.environment.rawValue)
        encoder.append(execution.operatingSystem.rawValue)
        encoder.append(execution.architecture.rawValue)
        if let artifact = action.requirements.artifactTarget {
            encoder.append(artifact.operatingSystem.rawValue)
            encoder.append(artifact.architecture.rawValue)
            encoder.append(artifact.abi ?? "")
            encoder.append(UInt64(artifact.androidAPILevel ?? 0))
        } else {
            encoder.append("no-artifact-target")
        }
        let semanticTools = action.requirements.tools.filter({
            $0.role == .semantic
        }).sorted(by: { $0.name < $1.name })
        try encoder.appendSequence(semanticTools) { toolEncoder, tool in
            switch tool.executable {
            case .artifact(let reference):
                toolEncoder.append(tool.name)
                toolEncoder.append(reference.producer.rawValue)
                toolEncoder.append(reference.slot.rawValue)
                toolEncoder.append(reference.validation.rawValue)
            case .named, .operationalNamed, .path, .taskOutput:
                let identity = try resolutions.semanticToolIdentity(
                    tool.executable,
                    environment: action.environment,
                    services: services)
                toolEncoder.append(tool.name)
                toolEncoder.append(path: identity.path)
                toolEncoder.append(bytes: identity.digest.bytes)
            }
        }
        let effects = action.requirements.effects.sorted {
            let left = $0.scope.root.string + "\u{0}" + $0.access.rawValue
            let right = $1.scope.root.string + "\u{0}" + $1.access.rawValue
            return left.utf8.lexicographicallyPrecedes(right.utf8)
        }
        encoder.appendSequence(effects) { effectEncoder, effect in
            effectEncoder.append(effect.access.rawValue)
            let scope: String
            switch effect.scope {
            case .input: scope = "input"
            case .checkout: scope = "checkout"
            case .scratch: scope = "scratch"
            case .output: scope = "output"
            case .publication: scope = "publication"
            case .unrestricted: scope = "unrestricted"
            }
            effectEncoder.append(scope)
            effectEncoder.append(path: effect.scope.root)
        }
        encoder.appendSequence(artifactEnvironment(action.environment)) { entry, pair in
            entry.append(pair.key)
            entry.append(pair.value)
        }
    }
}

private struct TaskIdentityResolutions {
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
    private var sourceCheckoutClosureDigests: [[FilePath]: ArtifactDigest] = [:]
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

    mutating func sourceCheckoutClosureDigest(
        _ paths: [FilePath],
        services: TaskPlanningServices
    ) throws -> ArtifactDigest {
        let paths = paths.sorted { $0.string < $1.string }
        if let digest = sourceCheckoutClosureDigests[paths] { return digest }
        let digest = try services.digestSourceCheckoutClosure(paths)
        sourceCheckoutClosureDigests[paths] = digest
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
