import ColliderCore
import Foundation
import SystemPackage

package enum AndroidRuntimeTaskIDs {
    package static let aospSourceLock = TaskID(
        rawValue: "android-runtime.aosp-source-lock")
    package static let aospSource = TaskID(rawValue: "android-runtime.aosp-source")
    package static let aospImage = TaskID(rawValue: "android-runtime.aosp-image")

    package static func gfxstream(_ target: NativeLinuxTarget) -> TaskID {
        TaskID(rawValue: "android-runtime.gfxstream.\(target.identifier)")
    }
}

public enum AndroidRuntimeColliderRecipe: ColliderComponent {
    public static let descriptor = ComponentDescriptor(
        id: ComponentID(rawValue: "android-runtime"),
        canonicalName: "android-runtime",
        directoryName: "android-runtime")

    private static let component = ComponentID(rawValue: "android-runtime")

    private struct SourceLockArtifacts {
        let task: TaskDeclaration
        let verification: ArtifactReference<JSONArtifact>
    }

    private struct RepoLauncherArtifacts {
        let task: TaskDeclaration
        let executable: ArtifactReference<FileArtifact>
    }

    private struct SourceArtifacts {
        let tasks: [TaskDeclaration]
        let launcher: ArtifactReference<FileArtifact>
        let provenance: ArtifactReference<JSONArtifact>
    }

    private struct SourceTaskArtifacts {
        let task: TaskDeclaration
        let provenance: ArtifactReference<JSONArtifact>
    }

    private struct SigningArtifacts {
        let task: TaskDeclaration
        let identity: ArtifactReference<JSONArtifact>
        let directory: ArtifactReference<DirectoryArtifact>
    }

    private struct BuilderImageArtifacts {
        let task: TaskDeclaration
        let imageID: ArtifactReference<FileArtifact>
    }

    private struct CompileArtifacts {
        let task: TaskDeclaration
        let unsignedTargetFiles: ArtifactReference<FileArtifact>
        let hostTools: ArtifactReference<DirectoryArtifact>
    }

    private struct AssembleArtifacts {
        let task: TaskDeclaration
        let targetFiles: ArtifactReference<FileArtifact>
        let imageArchive: ArtifactReference<FileArtifact>
        let images: [ArtifactReference<FileArtifact>]
    }

    public static func makeComponent(
        in context: RecipeContext
    ) throws -> ComponentDefinition {
        let root = context.componentRoot(descriptor)
        var tasks = try aospImageTasks(
            root: root,
            environment: context.environment)
        var gfxstreamRoots: Set<TaskID> = []
        for architecture in PlatformArchitecture.allCases {
            let target = NativeLinuxTarget(architecture: architecture)
            let task = try buildGfxstream(
                root: root,
                repositoryRoot: context.repositoryRoot,
                environment: context.environment,
                target: target,
                builder: context.nativeBuilder)
            tasks.append(task)
            gfxstreamRoots.insert(task.id)
        }
        var entrypoints = [
            ComponentEntrypoint(id: .bootstrap, roots: gfxstreamRoots),
            ComponentEntrypoint(
                id: ComponentEntrypointID(rawValue: "aosp.source-lock"),
                roots: [AndroidRuntimeTaskIDs.aospSourceLock]),
            ComponentEntrypoint(
                id: ComponentEntrypointID(rawValue: "aosp.source"),
                roots: [AndroidRuntimeTaskIDs.aospSource]),
            ComponentEntrypoint(
                id: ComponentEntrypointID(rawValue: "aosp.image"),
                roots: [AndroidRuntimeTaskIDs.aospImage]),
        ]
        #if os(Linux)
        if let configuration = try context.configurationIfPresent(
            AndroidAddonPackageConfiguration.self,
            for: descriptor.id)
        {
            let package = addonPackageTask(
                configuration: configuration,
                repositoryRoot: context.repositoryRoot)
            tasks.append(package)
            entrypoints.append(
                ComponentEntrypoint(
                    id: .packageAndroidAddon,
                    roots: [package.id]))
        }
        #endif
        return try ComponentDefinition(
            descriptor: descriptor,
            tasks: tasks,
            entrypoints: entrypoints)
    }

    public static func aospProductSourceOverlays(
        root: FilePath
    ) -> [AOSPProductSourceOverlay] {
        [
            AOSPProductSourceOverlay(
                source: root.removingLastComponent().appending(
                    "ipc/transport/Sources/NucleusIPCTransportC"),
                relativeDestination: "native/ipc-transport"),
            AOSPProductSourceOverlay(
                source: root.appending(
                    "aosp/packages/apps/NucleusRuntimeBridge"),
                relativeDestination:
                    "packages/apps/NucleusRuntimeBridge"),
        ]
    }

