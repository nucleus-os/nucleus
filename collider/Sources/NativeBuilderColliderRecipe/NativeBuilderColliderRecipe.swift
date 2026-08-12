import ColliderCore
import Foundation
import SystemPackage

package enum NativeBuilderTaskIDs {
    package static let dependencies = TaskID(rawValue: "native.builder-dependencies")
    package static let prepare = TaskID(rawValue: "native.builder")
}

package struct NativeBuilderArtifacts: Sendable {
    package let component: ComponentDefinition
    package let configuration: NativeOCIBaseConfiguration
}

private enum NativeEntrypointImageActionKind: OCIEntrypointImageActionKind {
    static let actionKind: ActionKind = "native.prepare-entrypoint-image"
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
        let dependencyContext = cacheRoot.appending("dependency-context")
        let generatedContext = cacheRoot.appending("context")
        let resolverOutput = cacheRoot.appending("apt-resolution")
        let resolverImageID = cacheRoot.appending("resolver-image-id")
        let dependencyImageID = cacheRoot.appending("dependency-image-id")
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
        let dependencyPreparation = OCIImagePreparation(
            executionPlatform: .linuxARM64OCI,
            context: dependencyContext,
            containerFile: dependencyContext.appending("Containerfile"),
            imageID: dependencyImageID,
            imageName: "localhost/nucleus-linux-build-dependencies",
            environment: environment)
        let finalPreparation = OCIImagePreparation(
            executionPlatform: .linuxARM64OCI,
            context: generatedContext,
            containerFile: generatedContext.appending("Containerfile"),
            imageID: imageID,
            imageName: "localhost/nucleus-linux-build",
            baseImageSource: .local,
            localBaseImageID: dependencyImageID,
            environment: environment)

        var dependencyBuilder = TaskBuilder(
            id: NativeBuilderTaskIDs.dependencies,
            component: descriptor.id)
        let dependencyImage: ArtifactReference =
            try dependencyBuilder.output(
                "image-id",
                path: dependencyImageID,
                validation: .regularFile)
        let dependencyTask = dependencyBuilder.build(
            inputs: nativeBuilderDependencyInputs(sourceContext: sourceContext),
            postconditions: [
                PathPostcondition(path: ccache, validation: .exists)
            ],
            locks: [.checkout("native-builder-image")],
            assessmentPolicy: .incremental,
            action:
                try AnyColliderAction(
                    PrepareNativeBuilderDependencyImageAction(
                        sourceContext: sourceContext,
                        inputRoot: inputRoot,
                        generatedContext: dependencyContext,
                        resolverOutput: resolverOutput,
                        ccache: ccache,
                        ubuntuSnapshot: manifest.ubuntuSnapshot,
                        ubuntuSuites: manifest.aptRepositories.map(\.suite),
                        initialDownloads: downloads,
                        resolverPreparation: resolverPreparation,
                        dependencyPreparation: dependencyPreparation)))
        var builder = TaskBuilder(
            id: NativeBuilderTaskIDs.prepare,
            component: descriptor.id)
        builder.consume(dependencyImage)
        let image: ArtifactReference = try builder.output(
            "image-id",
            path: imageID,
            validation: .regularFile)
        let task = builder.build(
            inputs: [.file(sourceContext.appending("entrypoint.sh"))],
            locks: [.checkout("native-builder-image")],
            assessmentPolicy: .incremental,
            action:
                try AnyColliderAction(
                    PrepareOCIEntrypointImageAction<NativeEntrypointImageActionKind>(
                        baseImageID: dependencyImageID,
                        entrypoint: sourceContext.appending("entrypoint.sh"),
                        entrypointDestination: "/usr/local/bin/nucleus-build",
                        generatedContext: generatedContext,
                        preparation: finalPreparation)))
        let configuration = NativeOCIBaseConfiguration(
            context: generatedContext,
            dependencyImage: dependencyImage,
            image: image,
            ccache: ccache,
            environment: environment)
        return NativeBuilderArtifacts(
            component: try ComponentDefinition(
                descriptor: descriptor,
                tasks: [dependencyTask, task],
                entrypoints: [
                    ComponentEntrypoint(id: .bootstrap, roots: [task.id])
                ],
                storage: [
                    StorageDeclaration(
                        id: "native-builder-metadata",
                        owner: descriptor.id,
                        producers: [.task(dependencyTask.id), .task(task.id)],
                        storageClass: .cache,
                        root: cacheRoot,
                        safetyRoot: cacheRoot.removingLastComponent(),
                        retentionPolicy: .singleWorkingSet),
                    StorageDeclaration(
                        id: "native-builder-ccache",
                        owner: descriptor.id,
                        producers: [.task(dependencyTask.id)],
                        storageClass: .cache,
                        root: ccache,
                        safetyRoot: ccache.removingLastComponent(),
                        retentionPolicy: .toolManagedLimit(
                            maximumBytes: 50 * 1_024 * 1_024 * 1_024)),
                ]),
            configuration: configuration)
    }
}

