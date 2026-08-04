import ColliderCore
import Foundation
import NativeBuilderColliderRecipe
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
            let task = buildGfxstream(
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
        let lockPath = root.appending("aosp.lock.json")
        let launcher = try aospRepoLauncherPath(root: root)
        let report = root.appending(
            ".aosp-tools/source-lock-verification.json")
        let lock = try loadAOSPSourceLock(root: root)
        let specification = try lock.specification()
        return TaskDeclaration(
            id: AndroidRuntimeTaskIDs.aospSourceLock,
            component: component,
            dependencies: [
                TaskID(rawValue: "android-runtime.aosp-repo-launcher")
            ],
            inputs: [
                .file(lockPath),
                .dependencyOutput(launcher),
                .tool(.named("git")),
            ],
            outputs: [
                OutputDeclaration(path: report, validation: .json)
            ],
            locks: [.checkout("android-runtime-aosp-source-lock")],
            assessmentPolicy: .always,
            operation: .verifyAOSPSourceLock(
                AOSPSourceLockVerification(
                    specification: specification,
                    launcher: launcher,
                    report: report,
                    environment: environment)))
    }

    public static func aospSourceTasks(
        root: FilePath,
        environment: [String: String]
    ) throws -> [TaskDeclaration] {
        let launcher = try aospRepoLauncher(
            root: root,
            environment: environment)
        let verification = try verifyAOSPSourceLock(
            root: root,
            environment: environment)
        let source = try aospSource(
            root: root,
            environment: environment)
        return [launcher, verification, source]
    }

    public static func aospImageTasks(
        root: FilePath,
        environment: [String: String]
    ) throws -> [TaskDeclaration] {
        let source = try aospSourceTasks(
            root: root,
            environment: environment)
        let builderImage = aospBuilderImage(
            root: root,
            environment: environment)
        let signing = aospSigningIdentity(
            root: root,
            environment: environment)
        let product = try aospProductImageTasks(
            root: root,
            environment: environment)
        return source + [builderImage, signing] + product
    }

    private static func aospRepoLauncher(
        root: FilePath,
        environment _: [String: String]
    ) throws -> TaskDeclaration {
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
        return TaskDeclaration(
            id: TaskID(rawValue: "android-runtime.aosp-repo-launcher"),
            component: component,
            inputs: [
                .file(root.appending("aosp.lock.json"))
            ],
            outputs: [
                OutputDeclaration(path: launcher, validation: .regularFile)
            ],
            locks: [.checkout("android-runtime-aosp-downloads")],
            operation: .download(specification, candidate: launcher))
    }

    private static func aospSource(
        root: FilePath,
        environment: [String: String]
    ) throws -> TaskDeclaration {
        let lock = try loadAOSPSourceLock(root: root)
        let specification = try lock.specification()
        let lockPath = root.appending("aosp.lock.json")
        let launcher = try aospRepoLauncherPath(root: root)
        let verification = root.appending(
            ".aosp-tools/source-lock-verification.json")
        let source = root.appending(".aosp-source")
        return TaskDeclaration(
            id: AndroidRuntimeTaskIDs.aospSource,
            component: component,
            dependencies: [
                TaskID(rawValue: "android-runtime.aosp-repo-launcher"),
                TaskID(rawValue: "android-runtime.aosp-source-lock"),
            ],
            inputs: [
                .file(lockPath),
                .dependencyOutput(launcher),
                .dependencyOutput(verification),
                .tool(.named("git")),
                .tool(.named("python3")),
            ],
            outputs: [
                OutputDeclaration(
                    path: source.appending(
                        ".nucleus/resolved-manifest.xml"),
                    validation: .regularFile),
                OutputDeclaration(
                    path: source.appending(".nucleus/source-provenance.json"),
                    validation: .json),
            ],
            locks: [.checkout("android-runtime-aosp-source")],
            operation: .prepareAOSPSource(
                AOSPSourcePreparation(
                    specification: specification,
                    launcher: launcher,
                    source: source,
                    syncJobs: 4,
                    retryFetches: 3,
                    environment: environment)))
    }

    private static func aospSigningIdentity(
        root: FilePath,
        environment: [String: String]
    ) -> TaskDeclaration {
        let signingIdentity = root.appending(
            ".aosp-signing/local-development")
        return TaskDeclaration(
            id: TaskID(rawValue: "android-runtime.aosp-signing-identity"),
            component: component,
            inputs: [
                .value(
                    name: "subject",
                    bytes: Array(aospSigningSubject.utf8)),
                .tool(.named("openssl")),
            ],
            outputs: [
                OutputDeclaration(
                    path: signingIdentity.appending(
                        "signing-identity.json"),
                    validation: .json),
                OutputDeclaration(
                    path: signingIdentity,
                    validation: .nonEmptyDirectory),
            ],
            locks: [.checkout("android-runtime-aosp-signing")],
            operation: .prepareAOSPSigningIdentity(
                AOSPSigningIdentityPreparation(
                    destination: signingIdentity,
                    subject: aospSigningSubject,
                    environment: environment)))
    }

    private static func aospBuilderImage(
        root: FilePath,
        environment: [String: String]
    ) -> TaskDeclaration {
        let context = root.appending("build-container")
        let containerFile = context.appending("Containerfile")
        let imageID = root.appending(".aosp-build/container/image-id")
        return TaskDeclaration(
            id: TaskID(rawValue: "android-runtime.aosp-builder-image"),
            component: component,
            inputs: [
                .tree(context)
            ],
            outputs: [
                OutputDeclaration(path: imageID, validation: .regularFile)
            ],
            locks: [.checkout("android-runtime-aosp-builder-image")],
            operation: .prepareOCIImage(
                OCIImagePreparation(
                    executionPlatform: .linuxAMD64OCI,
                    context: context,
                    containerFile: containerFile,
                    imageID: imageID,
                    imageName: "localhost/nucleus-aosp-build",
                    environment: environment)))
    }

    private static func aospProductImageTasks(
        root: FilePath,
        environment: [String: String]
    ) throws -> [TaskDeclaration] {
        let lockPath = root.appending("aosp-product.lock.json")
        let lock = try JSONDecoder().decode(
            AOSPProductLock.self,
            from: Data(contentsOf: URL(fileURLWithPath: lockPath.string)))
        try lock.validate()
        let source = root.appending(".aosp-source")
        let launcher = try aospRepoLauncherPath(root: root)
        let sourceProvenance = source.appending(
            ".nucleus/source-provenance.json")
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
            repoLauncher: launcher,
            sourceProvenance: sourceProvenance,
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
        let compile = TaskDeclaration(
            id: TaskID(rawValue: "android-runtime.aosp-compile"),
            component: component,
            dependencies: [
                TaskID(rawValue: "android-runtime.aosp-repo-launcher"),
                TaskID(rawValue: "android-runtime.aosp-source"),
                TaskID(rawValue: "android-runtime.aosp-builder-image"),
            ],
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
                .dependencyOutput(launcher),
                .dependencyOutput(sourceProvenance),
                .dependencyOutput(containerImageID),
                .tool(.named("python3")),
            ],
            outputs: [
                OutputDeclaration(
                    path: unsigned,
                    validation: .regularFile),
                OutputDeclaration(
                    path: unsignedDigest,
                    validation: .regularFile),
                OutputDeclaration(
                    path: hostTools,
                    validation: .nonEmptyDirectory),
            ],
            locks: [
                .checkout("android-runtime-aosp-source"),
                .checkout("android-runtime-aosp-build"),
                .checkout("android-runtime-aosp-ccache"),
            ],
            operation: .aospProduct(.compile, build))
        let sign = TaskDeclaration(
            id: TaskID(rawValue: "android-runtime.aosp-sign"),
            component: component,
            dependencies: [
                compile.id,
                TaskID(rawValue: "android-runtime.aosp-signing-identity"),
            ],
            inputs: [
                .value(
                    name: "aosp-product-identity",
                    bytes: productIdentity),
                .dependencyOutput(unsigned),
                .dependencyOutput(hostTools),
                .dependencyOutput(
                    signingIdentity.appending(
                        "signing-identity.json")),
                .dependencyOutput(containerImageID),
                .tool(.named("openssl")),
            ],
            outputs: [
                OutputDeclaration(
                    path: stagedTargetFiles,
                    validation: .regularFile)
            ],
            locks: [
                .checkout("android-runtime-aosp-source"),
                .checkout("android-runtime-aosp-build"),
            ],
            operation: .aospProduct(.sign, build))
        let assemble = TaskDeclaration(
            id: TaskID(rawValue: "android-runtime.aosp-assemble-images"),
            component: component,
            dependencies: [sign.id, compile.id],
            inputs: [
                .value(
                    name: "aosp-product-identity",
                    bytes: productIdentity),
                .dependencyOutput(stagedTargetFiles),
                .dependencyOutput(hostTools),
                .dependencyOutput(containerImageID),
                .tool(.named("unzip")),
            ],
            outputs: [
                OutputDeclaration(
                    path: stagedImageArchive,
                    validation: .regularFile)
            ]
                + requiredImages.map {
                    OutputDeclaration(
                        path: stagedImages.appending($0),
                        validation: .regularFile)
                },
            locks: [
                .checkout("android-runtime-aosp-source"),
                .checkout("android-runtime-aosp-build"),
            ],
            operation: .aospProduct(.assembleImages, build))
        let validate = TaskDeclaration(
            id: TaskID(rawValue: "android-runtime.aosp-validate"),
            component: component,
            dependencies: [
                assemble.id,
                TaskID(rawValue: "android-runtime.aosp-source"),
                TaskID(rawValue: "android-runtime.aosp-signing-identity"),
            ],
            inputs: [
                .value(
                    name: "aosp-product-identity",
                    bytes: productIdentity),
                .dependencyOutput(stagedTargetFiles),
                .dependencyOutput(stagedImageArchive),
                .dependencyOutput(sourceProvenance),
                .dependencyOutput(
                    signingIdentity.appending(
                        "signing-identity.json")),
                .dependencyOutput(containerImageID),
                .tree(
                    root.appending(
                        "aosp/device/nucleus/nucleus_x86_64")),
                .tree(
                    root.removingLastComponent().appending(
                        "ipc/transport/Sources/NucleusIPCTransportC")),
                .tool(.named("openssl")),
                .tool(.named("unzip")),
            ]
                + requiredImages.map {
                    .dependencyOutput(stagedImages.appending($0))
                },
            outputs: [
                OutputDeclaration(
                    path: stagedProvenance,
                    validation: .json)
            ],
            locks: [
                .checkout("android-runtime-aosp-source"),
                .checkout("android-runtime-aosp-build"),
            ],
            operation: .aospProduct(.validate, build))
        let publish = TaskDeclaration(
            id: AndroidRuntimeTaskIDs.aospImage,
            component: component,
            dependencies: [
                validate.id,
                assemble.id,
                sign.id,
            ],
            inputs: [
                .dependencyOutput(stagedProvenance),
                .dependencyOutput(stagedTargetFiles),
                .dependencyOutput(stagedImageArchive),
            ]
                + requiredImages.map {
                    .dependencyOutput(stagedImages.appending($0))
                },
            outputs: [
                OutputDeclaration(
                    path: signed.appending("image-provenance.json"),
                    validation: .json),
                OutputDeclaration(
                    path: signed.appending(
                        "\(lock.product)-target_files.zip"),
                    validation: .regularFile),
                OutputDeclaration(
                    path: signed.appending(
                        "\(lock.product)-images.zip"),
                    validation: .regularFile),
                OutputDeclaration(
                    path: active,
                    validation: .symlinkTarget),
            ]
                + requiredImages.map {
                    OutputDeclaration(
                        path: images.appending($0),
                        validation: .regularFile)
                },
            locks: [.checkout("android-runtime-aosp-build")],
            operation: .aospProduct(.publish, build))
        return [compile, sign, assemble, validate, publish]
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
    ) -> TaskDeclaration {
        let buildRoot = root.appending(".gfxstream-build/\(target.identifier)")
        let hostSource = repositoryRoot.appending("third-party/gfxstream")
        let guestSource = repositoryRoot.appending("third-party/mesa")
        let crossFile = root.appending("build-support/linux-x86_64.ini")
        let crossOption =
            target.architecture == .x86_64
            ? " --cross-file=/build-support/linux-x86_64.ini" : ""
        let hostBuild = "/tmp/nucleus-gfxstream-host"
        let guestBuild = "/tmp/nucleus-gfxstream-guest"
        return TaskDeclaration(
            id: AndroidRuntimeTaskIDs.gfxstream(target),
            component: component,
            dependencies: [NativeBuilderTaskIDs.prepare],
            inputs: [
                .tree(hostSource),
                .tree(guestSource),
                .dependencyOutput(builder.imageID),
                .tree(builder.swiftSDKRoot),
            ] + (target.architecture == .x86_64 ? [.file(crossFile)] : []),
            outputs: [
                OutputDeclaration(
                    path: buildRoot.appending("host/host/libgfxstream_backend.a"),
                    validation: .regularFile),
                OutputDeclaration(
                    path: buildRoot.appending(
                        "guest/src/gfxstream/guest/vulkan/libvulkan_gfxstream.so"),
                    validation: .regularFile),
            ],
            locks: [
                .checkout("android-runtime-gfxstream-\(target.identifier)")
            ],
            assessmentPolicy: .incremental,
            operation: .sequence([
                .removePath(buildRoot),
                .createDirectory(buildRoot),
                gfxstreamOperation(
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
                gfxstreamOperation(
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

private func gfxstreamOperation(
    root: FilePath,
    hostSource: FilePath,
    guestSource: FilePath,
    buildRoot: FilePath,
    target: NativeLinuxTarget,
    builder: NativeOCIConfiguration,
    environment: [String: String],
    command: [String]
) -> TaskOperation {
    .runOCI(
        OCIExecution(
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
            output: .logged))
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