    public static func verifyAOSPSourceLock(
        root: FilePath,
        environment: [String: String]
    ) throws -> TaskDeclaration {
        let launcher = try aospRepoLauncher(
            root: root,
            environment: environment)
        return try aospSourceLockArtifacts(
            root: root,
            environment: environment,
            launcher: launcher.executable
        ).task
    }

    private static func aospSourceLockArtifacts(
        root: FilePath,
        environment: [String: String],
        launcher: ArtifactReference<FileArtifact>
    ) throws -> SourceLockArtifacts {
        let lockPath = root.appending("aosp.lock.json")
        let report = root.appending(
            ".aosp-tools/source-lock-verification.json")
        let lock = try loadAOSPSourceLock(root: root)
        let specification = try lock.specification()
        var builder = TaskBuilder(
            id: AndroidRuntimeTaskIDs.aospSourceLock,
            component: component)
        builder.consume(launcher)
        let verification: ArtifactReference<JSONArtifact> = try builder.output(
            "verification",
            path: report,
            validation: .json)
        let task = builder.build(
            inputs: [
                .file(lockPath),
                .tool(.named("git")),
            ],
            locks: [.checkout("android-runtime-aosp-source-lock")],
            assessmentPolicy: .always,
            operation: .verifyAOSPSourceLock(
                AOSPSourceLockVerification(
                    specification: specification,
                    launcher: launcher.path,
                    report: report,
                    environment: environment))
        )
        return SourceLockArtifacts(task: task, verification: verification)
    }

    public static func aospSourceTasks(
        root: FilePath,
        environment: [String: String]
    ) throws -> [TaskDeclaration] {
        try aospSourceArtifacts(
            root: root,
            environment: environment
        ).tasks
    }

    private static func aospSourceArtifacts(
        root: FilePath,
        environment: [String: String]
    ) throws -> SourceArtifacts {
        let launcher = try aospRepoLauncher(
            root: root,
            environment: environment)
        let verification = try aospSourceLockArtifacts(
            root: root,
            environment: environment,
            launcher: launcher.executable)
        let source = try aospSource(
            root: root,
            environment: environment,
            launcher: launcher.executable,
            verification: verification.verification)
        return SourceArtifacts(
            tasks: [launcher.task, verification.task, source.task],
            launcher: launcher.executable,
            provenance: source.provenance)
    }

    public static func aospImageTasks(
        root: FilePath,
        environment: [String: String]
    ) throws -> [TaskDeclaration] {
        let source = try aospSourceArtifacts(
            root: root,
            environment: environment)
        let builderImage = try aospBuilderImage(
            root: root,
            environment: environment)
        let signing = try aospSigningIdentity(
            root: root,
            environment: environment)
        let product = try aospProductImageTasks(
            root: root,
            environment: environment,
            launcher: source.launcher,
            sourceProvenance: source.provenance,
            signing: signing,
            builderImage: builderImage)
        return source.tasks + [builderImage.task, signing.task] + product
    }

    private static func aospRepoLauncher(
        root: FilePath,
        environment _: [String: String]
    ) throws -> RepoLauncherArtifacts {
        let lock = try loadAOSPSourceLock(root: root)
        try lock.validate()
        guard let digest = ArtifactDigest(sha256Hex: lock.repo.launcherSHA256),
            let url = URL(string: lock.repo.launcherURL)
        else {
            throw AndroidRuntimeRecipeFailure.invalidAOSPSourceLock(
                "Repo launcher download specification is invalid")
        }
        let launcher = try aospRepoLauncherPath(root: root)
        let specification = try DownloadSpec(
            url: url,
            permittedRedirectOrigins: ["https://storage.googleapis.com"],
            expectedDigest: digest,
            maximumResponseSize: 2 * 1_024 * 1_024,
            acceptedMediaTypes: [
                "application/octet-stream",
                "text/plain",
            ])
        var builder = TaskBuilder(
            id: TaskID(rawValue: "android-runtime.aosp-repo-launcher"),
            component: component)
        let executable: ArtifactReference<FileArtifact> = try builder.output(
            "repo-launcher",
            path: launcher,
            validation: .regularFile)
        let task = builder.build(
            inputs: [
                .file(root.appending("aosp.lock.json"))
            ],
            locks: [.checkout("android-runtime-aosp-downloads")],
            operation: .action(
                try AnyColliderAction(
                    DownloadAOSPRepoLauncherAction(
                        specification: specification,
                        destination: launcher))))
        return RepoLauncherArtifacts(task: task, executable: executable)
    }

