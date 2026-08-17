import ColliderCore
import Foundation
import SystemPackage

package enum ApexManifestProtobufMode: String, Hashable, Sendable {
    case publish
    case verify
}

package struct ApexManifestProtobufAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        package let mode: ApexManifestProtobufMode
        package let packageRoot: FilePath
        package let scratchPath: FilePath
        package let generatedSource: FilePath
        package let result: FilePath

        package func encode(into encoder: inout IdentityEncoder) {
            encoder.append(mode.rawValue)
            encoder.append(path: packageRoot)
            encoder.append(path: scratchPath)
            encoder.append(path: generatedSource)
            encoder.append(path: result)
            encoder.append(2)
        }
    }

    package static let kind: ActionKind = "android-runtime.generate-apex-manifest"

    package let mode: ApexManifestProtobufMode
    package let packageRoot: FilePath
    package let scratchPath: FilePath
    package let swiftExecutable: CommandSpec.Executable
    package let generatedSource: FilePath
    package let result: FilePath
    package let environment: [String: String]

    package var identity: Identity {
        Identity(
            mode: mode,
            packageRoot: packageRoot,
            scratchPath: scratchPath,
            generatedSource: generatedSource,
            result: result)
    }

    package var requirements: ActionRequirements {
        var effects = [
            ActionEffect(.read, scope: .checkout(packageRoot)),
            ActionEffect(.readWrite, scope: .scratch(scratchPath)),
            ActionEffect(.write, scope: .output(result)),
        ]
        if mode == .publish {
            effects.append(
                ActionEffect(.write, scope: .publication(generatedSource)))
        }
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
        var arguments = [
            "package",
            "--package-path", packageRoot.string,
            "--scratch-path", scratchPath.string,
            "--only-use-versions-from-resolved-file",
            "plugin",
            "--allow-writing-to-package-directory",
        ]
        arguments += [
            "generate-apex-manifest",
            mode == .publish ? "--publish" : "--verify",
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
        let generatedSource = root.appending(
            "Sources/NucleusAndroidContainerContract/apex_manifest.pb.swift")
        let pluginSource = packageRoot.appending(
            "tools/generate-apex-manifest/plugin.swift")
        let verificationRoot = buildRoot.appending(
            "android-runtime/apex-manifest-protobuf")
        let generation = verificationRoot.appending("generation.json")
        let verification = verificationRoot.appending("verification.json")
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
                    mode: .publish,
                    packageRoot: packageRoot,
                    scratchPath: swiftPM.scratchPath,
                    swiftExecutable: swiftPM.swiftExecutable,
                    generatedSource: generatedSource,
                    result: generationMarker.path,
                    environment: environment)))

        var verificationBuilder = TaskBuilder(
            id: AndroidRuntimeTaskIDs.apexManifestVerify,
            component: descriptor.id)
        let marker: ArtifactReference = try verificationBuilder.output(
            "verification",
            path: verification,
            validation: .json)
        let verificationTask = verificationBuilder.build(
            inputs: sharedInputs + [.file(generatedSource)],
            locks: locks,
            assessmentPolicy: .incremental,
            action: try AnyColliderAction(
                ApexManifestProtobufAction(
                    mode: .verify,
                    packageRoot: packageRoot,
                    scratchPath: swiftPM.scratchPath,
                    swiftExecutable: swiftPM.swiftExecutable,
                    generatedSource: generatedSource,
                    result: marker.path,
                    environment: environment)))

        return ApexManifestProtobufTasks(
            generation: generationTask,
            verification: verificationTask,
            generatedSource: generatedSource,
            verificationRoot: verificationRoot)
    }
}