private func nativeBuilderDependencyInputs(
    sourceContext: FilePath
) -> [ArtifactInput] {
    [
        "Dependencies.Containerfile",
        "Resolver.Containerfile",
        "apt-extract-packages.txt",
        "apt-install-packages.txt",
        "native-builder-inputs.json",
        "resolve-apt-packages.sh",
    ].map { .file(sourceContext.appending($0)) }
}

private struct PrepareNativeBuilderDependencyImageAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let sourceContext: FilePath
        let inputRoot: FilePath
        let generatedContext: FilePath
        let resolverOutput: FilePath
        let cache: FilePath
        let ubuntuSnapshot: String
        let ubuntuSuites: [String]
        let resolverPreparation: OCIImagePreparation
        let dependencyPreparation: OCIImagePreparation

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: sourceContext)
            encoder.append(path: inputRoot)
            encoder.append(path: generatedContext)
            encoder.append(path: resolverOutput)
            encoder.append(path: cache)
            encoder.append(ubuntuSnapshot)
            encoder.append(ubuntuSuites.joined(separator: "\n"))
            encoder.append(nested: OCIImagePreparationActionIdentity(resolverPreparation))
            encoder.append(nested: OCIImagePreparationActionIdentity(dependencyPreparation))
        }
    }

    static let kind: ActionKind = "native.prepare-builder-dependency-image"

    let sourceContext: FilePath
    let inputRoot: FilePath
    let generatedContext: FilePath
    let resolverOutput: FilePath
    let ccache: FilePath
    let ubuntuSnapshot: String
    let ubuntuSuites: [String]
    let initialDownloads: [NativeBuilderDownload]
    let resolverPreparation: OCIImagePreparation
    let dependencyPreparation: OCIImagePreparation

    var identity: Identity {
        Identity(
            sourceContext: sourceContext,
            inputRoot: inputRoot,
            generatedContext: generatedContext,
            resolverOutput: resolverOutput,
            cache: ccache,
            ubuntuSnapshot: ubuntuSnapshot,
            ubuntuSuites: ubuntuSuites,
            resolverPreparation: resolverPreparation,
            dependencyPreparation: dependencyPreparation)
    }

    var requirements: ActionRequirements {
        ActionRequirements(
            effects: [
                ActionEffect(
                    .read,
                    scope: .input(
                        sourceContext.appending("Dependencies.Containerfile"))),
                ActionEffect(
                    .read,
                    scope: .input(
                        sourceContext.appending("Resolver.Containerfile"))),
                ActionEffect(
                    .read,
                    scope: .input(
                        sourceContext.appending("apt-extract-packages.txt"))),
                ActionEffect(
                    .read,
                    scope: .input(
                        sourceContext.appending("apt-install-packages.txt"))),
                ActionEffect(
                    .read,
                    scope: .input(
                        sourceContext.appending("native-builder-inputs.json"))),
                ActionEffect(
                    .read,
                    scope: .input(
                        sourceContext.appending("resolve-apt-packages.sh"))),
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
                    scope: .output(dependencyPreparation.imageID)),
            ],
            lane: .hostExclusive,
            networkAccess: .contentAddressed,
            executionPlatform: .linuxARM64OCI)
    }

    var environment: [String: String] { dependencyPreparation.environment }
    var imagePreparations: [OCIImagePreparation] {
        [resolverPreparation, dependencyPreparation]
    }

    func execute(in context: ActionContext) async throws {
        try context.files.createDirectory(ccache)
        try context.files.createDirectory(inputRoot)
        try await download(initialDownloads, in: context)
        let indexDownloads = try nativeBuilderAPTIndexDownloads(
            releases: initialDownloads,
            root: inputRoot,
            files: context.files)
        try await download(indexDownloads, in: context)

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
            downloads: initialDownloads + indexDownloads + packageDownloads,
            files: context.files)
        try await context.containers.prepareImage(dependencyPreparation)
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
                    boundedExport: resolverOutput,
                    target: "/output"),
            ],
            userPolicy: OCIUserPolicy(userID: 0, groupID: 0),
            capabilityPolicy: .dropAll,
            privilegePolicy: .prohibitAcquisition,
            processFilesystemPolicy: .standard,
            resourceLimits: OCIResourceLimits(
                cpuCount: 2,
                memoryBytes: 4 * 1_024 * 1_024 * 1_024,
                processCount: 1_024),
            containerEnvironment: [
                "LANG": "C.UTF-8",
                "LC_ALL": "C.UTF-8",
                "NUCLEUS_UBUNTU_SNAPSHOT": ubuntuSnapshot,
                "NUCLEUS_UBUNTU_SUITES": ubuntuSuites.joined(separator: " "),
            ],
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
            from: sourceContext.appending("Dependencies.Containerfile"),
            to: candidate.appending("Containerfile"))
        for download in downloads {
            let destination: FilePath
            switch download.placement {
            case .archive(let name):
                destination = candidate.appending("inputs/archives/\(name)")
            case .aptRelease:
                continue
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
        generatedContext.removingLastComponent().appending(
            "\(generatedContext.lastComponent?.string ?? "dependency-context").candidate")
    }
}