    private static func aospSource(
        root: FilePath,
        environment: [String: String],
        launcher: ArtifactReference<FileArtifact>,
        verification: ArtifactReference<JSONArtifact>
    ) throws -> SourceTaskArtifacts {
        let lock = try loadAOSPSourceLock(root: root)
        let specification = try lock.specification()
        let lockPath = root.appending("aosp.lock.json")
        let source = root.appending(".aosp-source")
        var builder = TaskBuilder(
            id: AndroidRuntimeTaskIDs.aospSource,
            component: component)
        builder.consume(verification)
        builder.consume(launcher)
        let _: ArtifactReference<FileArtifact> = try builder.output(
            "resolved-manifest",
            path: source.appending(".nucleus/resolved-manifest.xml"),
            validation: .regularFile)
        let provenance: ArtifactReference<JSONArtifact> = try builder.output(
            "provenance",
            path: source.appending(".nucleus/source-provenance.json"),
            validation: .json)
        let task = builder.build(
            inputs: [
                .file(lockPath),
                .tool(.named("git")),
                .tool(.named("python3")),
            ],
            locks: [.checkout("android-runtime-aosp-source")],
            operation: .prepareAOSPSource(
                AOSPSourcePreparation(
                    specification: specification,
                    launcher: launcher.path,
                    source: source,
                    syncJobs: 4,
                    retryFetches: 3,
                    environment: environment))
        )
        return SourceTaskArtifacts(task: task, provenance: provenance)
    }

    private static func aospSigningIdentity(
        root: FilePath,
        environment: [String: String]
    ) throws -> SigningArtifacts {
        let signingIdentity = root.appending(
            ".aosp-signing/local-development")
        var builder = TaskBuilder(
            id: TaskID(rawValue: "android-runtime.aosp-signing-identity"),
            component: component)
        let identity: ArtifactReference<JSONArtifact> = try builder.output(
            "identity",
            path: signingIdentity.appending("signing-identity.json"),
            validation: .json)
        let directory: ArtifactReference<DirectoryArtifact> = try builder.output(
            "directory",
            path: signingIdentity,
            validation: .nonEmptyDirectory)
        let task = builder.build(
            inputs: [
                .value(
                    name: "subject",
                    bytes: Array(aospSigningSubject.utf8)),
                .tool(.named("openssl")),
            ],
            locks: [.checkout("android-runtime-aosp-signing")],
            operation: .prepareAOSPSigningIdentity(
                AOSPSigningIdentityPreparation(
                    destination: signingIdentity,
                    subject: aospSigningSubject,
                    environment: environment)))
        return SigningArtifacts(
            task: task,
            identity: identity,
            directory: directory)
    }

    private static func aospBuilderImage(
        root: FilePath,
        environment: [String: String]
    ) throws -> BuilderImageArtifacts {
        let context = root.appending("build-container")
        let containerFile = context.appending("Containerfile")
        let imageID = root.appending(".aosp-build/container/image-id")
        var builder = TaskBuilder(
            id: TaskID(rawValue: "android-runtime.aosp-builder-image"),
            component: component)
        let artifact: ArtifactReference<FileArtifact> = try builder.output(
            "image-id",
            path: imageID,
            validation: .regularFile)
        let task = builder.build(
            inputs: [
                .tree(context)
            ],
            locks: [.checkout("android-runtime-aosp-builder-image")],
            operation: .action(
                try AnyColliderAction(
                    PrepareAOSPBuilderImageAction(
                        preparation: OCIImagePreparation(
                            executionPlatform: .linuxAMD64OCI,
                            context: context,
                            containerFile: containerFile,
                            imageID: imageID,
                            imageName: "localhost/nucleus-aosp-build",
                            environment: environment)))))
        return BuilderImageArtifacts(task: task, imageID: artifact)
    }

