import ColliderCore
import SystemPackage

public enum VulkanColliderRecipe: ColliderComponent {
    public static let descriptor = ComponentDescriptor(
        id: ComponentID(rawValue: "vulkan"),
        canonicalName: "vulkan",
        directoryName: "swift-vulkan")

    public static func makeComponent(
        in context: RecipeContext
    ) throws -> ComponentDefinition {
        let generation = try generate(
            root: context.componentRoot(descriptor),
            generatedRoot: context.cacheRoot.appending("generated/vulkan"),
            environment: context.environment,
            swiftPM: try context.swiftPM(.hostDebug))
        return try ComponentDefinition(
            descriptor: descriptor,
            tasks: generation.tasks,
            entrypoints: [
                ComponentEntrypoint(id: .generate, roots: [generation.task.id]),
                ComponentEntrypoint(
                    id: .verifyGeneratedSources,
                    roots: [generation.verification.id]),
            ],
            storage: [
                // The generated bindings live in storage. The committed file
                // beside the sources is authored state a human adopts, so no
                // task declares itself its producer.
                StorageDeclaration(
                    id: "vulkan-generated-sources",
                    owner: descriptor.id,
                    producers: [.task(generation.task.id)],
                    storageClass: .published,
                    root: context.cacheRoot.appending("generated/vulkan"),
                    safetyRoot: context.cacheRoot,
                    retentionPolicy: .singleWorkingSet)
            ],
            generatedSources: generation.mappings)
    }

    package struct Generation: Sendable {
        package let tasks: [TaskDeclaration]
        package let task: TaskDeclaration
        package let verification: TaskDeclaration
        package let mappings: [GeneratedSourceMapping]
    }

    package static func generate(
        root: FilePath,
        generatedRoot: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) throws -> Generation {
        var toolBuilder = TaskBuilder(
            id: TaskID(rawValue: "vulkan.generator"),
            component: descriptor.id)
        let generator: ExecutableReference = try toolBuilder.executableOutput(
            "executable",
            path: swiftPM.executable("VulkanGen"))
        let tool = toolBuilder.build(
            swiftProducts: [
                swiftPM.product(
                    package: "swift-vulkan",
                    product: "VulkanGen",
                    packageRoot: root,
                    environment: environment,
                    expectedOutputs: [
                        PathPostcondition(
                            path: generator.path,
                            validation: .executableFile)
                    ])
            ],
            inputs: [
                .sourceCheckout(root.appending("Tools/VulkanGen")),
                swiftPM.identityInput,
            ],
            locks: [.checkout("vulkan")])

        // Generation writes declared storage. The committed file beside the
        // sources is adopted by the developer who commits it, because a build
        // that rewrites the checkout it is reading makes every checkout dirty
        // and lets build code modify source that is later committed.
        let committed = root.appending("Sources/Vulkan/Vulkan.swift")
        let output = generatedRoot.appending("Vulkan.swift")
        var builder = TaskBuilder(
            id: TaskID(rawValue: "vulkan.generate"),
            component: descriptor.id)
        builder.consume(generator)
        let generated: ArtifactReference = try builder.output(
            "bindings",
            path: output,
            validation: .regularFile)
        let task = builder.build(
            inputs: [
                .file(root.appending("third-party/vk.xml"))
            ],
            locks: [.checkout("vulkan")],
            action:
                try AnyColliderAction(
                    GenerateVulkanBindingsAction(
                        generator: generator,
                        registry: root.appending("third-party/vk.xml"),
                        output: output,
                        workingDirectory: root,
                        formatConfiguration: root.removingLastComponent()
                            .appending(".swift-format"),
                        environment: environment)))
        let mappings = [
            GeneratedSourceMapping(generated: output, committed: committed)
        ]
        var verifier = TaskBuilder(
            id: TaskID(rawValue: "vulkan.verify-generated-sources"),
            component: descriptor.id)
        verifier.consume(generated)
        let verification = verifier.build(
            inputs: [.file(committed)],
            locks: [.checkout("vulkan")],
            action:
                try AnyColliderAction(
                    VerifyVulkanGeneratedSourceAction(mappings: mappings)))
        return Generation(
            tasks: [tool, task, verification],
            task: task,
            verification: verification,
            mappings: mappings)
    }
}

private struct GenerateVulkanBindingsAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let generator: FilePath
        let registry: FilePath
        let output: FilePath

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: generator)
            encoder.append(path: registry)
            encoder.append(path: output)
            encoder.append(1)
        }
    }

    static let kind: ActionKind = "vulkan.generate-bindings"

    let generator: ExecutableReference
    let registry: FilePath
    let output: FilePath
    let workingDirectory: FilePath
    let formatConfiguration: FilePath
    let environment: [String: String]

    var identity: Identity {
        Identity(generator: generator.path, registry: registry, output: output)
    }

    var requirements: ActionRequirements {
        ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "vulkan-generator",
                    executable: generator.executable,
                    role: .semantic),
                ActionToolRequirement(
                    "swift-format",
                    executable: .named("swift-format"),
                    role: .semantic),
            ],
            effects: [
                ActionEffect(.read, scope: .input(registry)),
                ActionEffect(.read, scope: .checkout(formatConfiguration)),
                ActionEffect(.write, scope: .output(output)),
            ],
            executionPlatform: .macOSARM64Native)
    }

    func execute(in context: ActionContext) async throws {
        let result = try await context.commands.execute(
            CommandSpec(
                executable: generator.executable,
                arguments: [registry.string, output.string, "1"],
                workingDirectory: workingDirectory,
                environment: environment))
        guard result.succeeded else {
            throw result.executionFailure(reason: "Vulkan binding generation failed")
        }
        // The repository's formatting contract covers every Swift source,
        // including this one, and the committed copy is formatted. Generation
        // therefore produces formatted output, so what a human adopts is
        // byte-identical to what verification regenerates. The configuration is
        // named explicitly because the output no longer sits under the
        // repository root for swift-format to discover.
        let formatted = try await context.commands.execute(
            CommandSpec(
                executable: .named("swift-format"),
                arguments: [
                    "format", "--in-place",
                    "--configuration", formatConfiguration.string,
                    output.string,
                ],
                workingDirectory: workingDirectory,
                environment: environment))
        guard formatted.succeeded else {
            throw formatted.executionFailure(
                reason: "generated Vulkan bindings could not be formatted")
        }
    }
}
