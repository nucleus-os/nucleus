import ColliderCore
import Foundation
import SystemPackage

package struct ApexManifestProtobufAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        package let packageRoot: FilePath
        package let scratchPath: FilePath
        package let generatedSource: FilePath
        package let result: FilePath

        package func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: packageRoot)
            encoder.append(path: scratchPath)
            encoder.append(path: generatedSource)
            encoder.append(path: result)
            encoder.append(2)
        }
    }

    package static let kind: ActionKind = "android-runtime.generate-apex-manifest"

    package let packageRoot: FilePath
    package let scratchPath: FilePath
    package let swiftExecutable: CommandSpec.Executable
    package let generatedSource: FilePath
    package let result: FilePath
    package let environment: [String: String]

    package var identity: Identity {
        Identity(
            packageRoot: packageRoot,
            scratchPath: scratchPath,
            generatedSource: generatedSource,
            result: result)
    }

    package var requirements: ActionRequirements {
        // Generation writes its own output and the marker, and reads the
        // checkout. It no longer writes generated source back into the
        // checkout, so there is no publication effect.
        let effects = [
            ActionEffect(.read, scope: .checkout(packageRoot)),
            ActionEffect(.readWrite, scope: .scratch(scratchPath)),
            ActionEffect(.readWrite, scope: .output(generatedSource)),
            ActionEffect(.write, scope: .output(result)),
        ]
        return ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "swift",
                    executable: swiftExecutable,
                    role: .semantic)
            ],
            effects: effects,
            executionPlatform: .macOSARM64Native)
    }

    package func execute(in context: ActionContext) async throws {
        let output = generatedSource.removingLastComponent()
        // The plugin sandbox permits writes only where the invocation says.
        // Naming the one output directory replaces the blanket permission to
        // write the package directory, which is what let generation reach the
        // checkout at all.
        let arguments = [
            "package",
            "--package-path", packageRoot.string,
            "--scratch-path", scratchPath.string,
            "--only-use-versions-from-resolved-file",
            "plugin",
            "--allow-writing-to-directory", output.string,
            "generate-apex-manifest",
            "--output", output.string,
        ]
        let execution = try await context.commands.execute(
            CommandSpec(
                executable: swiftExecutable,
                arguments: arguments,
                workingDirectory: packageRoot,
                environment: environment))
        guard execution.succeeded else {
            throw execution.executionFailure(
                reason: "APEX manifest protobuf generation failed")
        }
        let digest = try context.files.digest(file: generatedSource).hexadecimal
        let marker = "{\"generatedSourceSHA256\":\"\(digest)\"}\n"
        try context.files.write(Array(marker.utf8), to: result)
    }
}

package struct ApexManifestProtobufTasks: Sendable {
    package let generation: TaskDeclaration
    package let verification: TaskDeclaration
    package let generatedSource: FilePath
    package let verificationRoot: FilePath
    package let mappings: [GeneratedSourceMapping]
}

/// Compares the committed APEX manifest source against regenerating it.
package struct VerifyAndroidRuntimeGeneratedSourceAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        package let mappings: [GeneratedSourceMapping]

        package func encode(into encoder: inout IdentityEncoder) {
            encoder.appendSequence(mappings) {
                $0.append(path: $1.generated)
                $0.append(path: $1.committed)
            }
        }
    }

    // An action kind is namespaced to the component that owns the task.
    package static let kind: ActionKind = "android-runtime.verify-generated-sources"

    package let mappings: [GeneratedSourceMapping]

    package var identity: Identity { Identity(mappings: mappings) }

    package var requirements: ActionRequirements {
        ActionRequirements(
            effects: mappings.flatMap {
                [
                    ActionEffect(.read, scope: .input($0.generated)),
                    ActionEffect(.read, scope: .checkout($0.committed)),
                ]
            },
            executionPlatform: .macOSARM64Native)
    }

    package func execute(in context: ActionContext) async throws {
        try GeneratedSourceVerification.check(
            mappings,
            component: "android-runtime",
            in: context)
    }
}

extension AndroidRuntimeColliderRecipe {
    package static func apexManifestProtobufTasks(
        root: FilePath,
        packageRoot: FilePath,
        buildRoot: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) throws -> ApexManifestProtobufTasks {
        let schema = root.appending("Protos/apex_manifest.proto")
        // Generation writes storage; the copy beside the sources is authored
        // state a human adopts.
        let committedSource = root.appending(
            "Sources/NucleusAndroidContainerContract/apex_manifest.pb.swift")
        let generatedSource = buildRoot.appending(
            "android-runtime/generated/apex_manifest.pb.swift")
        let pluginSource = packageRoot.appending(
            "tools/generate-apex-manifest/plugin.swift")
        let verificationRoot = buildRoot.appending(
            "android-runtime/apex-manifest-protobuf")
        let generation = verificationRoot.appending("generation.json")
        let sharedInputs =
            [
                ArtifactInput.file(packageRoot.appending("Package.swift")),
                ArtifactInput.file(packageRoot.appending("Package.resolved")),
                ArtifactInput.file(schema),
                ArtifactInput.file(pluginSource),
                swiftPM.identityInput,
            ] + swiftPM.dependencyConfigurationFiles.map(ArtifactInput.file)
        let locks = [
            swiftPM.lock,
            TaskLock.checkout("android-runtime-apex-manifest-protobuf"),
        ]

        var generationBuilder = TaskBuilder(
            id: AndroidRuntimeTaskIDs.apexManifestGenerate,
            component: descriptor.id)
        let generationMarker: ArtifactReference = try generationBuilder.output(
            "generation",
            path: generation,
            validation: .json)
        let generationTask = generationBuilder.build(
            inputs: sharedInputs,
            locks: locks,
            assessmentPolicy: .always,
            action: try AnyColliderAction(
                ApexManifestProtobufAction(
                    packageRoot: packageRoot,
                    scratchPath: swiftPM.scratchPath,
                    swiftExecutable: swiftPM.swiftExecutable,
                    generatedSource: generatedSource,
                    result: generationMarker.path,
                    environment: environment)))

        let mappings = [
            GeneratedSourceMapping(
                generated: generatedSource,
                committed: committedSource)
        ]
        var verificationBuilder = TaskBuilder(
            id: AndroidRuntimeTaskIDs.apexManifestVerify,
            component: descriptor.id)
        verificationBuilder.consume(generationMarker)
        let verificationTask = verificationBuilder.build(
            inputs: [.file(committedSource)],
            locks: [TaskLock.checkout("android-runtime-apex-manifest-protobuf")],
            assessmentPolicy: .incremental,
            action: try AnyColliderAction(
                VerifyAndroidRuntimeGeneratedSourceAction(mappings: mappings)))

        return ApexManifestProtobufTasks(
            generation: generationTask,
            verification: verificationTask,
            generatedSource: generatedSource,
            verificationRoot: verificationRoot,
            mappings: mappings)
    }
}