    private static func aospProductImageTasks(
        root: FilePath,
        environment: [String: String],
        launcher: ArtifactReference<FileArtifact>,
        sourceProvenance: ArtifactReference<JSONArtifact>,
        signing: SigningArtifacts,
        builderImage: BuilderImageArtifacts
    ) throws -> [TaskDeclaration] {
        let lockPath = root.appending("aosp-product.lock.json")
        let lock = try JSONDecoder().decode(
            AOSPProductLock.self,
            from: Data(contentsOf: URL(fileURLWithPath: lockPath.string)))
        try lock.validate()
        let source = root.appending(".aosp-source")
        let signingIdentity = root.appending(
            ".aosp-signing/local-development")
        let aospBuildRoot = root.appending(".aosp-build")
        let ccacheDirectory = aospCCacheDirectory(environment: environment)
        let productIdentity = Array(
            [
                lock.product,
                lock.release,
                lock.variant,
                lock.buildNumber,
                String(lock.buildTimestamp),
                String(lock.platformSDK),
                String(lock.vendorAPILevel),
            ].joined(separator: "\0").utf8)
        let generationID = [
            String(lock.buildTimestamp),
            lock.buildNumber,
            lock.release,
            lock.product,
            lock.variant,
            String(lock.platformSDK),
            String(lock.vendorAPILevel),
        ].joined(separator: "-")
        let buildRoot =
            aospBuildRoot
            .appending("generations")
            .appending(generationID)
        let active = aospBuildRoot.appending("current")
        let containerImageID = aospBuildRoot.appending("container/image-id")
        let signed = buildRoot.appending("signed")
        let images = buildRoot.appending("images")
        let unsigned = buildRoot.appending(
            "unsigned/\(lock.product)-target_files.zip")
        let unsignedDigest = buildRoot.appending(
            "unsigned/\(lock.product)-target_files.zip.sha256")
        let staged = buildRoot.appending("staged")
        let stagedTargetFiles = staged.appending(
            "\(lock.product)-target_files.zip")
        let stagedImageArchive = staged.appending(
            "\(lock.product)-images.zip")
        let stagedImages = staged.appending("images")
        let stagedProvenance = staged.appending(
            "image-provenance.json")
        let hostTools = buildRoot.appending("out/host/linux-x86/bin")
        let build = AOSPProductBuild(
            productSource: root.appending(
                "aosp/device/nucleus/nucleus_x86_64"),
            source: source,
            repoLauncher: launcher.path,
            sourceProvenance: sourceProvenance.path,
            buildRoot: buildRoot,
            ccacheDirectory: ccacheDirectory,
            containerImageID: containerImageID,
            signingIdentity: signingIdentity,
            product: lock.product,
            release: lock.release,
            variant: lock.variant,
            buildNumber: lock.buildNumber,
            buildTimestamp: lock.buildTimestamp,
            buildJobs: lock.buildJobs,
            expectedPlatformSDK: lock.platformSDK,
            expectedVendorAPILevel: lock.vendorAPILevel,
            environment: environment,
            sourceOverlays: aospProductSourceOverlays(root: root))
        let requiredImages = [
            "system.img",
            "system_ext.img",
            "product.img",
            "vendor.img",
            "vbmeta.img",
            "vbmeta_system.img",
        ]
        var compileBuilder = TaskBuilder(
            id: TaskID(rawValue: "android-runtime.aosp-compile"),
            component: component)
        compileBuilder.consume(sourceProvenance)
        compileBuilder.consume(launcher)
        compileBuilder.consume(builderImage.imageID)
        let unsignedReference: ArtifactReference<FileArtifact> = try compileBuilder.output(
            "unsigned-target-files",
            path: unsigned,
            validation: .regularFile)
        let _: ArtifactReference<FileArtifact> = try compileBuilder.output(
            "unsigned-target-files-digest",
            path: unsignedDigest,
            validation: .regularFile)
        let hostToolsReference: ArtifactReference<DirectoryArtifact> =
            try compileBuilder.output(
                "host-tools",
                path: hostTools,
                validation: .nonEmptyDirectory)
        let compileTask = compileBuilder.build(
            inputs: [
                .value(
                    name: "aosp-product-identity",
                    bytes: productIdentity),
                .tree(
                    root.appending(
                        "aosp/device/nucleus/nucleus_x86_64")),
                .tree(
                    root.removingLastComponent().appending(
                        "ipc/transport/Sources/NucleusIPCTransportC")),
                .tree(
                    root.appending(
                        "aosp/packages/apps/NucleusRuntimeBridge")),
                .tool(.named("python3")),
            ],
            locks: [
                .checkout("android-runtime-aosp-source"),
                .checkout("android-runtime-aosp-build"),
                .checkout("android-runtime-aosp-ccache"),
            ],
            operation: .aospProduct(.compile, build)
        )
        let compile = CompileArtifacts(
            task: compileTask,
            unsignedTargetFiles: unsignedReference,
            hostTools: hostToolsReference)
        var signBuilder = TaskBuilder(
            id: TaskID(rawValue: "android-runtime.aosp-sign"),
            component: component)
        signBuilder.consume(signing.identity)
        signBuilder.consume(signing.directory)
        signBuilder.consume(compile.unsignedTargetFiles)
        signBuilder.consume(compile.hostTools)
        signBuilder.consume(builderImage.imageID)
        let stagedTargetFilesReference: ArtifactReference<FileArtifact> =
            try signBuilder.output(
                "staged-target-files",
                path: stagedTargetFiles,
                validation: .regularFile)
        let sign = signBuilder.build(
            inputs: [
                .value(
                    name: "aosp-product-identity",
                    bytes: productIdentity),
                .tool(.named("openssl")),
            ],
            locks: [
                .checkout("android-runtime-aosp-source"),
                .checkout("android-runtime-aosp-build"),
            ],
            operation: .aospProduct(.sign, build)
        )
        var assembleBuilder = TaskBuilder(
            id: TaskID(rawValue: "android-runtime.aosp-assemble-images"),
            component: component)
        assembleBuilder.consume(stagedTargetFilesReference)
        assembleBuilder.consume(compile.hostTools)
        assembleBuilder.consume(builderImage.imageID)
        let stagedArchiveReference: ArtifactReference<FileArtifact> =
            try assembleBuilder.output(
                "image-archive",
                path: stagedImageArchive,
                validation: .regularFile)
        let stagedImageReferences: [ArtifactReference<FileArtifact>] =
            try requiredImages.map { image in
                try assembleBuilder.output(
                    OutputSlotID(rawValue: "image-\(image)"),
                    path: stagedImages.appending(image),
                    validation: .regularFile)
            }
        let assembleTask = assembleBuilder.build(
            inputs: [
                .value(
                    name: "aosp-product-identity",
                    bytes: productIdentity),
                .tool(.named("unzip")),
            ],
            locks: [
                .checkout("android-runtime-aosp-source"),
                .checkout("android-runtime-aosp-build"),
            ],
            operation: .aospProduct(.assembleImages, build))
        let assemble = AssembleArtifacts(
            task: assembleTask,
            targetFiles: stagedTargetFilesReference,
            imageArchive: stagedArchiveReference,
            images: stagedImageReferences)
        var validateBuilder = TaskBuilder(
            id: TaskID(rawValue: "android-runtime.aosp-validate"),
            component: component)
        validateBuilder.consume(sourceProvenance)
        validateBuilder.consume(signing.identity)
        validateBuilder.consume(assemble.targetFiles)
        validateBuilder.consume(assemble.imageArchive)
        validateBuilder.consume(builderImage.imageID)
        for image in assemble.images {
            validateBuilder.consume(image)
        }
        let stagedProvenanceReference: ArtifactReference<JSONArtifact> =
            try validateBuilder.output(
                "image-provenance",
                path: stagedProvenance,
                validation: .json)
        let validate = validateBuilder.build(
            inputs: [
                .value(
                    name: "aosp-product-identity",
                    bytes: productIdentity),
                .tree(
                    root.appending(
                        "aosp/device/nucleus/nucleus_x86_64")),
                .tree(
                    root.removingLastComponent().appending(
                        "ipc/transport/Sources/NucleusIPCTransportC")),
                .tool(.named("openssl")),
                .tool(.named("unzip")),
            ],
            locks: [
                .checkout("android-runtime-aosp-source"),
                .checkout("android-runtime-aosp-build"),
            ],
            operation: .aospProduct(.validate, build)
        )
        var publishBuilder = TaskBuilder(
            id: AndroidRuntimeTaskIDs.aospImage,
            component: component)
        publishBuilder.consume(stagedProvenanceReference)
        publishBuilder.consume(assemble.targetFiles)
        publishBuilder.consume(assemble.imageArchive)
        for image in assemble.images {
            publishBuilder.consume(image)
        }
        let _: ArtifactReference<JSONArtifact> = try publishBuilder.output(
            "image-provenance",
            path: signed.appending("image-provenance.json"),
            validation: .json)
        let _: ArtifactReference<FileArtifact> = try publishBuilder.output(
            "target-files",
            path: signed.appending("\(lock.product)-target_files.zip"),
            validation: .regularFile)
        let _: ArtifactReference<FileArtifact> = try publishBuilder.output(
            "image-archive",
            path: signed.appending("\(lock.product)-images.zip"),
            validation: .regularFile)
        let _: ArtifactReference<PathArtifact> = try publishBuilder.output(
            "active-generation",
            path: active,
            validation: .symlinkTarget)
        for image in requiredImages {
            let _: ArtifactReference<FileArtifact> = try publishBuilder.output(
                OutputSlotID(rawValue: "image-\(image)"),
                path: images.appending(image),
                validation: .regularFile)
        }
        let publish = publishBuilder.build(
            inputs: [],
            locks: [.checkout("android-runtime-aosp-build")],
            operation: .aospProduct(.publish, build)
        )
        return [compile.task, sign, assemble.task, validate, publish]
    }

