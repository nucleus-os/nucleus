import ColliderCore
import Foundation
import SystemPackage

package enum NativeBuilderTaskIDs {
    package static let prepare = TaskID(rawValue: "native.builder")
}

package struct NativeBuilderArtifacts: Sendable {
    package let component: ComponentDefinition
    package let configuration: NativeOCIBaseConfiguration
}

public enum NativeBuilderColliderRecipe {
    public static let descriptor = ComponentDescriptor(
        id: ComponentID(rawValue: "native"),
        canonicalName: "native-builder",
        directoryName: "collider/images/native-builder")

    package static func prepare(
        context sourceContext: FilePath,
        cacheRoot: FilePath,
        imageID: FilePath,
        ccache: FilePath,
        environment: [String: String]
    ) throws -> NativeBuilderArtifacts {
        let inputRoot = cacheRoot.appending("inputs")
        let generatedContext = cacheRoot.appending("context")
        let resolverOutput = cacheRoot.appending("apt-resolution")
        let resolverImageID = cacheRoot.appending("resolver-image-id")
        let manifest = try NativeBuilderInputManifest.load(
            from: sourceContext.appending("native-builder-inputs.json"))
        let downloads = try manifest.downloads(root: inputRoot)
        let resolverPreparation = OCIImagePreparation(
            executionPlatform: .linuxARM64OCI,
            context: sourceContext,
            containerFile: sourceContext.appending("Resolver.Containerfile"),
            imageID: resolverImageID,
            imageName: "localhost/nucleus-apt-resolver",
            environment: environment)
        let finalPreparation = OCIImagePreparation(
            executionPlatform: .linuxARM64OCI,
            context: generatedContext,
            containerFile: generatedContext.appending("Containerfile"),
            imageID: imageID,
            imageName: "localhost/nucleus-linux-build",
            environment: environment)

        var builder = TaskBuilder(
            id: NativeBuilderTaskIDs.prepare,
            component: descriptor.id)
        let image: ArtifactReference<FileArtifact> = try builder.output(
            "image-id",
            path: imageID,
            validation: .regularFile)
        let task = builder.build(
            inputs: [.tree(sourceContext)],
            postconditions: [
                PathPostcondition(path: ccache, validation: .exists)
            ],
            locks: [.checkout("native-builder-image")],
            assessmentPolicy: .incremental,
            action:
                try AnyColliderAction(
                    PrepareNativeBuilderImageAction(
                        sourceContext: sourceContext,
                        inputRoot: inputRoot,
                        generatedContext: generatedContext,
                        resolverOutput: resolverOutput,
                        ccache: ccache,
                        initialDownloads: downloads,
                        resolverPreparation: resolverPreparation,
                        finalPreparation: finalPreparation)))
        let configuration = NativeOCIBaseConfiguration(
            context: generatedContext,
            image: image,
            ccache: ccache,
            environment: environment)
        return NativeBuilderArtifacts(
            component: try ComponentDefinition(
                descriptor: descriptor,
                tasks: [task],
                entrypoints: [
                    ComponentEntrypoint(id: .bootstrap, roots: [task.id])
                ]),
            configuration: configuration)
    }
}

private struct PrepareNativeBuilderImageAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let sourceContext: FilePath
        let inputRoot: FilePath
        let generatedContext: FilePath
        let resolverOutput: FilePath
        let cache: FilePath
        let resolverPreparation: OCIImagePreparation
        let finalPreparation: OCIImagePreparation

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: sourceContext.string)
            encoder.append(tag: 2, string: inputRoot.string)
            encoder.append(tag: 3, string: generatedContext.string)
            encoder.append(tag: 4, string: resolverOutput.string)
            encoder.append(tag: 5, string: cache.string)
            encoder.append(
                tag: 6,
                nested: OCIImagePreparationActionIdentity(resolverPreparation))
            encoder.append(
                tag: 7,
                nested: OCIImagePreparationActionIdentity(finalPreparation))
        }
    }

    static let kind: ActionKind = "native.prepare-builder-image"

    let sourceContext: FilePath
    let inputRoot: FilePath
    let generatedContext: FilePath
    let resolverOutput: FilePath
    let ccache: FilePath
    let initialDownloads: [NativeBuilderDownload]
    let resolverPreparation: OCIImagePreparation
    let finalPreparation: OCIImagePreparation

    var identity: Identity {
        Identity(
            sourceContext: sourceContext,
            inputRoot: inputRoot,
            generatedContext: generatedContext,
            resolverOutput: resolverOutput,
            cache: ccache,
            resolverPreparation: resolverPreparation,
            finalPreparation: finalPreparation)
    }

    var requirements: ActionRequirements {
        ActionRequirements(
            effects: [
                ActionEffect(.read, scope: .input(sourceContext)),
                ActionEffect(.readWrite, scope: .scratch(inputRoot)),
                ActionEffect(.readWrite, scope: .scratch(generatedContext)),
                ActionEffect(
                    .readWrite,
                    scope: .scratch(candidateContext)),
                ActionEffect(.readWrite, scope: .scratch(resolverOutput)),
                ActionEffect(
                    .readWrite,
                    scope: .scratch(resolverPreparation.imageID)),
                ActionEffect(.readWrite, scope: .scratch(ccache)),
                ActionEffect(
                    .readWrite,
                    scope: .output(finalPreparation.imageID)),
            ],
            lane: .hostExclusive,
            networkAccess: .contentAddressed,
            executionPlatform: .linuxARM64OCI)
    }

    var environment: [String: String] { finalPreparation.environment }

    func execute(in context: ActionContext) async throws {
        try context.files.createDirectory(ccache)
        try context.files.createDirectory(inputRoot)
        try await download(initialDownloads, in: context)

        try await context.containers.prepareImage(resolverPreparation)
        try context.files.remove(resolverOutput)
        try context.files.createDirectory(resolverOutput)
        try await context.containers.run(resolverExecution())

        let closurePath = resolverOutput.appending("packages.tsv")
        let closure = try String(
            decoding: context.files.read(closurePath),
            as: UTF8.self)
        let packageDownloads = try nativeBuilderPackageDownloads(
            manifest: closure,
            root: inputRoot)
        try await download(packageDownloads, in: context)
        try assembleContext(
            downloads: initialDownloads + packageDownloads,
            files: context.files)
        try await context.containers.prepareImage(finalPreparation)
    }

    private func resolverExecution() -> OCIExecution {
        OCIExecution(
            executionPlatform: .linuxARM64OCI,
            artifactTarget: .linuxARM64,
            imageID: resolverPreparation.imageID,
            hostname: "native-apt-resolver",
            workingDirectory: "/",
            hostWorkingDirectory: sourceContext,
            mounts: [
                OCIMount(
                    source: sourceContext,
                    target: "/input",
                    access: .readOnly),
                OCIMount(
                    source: inputRoot.appending("indexes"),
                    target: "/indexes",
                    access: .readOnly),
                OCIMount(
                    source: resolverOutput,
                    target: "/output",
                    access: .readWrite),
            ],
            userPolicy: OCIUserPolicy(userID: 0, groupID: 0),
            capabilityPolicy: .dropAll,
            privilegePolicy: .prohibitAcquisition,
            processFilesystemPolicy: .standard,
            resourceLimits: OCIResourceLimits(
                cpuCount: 2,
                memoryBytes: 4 * 1_024 * 1_024 * 1_024,
                processCount: 1_024),
            containerEnvironment: ["LANG": "C.UTF-8", "LC_ALL": "C.UTF-8"],
            command: ["/usr/local/bin/resolve-nucleus-apt-packages"],
            environment: environment,
            output: .logged)
    }

    private func download(
        _ downloads: [NativeBuilderDownload],
        in context: ActionContext
    ) async throws {
        var iterator = downloads.makeIterator()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<min(12, downloads.count) {
                guard let download = iterator.next() else { break }
                group.addTask {
                    try await context.downloads.download(
                        download.identity.specification,
                        to: download.identity.destination)
                }
            }
            while try await group.next() != nil {
                guard let download = iterator.next() else { continue }
                group.addTask {
                    try await context.downloads.download(
                        download.identity.specification,
                        to: download.identity.destination)
                }
            }
        }
    }

    private func assembleContext(
        downloads: [NativeBuilderDownload],
        files: ActionFileSystem
    ) throws {
        let candidate = candidateContext
        try files.remove(candidate)
        try files.createDirectory(candidate)
        try files.copy(
            from: sourceContext.appending("Containerfile"),
            to: candidate.appending("Containerfile"))
        try files.copy(
            from: sourceContext.appending("entrypoint.sh"),
            to: candidate.appending("entrypoint.sh"))
        for download in downloads {
            let destination: FilePath
            switch download.placement {
            case .archive(let name):
                destination = candidate.appending("inputs/archives/\(name)")
            case .aptIndex:
                continue
            case .aptPackage(let role, let digest):
                destination = candidate.appending(
                    "inputs/apt/\(role)/\(digest).deb")
            }
            try files.createDirectory(destination.removingLastComponent())
            try files.copy(
                from: download.identity.destination,
                to: destination)
        }
        try files.remove(generatedContext)
        try files.move(from: candidate, to: generatedContext)
    }

    private var candidateContext: FilePath {
        generatedContext.removingLastComponent().appending("context.candidate")
    }
}