    private static func aospCCacheDirectory(
        environment: [String: String]
    ) -> FilePath {
        if let xdg = environment["XDG_CACHE_HOME"], !xdg.isEmpty {
            return FilePath(xdg).appending("nucleus").appending("aosp-ccache")
        }
        let home = environment["HOME"] ?? "/tmp"
        return FilePath(home).appending(".cache").appending("nucleus")
            .appending("aosp-ccache")
    }

    private static func loadAOSPSourceLock(
        root: FilePath
    ) throws -> AOSPSourceLock {
        try JSONDecoder().decode(
            AOSPSourceLock.self,
            from: Data(
                contentsOf: URL(
                    fileURLWithPath: root.appending("aosp.lock.json").string)))
    }

    private static func aospRepoLauncherPath(
        root: FilePath
    ) throws -> FilePath {
        let lock = try loadAOSPSourceLock(root: root)
        try lock.validate()
        return root.appending(
            ".aosp-tools/repo-\(lock.repo.launcherVersion)")
    }

    public static func buildGfxstream(
        root: FilePath,
        repositoryRoot: FilePath,
        environment: [String: String],
        target: NativeLinuxTarget,
        builder: NativeOCIConfiguration
    ) throws -> TaskDeclaration {
        let buildRoot = root.appending(".gfxstream-build/\(target.identifier)")
        let hostSource = repositoryRoot.appending("third-party/gfxstream")
        let guestSource = repositoryRoot.appending("third-party/mesa")
        let crossFile = root.appending("build-support/linux-x86_64.ini")
        let crossOption =
            target.architecture == .x86_64
            ? " --cross-file=/build-support/linux-x86_64.ini" : ""
        let hostBuild = "/tmp/nucleus-gfxstream-host"
        let guestBuild = "/tmp/nucleus-gfxstream-guest"
        var task = TaskBuilder(
            id: AndroidRuntimeTaskIDs.gfxstream(target),
            component: component)
        task.consume(builder.image)
        let _: ArtifactReference<FileArtifact> = try task.output(
            "host-backend",
            path: buildRoot.appending("host/host/libgfxstream_backend.a"),
            validation: .regularFile)
        let _: ArtifactReference<FileArtifact> = try task.output(
            "guest-vulkan-driver",
            path: buildRoot.appending(
                "guest/src/gfxstream/guest/vulkan/libvulkan_gfxstream.so"),
            validation: .regularFile)
        return task.build(
            inputs: [
                .tree(hostSource),
                .tree(guestSource),
                .tree(builder.swiftSDKRoot),
            ] + (target.architecture == .x86_64 ? [.file(crossFile)] : []),
            locks: [
                .checkout("android-runtime-gfxstream-\(target.identifier)")
            ],
            assessmentPolicy: .incremental,
            operation: .sequence([
                .action(
                    try AnyColliderAction(
                        PrepareGfxstreamBuildAction(buildRoot: buildRoot))),
                try gfxstreamOperation(
                    root: root,
                    hostSource: hostSource,
                    guestSource: guestSource,
                    buildRoot: buildRoot,
                    target: target,
                    builder: builder,
                    environment: environment,
                    command: [
                        "bash", "-lc",
                        "meson setup \(hostBuild) /gfxstream"
                            + " -Dbuildtype=release -Ddefault_library=static"
                            + " -Ddecoders=gles,vulkan,composer -Dgfxstream-build=host"
                            + crossOption
                            + " && meson compile -C \(hostBuild) gfxstream_backend"
                            + " && mkdir -p /build/host/host"
                            + " && cp \(hostBuild)/host/libgfxstream_backend.a"
                            + " /build/host/host/libgfxstream_backend.a",
                    ]),
                try gfxstreamOperation(
                    root: root,
                    hostSource: hostSource,
                    guestSource: guestSource,
                    buildRoot: buildRoot,
                    target: target,
                    builder: builder,
                    environment: environment,
                    command: [
                        "bash", "-lc",
                        "meson setup \(guestBuild) /mesa"
                            + " -Dbuildtype=release -Dvulkan-drivers=gfxstream"
                            + " -Dgallium-drivers=[] -Dplatforms=[] -Dglx=disabled"
                            + " -Degl=disabled -Dgbm=disabled -Dgles1=disabled"
                            + " -Dgles2=disabled -Dopengl=false -Dllvm=disabled"
                            + " -Dshared-glapi=disabled -Dvalgrind=disabled"
                            + " -Dlibunwind=disabled -Dbuild-tests=false"
                            + " -Dvideo-codecs=[]"
                            + crossOption
                            + " && meson compile -C \(guestBuild) vulkan_gfxstream"
                            + " gfxstream_vk_icd gfxstream_vk_devenv_icd"
                            + " && mkdir -p /build/guest"
                            + " && cp -a \(guestBuild)/. /build/guest/",
                    ]),
            ]))
    }

}

private struct PrepareAOSPBuilderImageAction: ColliderAction {
    static let kind: ActionKind = "android-runtime.prepare-aosp-builder-image"

    let identity: OCIImagePreparationActionIdentity

    init(preparation: OCIImagePreparation) {
        identity = OCIImagePreparationActionIdentity(preparation)
    }

    var requirements: ActionRequirements {
        ociImagePreparationActionRequirements(preparation: identity.preparation)
    }

    var environment: [String: String] { identity.preparation.environment }

    func execute(in context: ActionContext) async throws {
        try await context.containers.prepareImage(identity.preparation)
    }
}

private struct DownloadAOSPRepoLauncherAction: ColliderAction {
    static let kind: ActionKind = "android-runtime.download-aosp-repo-launcher"

    let identity: DownloadActionIdentity

    init(specification: DownloadSpec, destination: FilePath) {
        identity = DownloadActionIdentity(
            specification: specification,
            destination: destination)
    }

    var requirements: ActionRequirements {
        ActionRequirements(effects: [
            ActionEffect(.readWrite, scope: .output(identity.destination))
        ])
    }

    func execute(in context: ActionContext) async throws {
        try await context.downloads.download(
            identity.specification,
            to: identity.destination)
    }

    func validateOutputs(using files: ActionFileSystem) throws {
        try identity.validateOutput(using: files)
    }
}

private struct PrepareGfxstreamBuildAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let buildRoot: FilePath

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: buildRoot.string)
        }
    }

    static let kind: ActionKind = "android-runtime.prepare-gfxstream-build"

    let buildRoot: FilePath

    var identity: Identity { Identity(buildRoot: buildRoot) }

    var requirements: ActionRequirements {
        ActionRequirements(effects: [
            ActionEffect(.readWrite, scope: .output(buildRoot))
        ])
    }

    func execute(in context: ActionContext) async throws {
        try context.files.remove(buildRoot)
        try context.files.createDirectory(buildRoot)
    }
}

private func gfxstreamOperation(
    root: FilePath,
    hostSource: FilePath,
    guestSource: FilePath,
    buildRoot: FilePath,
    target: NativeLinuxTarget,
    builder: NativeOCIConfiguration,
    environment: [String: String],
    command: [String]
) throws -> TaskOperation {
    let execution = OCIExecution(
        executionPlatform: .linuxARM64OCI,
        artifactTarget: target.artifactTarget,
        imageID: builder.imageID,
        hostname: "native-gfxstream-\(target.architecture.rawValue)",
        workingDirectory: "/build",
        hostWorkingDirectory: root,
        mounts: [
            OCIMount(source: hostSource, target: "/gfxstream", access: .readOnly),
            OCIMount(source: guestSource, target: "/mesa", access: .readOnly),
            OCIMount(source: buildRoot, target: "/build", access: .readWrite),
            OCIMount(
                source: root.appending("build-support"),
                target: "/build-support",
                access: .readOnly),
            OCIMount(
                source: builder.ccache,
                target: "/ccache",
                access: .readWrite),
            OCIMount(
                source: builder.swiftSDKRoot,
                target: "/swift-sdk",
                access: .readOnly),
        ],
        networkPolicy: .externalDisabled,
        userPolicy: .builder,
        capabilityPolicy: .dropAll,
        privilegePolicy: .prohibitAcquisition,
        processFilesystemPolicy: .standard,
        intelBinaryTranslationPolicy: target.intelBinaryTranslationPolicy,
        resourceLimits: .parallelBuild,
        containerEnvironment: [
            "CC": "clang",
            "CCACHE_DIR": "/ccache",
            "CXX": "clang++",
            "CXXFLAGS": "-stdlib=libc++",
            "LDFLAGS": "-stdlib=libc++ -fuse-ld=lld",
            "LD_LIBRARY_PATH": target.containerRuntimeLibraryPath,
            "PKG_CONFIG_LIBDIR":
                "/usr/lib/\(target.gnuArchitecture)/pkgconfig:/usr/share/pkgconfig",
        ],
        command: ["gfxstream"] + command,
        environment: environment,
        output: .logged)
    return .action(
        try AnyColliderAction(
            RunGfxstreamBuildAction(execution: execution)))
}

private struct RunGfxstreamBuildAction: ColliderAction {
    static let kind: ActionKind = "android-runtime.build-gfxstream"

    let execution: OCIExecution

    var identity: OCIExecutionActionIdentity {
        OCIExecutionActionIdentity(execution)
    }

    var requirements: ActionRequirements {
        ociActionRequirements(execution: execution)
    }

    var environment: [String: String] { execution.environment }

    func execute(in context: ActionContext) async throws {
        try await context.containers.run(execution)
    }
}

private struct AOSPSourceLock: Decodable {
    struct Upstream: Decodable {
        let release: String
        let revision: String
        let manifestCommit: String
        let superprojectCommit: String
    }

    struct Source: Decodable {
        let manifestURL: String
        let manifestRevision: String
        let manifestCommit: String
        let defaultManifestSHA256: String
        let superprojectURL: String
        let superprojectRevision: String
        let superprojectCommit: String
    }

    struct Repo: Decodable {
        let launcherURL: String
        let launcherVersion: String
        let launcherSHA256: String
        let repositoryURL: String
        let revision: String
        let tagObject: String
        let commit: String
    }

    let upstream: Upstream
    let source: Source
    let repo: Repo

    func validate() throws {
        guard upstream.revision == "refs/tags/android-17.0.0_r1" else {
            throw AndroidRuntimeRecipeFailure.invalidAOSPSourceLock(
                "platform revision must be refs/tags/android-17.0.0_r1")
        }
        guard upstream.release == "Android 17.0.0 Release 1" else {
            throw AndroidRuntimeRecipeFailure.invalidAOSPSourceLock(
                "platform release must be Android 17.0.0 Release 1")
        }
        guard
            source.manifestRevision
                == "refs/heads/nucleus-android-17.0.0_r1",
            source.superprojectRevision
                == "refs/heads/nucleus-android-17.0.0_r1"
        else {
            throw AndroidRuntimeRecipeFailure.invalidAOSPSourceLock(
                "Nucleus source revisions must select the Android 17 branch")
        }
        guard
            source.manifestURL
                == "ssh://git@github.com/nucleus-os/platform_manifest.git",
            source.superprojectURL
                == "ssh://git@github.com/nucleus-os/platform_superproject.git",
            repo.launcherURL
                == "https://storage.googleapis.com/git-repo-downloads/repo",
            repo.repositoryURL
                == "https://gerrit.googlesource.com/git-repo"
        else {
            throw AndroidRuntimeRecipeFailure.invalidAOSPSourceLock(
                "source URLs do not match the approved upstreams")
        }
        for (name, value, count) in [
            ("upstream manifest commit", upstream.manifestCommit, 40),
            ("upstream superproject commit", upstream.superprojectCommit, 40),
            ("manifest commit", source.manifestCommit, 40),
            ("manifest digest", source.defaultManifestSHA256, 64),
            ("superproject commit", source.superprojectCommit, 40),
            ("Repo launcher digest", repo.launcherSHA256, 64),
            ("Repo tag object", repo.tagObject, 40),
            ("Repo commit", repo.commit, 40),
        ] {
            guard value.utf8.count == count,
                value.utf8.allSatisfy({ byte in
                    (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                        || (UInt8(ascii: "a")...UInt8(ascii: "f"))
                            .contains(byte)
                })
            else {
                throw AndroidRuntimeRecipeFailure.invalidAOSPSourceLock(
                    "\(name) must be \(count) lowercase hexadecimal digits")
            }
        }
        guard repo.revision == "refs/tags/v\(repo.launcherVersion)" else {
            throw AndroidRuntimeRecipeFailure.invalidAOSPSourceLock(
                "Repo revision and launcher version disagree")
        }
    }

    func specification() throws -> AOSPSourceSpecification {
        try validate()
        guard
            let defaultManifestDigest = ArtifactDigest(
                sha256Hex: source.defaultManifestSHA256),
            let launcherDigest = ArtifactDigest(
                sha256Hex: repo.launcherSHA256)
        else {
            throw AndroidRuntimeRecipeFailure.invalidAOSPSourceLock(
                "source digests are invalid")
        }
        return AOSPSourceSpecification(
            platform: AOSPPlatformSource(
                release: upstream.release,
                revision: upstream.revision,
                manifestURL: source.manifestURL,
                manifestRevision: source.manifestRevision,
                manifestCommit: source.manifestCommit,
                defaultManifestDigest: defaultManifestDigest,
                superprojectURL: source.superprojectURL,
                superprojectRevision: source.superprojectRevision,
                superprojectCommit: source.superprojectCommit),
            repo: AOSPRepoSource(
                launcherVersion: repo.launcherVersion,
                launcherDigest: launcherDigest,
                repositoryURL: repo.repositoryURL,
                revision: repo.revision,
                tagObject: repo.tagObject,
                commit: repo.commit))
    }
}

private struct AOSPProductLock: Decodable {
    let product: String
    let release: String
    let variant: String
    let buildNumber: String
    let buildTimestamp: UInt64
    let platformSDK: UInt32
    let vendorAPILevel: UInt32
    let buildJobs: UInt32

    func validate() throws {
        guard product == "nucleus_x86_64",
            release == "cp2a",
            variant == "user",
            buildNumber == "nucleus-android17-r1",
            buildTimestamp == 1_781_652_681,
            platformSDK == 37,
            vendorAPILevel == 202604,
            buildJobs > 0
        else {
            throw AndroidRuntimeRecipeFailure.invalidAOSPProductLock(
                "product identity does not match the Android 17 "
                    + "Nucleus build contract")
        }
    }
}

private let aospSigningSubject =
    "/C=US/O=Nucleus/OU=Android Development"

public enum AndroidRuntimeRecipeFailure: Error, CustomStringConvertible {
    case invalidAOSPProductLock(String)
    case invalidAOSPSourceLock(String)

    public var description: String {
        switch self {
        case .invalidAOSPProductLock(let detail):
            "invalid AOSP product lock: \(detail)"
        case .invalidAOSPSourceLock(let detail):
            "invalid AOSP source lock: \(detail)"
        }
    }
}
