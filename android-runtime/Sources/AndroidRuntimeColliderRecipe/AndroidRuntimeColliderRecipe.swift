import ColliderCore
import Foundation
import SystemPackage

public enum AndroidRuntimeColliderRecipe {
    private static let component = ComponentID(rawValue: "android-runtime")

    public static func tasks(
        root: FilePath,
        repositoryRoot: FilePath,
        environment: [String: String]
    ) throws -> [TaskDeclaration] {
        [
            try gfxstream(
                root: root,
                repositoryRoot: repositoryRoot,
                environment: environment),
            build(root: root, environment: environment),
        ]
    }

    public static func test(
        root: FilePath,
        environment: [String: String]
    ) -> TaskDeclaration {
        swiftTask(
            id: "android-runtime.test",
            root: root,
            environment: environment,
            arguments: ["test"],
            dependencies: [TaskID(rawValue: "android-runtime.build")])
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
            id: TaskID(rawValue: "android-runtime.aosp-source-lock"),
            component: component,
            dependencies: [
                TaskID(rawValue: "android-runtime.aosp-repo-launcher"),
            ],
            inputs: [
                .file(lockPath),
                .dependencyOutput(launcher),
                .tool(.named("git")),
            ],
            outputs: [
                OutputDeclaration(path: report, validation: .json),
            ],
            locks: [.checkout("android-runtime-aosp-source-lock")],
            cachePolicy: .always,
            operation: .verifyAOSPSourceLock(AOSPSourceLockVerification(
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
        let container = aospBuildContainer(
            root: root,
            environment: environment)
        let signing = aospSigningIdentity(
            root: root,
            environment: environment)
        let product = try aospProductImageTasks(
            root: root,
            environment: environment)
        return source + [container, signing] + product
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
                .file(root.appending("aosp.lock.json")),
            ],
            outputs: [
                OutputDeclaration(path: launcher, validation: .regularFile),
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
        let patchManifestPath = root.appending("aosp/patches.json")
        let patchStacks = try loadAOSPSourcePatchStacks(
            manifest: patchManifestPath,
            root: root)
        let lockPath = root.appending("aosp.lock.json")
        let launcher = try aospRepoLauncherPath(root: root)
        let verification = root.appending(
            ".aosp-tools/source-lock-verification.json")
        let source = root.appending(".aosp-source")
        return TaskDeclaration(
            id: TaskID(rawValue: "android-runtime.aosp-source"),
            component: component,
            dependencies: [
                TaskID(rawValue: "android-runtime.aosp-repo-launcher"),
                TaskID(rawValue: "android-runtime.aosp-source-lock"),
            ],
            inputs: [
                .file(lockPath),
                .file(patchManifestPath),
                .dependencyOutput(launcher),
                .dependencyOutput(verification),
                .tool(.named("git")),
                .tool(.named("python3")),
            ] + patchStacks.flatMap(\.patches).map { .file($0.file) },
            outputs: [
                OutputDeclaration(
                    path: source.appending(
                        ".nucleus/base-resolved-manifest.xml"),
                    validation: .regularFile),
                OutputDeclaration(
                    path: source.appending(
                        ".nucleus/patched-resolved-manifest.xml"),
                    validation: .regularFile),
                OutputDeclaration(
                    path: source.appending(".nucleus/source-provenance.json"),
                    validation: .json),
            ],
            locks: [.checkout("android-runtime-aosp-source")],
            operation: .prepareAOSPSource(AOSPSourcePreparation(
                specification: specification,
                launcher: launcher,
                source: source,
                patchStacks: patchStacks,
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

    private static func aospBuildContainer(
        root: FilePath,
        environment: [String: String]
    ) -> TaskDeclaration {
        let context = root.appending("build-container")
        let containerFile = context.appending("Containerfile")
        let imageID = root.appending(".aosp-build/container/image-id")
        return TaskDeclaration(
            id: TaskID(rawValue: "android-runtime.aosp-build-container"),
            component: component,
            inputs: [
                .tree(context),
                .tool(.named("podman")),
            ],
            outputs: [
                OutputDeclaration(path: imageID, validation: .regularFile),
            ],
            locks: [.checkout("android-runtime-aosp-container")],
            operation: .prepareAOSPBuildContainer(
                AOSPBuildContainerPreparation(
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
        let buildRoot = root.appending(".aosp-build")
        let ccacheDirectory = aospCCacheDirectory(environment: environment)
        let containerImageID = buildRoot.appending("container/image-id")
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
            environment: environment)
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
                TaskID(rawValue: "android-runtime.aosp-build-container"),
            ],
            inputs: [
                .value(
                    name: "aosp-product-identity",
                    bytes: productIdentity),
                .tree(root.appending(
                    "aosp/device/nucleus/nucleus_x86_64")),
                .dependencyOutput(launcher),
                .dependencyOutput(sourceProvenance),
                .dependencyOutput(containerImageID),
                .tool(.named("python3")),
                .tool(.named("podman")),
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
            operation: .compileAOSPProduct(build))
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
                .dependencyOutput(signingIdentity.appending(
                    "signing-identity.json")),
                .dependencyOutput(containerImageID),
                .tool(.named("openssl")),
                .tool(.named("podman")),
            ],
            outputs: [
                OutputDeclaration(
                    path: stagedTargetFiles,
                    validation: .regularFile),
            ],
            locks: [
                .checkout("android-runtime-aosp-source"),
                .checkout("android-runtime-aosp-build"),
            ],
            operation: .signAOSPProduct(build))
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
                .tool(.named("podman")),
            ],
            outputs: [
                OutputDeclaration(
                    path: stagedImageArchive,
                    validation: .regularFile)
            ] + requiredImages.map {
                OutputDeclaration(
                    path: stagedImages.appending($0),
                    validation: .regularFile)
            },
            locks: [
                .checkout("android-runtime-aosp-source"),
                .checkout("android-runtime-aosp-build"),
            ],
            operation: .assembleAOSPProductImages(build))
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
                .dependencyOutput(signingIdentity.appending(
                    "signing-identity.json")),
                .dependencyOutput(containerImageID),
                .tree(root.appending(
                    "aosp/device/nucleus/nucleus_x86_64")),
                .tool(.named("openssl")),
                .tool(.named("unzip")),
                .tool(.named("podman")),
            ] + requiredImages.map {
                .dependencyOutput(stagedImages.appending($0))
            },
            outputs: [
                OutputDeclaration(
                    path: stagedProvenance,
                    validation: .json),
            ],
            locks: [
                .checkout("android-runtime-aosp-source"),
                .checkout("android-runtime-aosp-build"),
            ],
            operation: .validateAOSPProduct(build))
        let publish = TaskDeclaration(
            id: TaskID(rawValue: "android-runtime.aosp-image"),
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
            ] + requiredImages.map {
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
            ] + requiredImages.map {
                OutputDeclaration(
                    path: images.appending($0),
                    validation: .regularFile)
            },
            locks: [.checkout("android-runtime-aosp-build")],
            operation: .publishAOSPProduct(build))
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
            from: Data(contentsOf: URL(
                fileURLWithPath: root.appending("aosp.lock.json").string)))
    }

    private static func loadAOSPSourcePatchStacks(
        manifest: FilePath,
        root: FilePath
    ) throws -> [AOSPSourcePatchStack] {
        let declaration = try JSONDecoder().decode(
            AOSPSourcePatchManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: manifest.string)))
        guard !declaration.repositories.isEmpty else {
            throw AndroidRuntimeRecipeFailure.invalidAOSPSourceLock(
                "forward-patch manifest must declare repositories")
        }
        var repositories = Set<String>()
        var patchPaths = Set<String>()
        return try declaration.repositories.map { repository in
            guard isSafeRelativePath(repository.path),
                  repositories.insert(repository.path).inserted
            else {
                throw AndroidRuntimeRecipeFailure.invalidAOSPSourceLock(
                    "forward-patch repository path is invalid or duplicated: "
                        + repository.path)
            }
            guard !repository.patches.isEmpty else {
                throw AndroidRuntimeRecipeFailure.invalidAOSPSourceLock(
                    "forward-patch repository \(repository.path) has no patches")
            }
            let patches = try repository.patches.map { path in
                guard path.hasPrefix("aosp/patches/"),
                      isSafeRelativePath(path),
                      patchPaths.insert(path).inserted
                else {
                    throw AndroidRuntimeRecipeFailure.invalidAOSPSourceLock(
                        "forward-patch path is invalid or duplicated: \(path)")
                }
                let file = root.appending(path)
                var isDirectory = ObjCBool(false)
                guard unsafe FileManager.default.fileExists(
                    atPath: file.string,
                    isDirectory: &isDirectory),
                      !isDirectory.boolValue
                else {
                    throw AndroidRuntimeRecipeFailure.invalidAOSPSourceLock(
                        "forward patch is not a regular file: \(path)")
                }
                return AOSPSourcePatch(path: path, file: file)
            }
            return AOSPSourcePatchStack(
                repositoryPath: repository.path,
                patches: patches)
        }
    }

    private static func aospRepoLauncherPath(
        root: FilePath
    ) throws -> FilePath {
        let lock = try loadAOSPSourceLock(root: root)
        try lock.validate()
        return root.appending(
            ".aosp-tools/repo-\(lock.repo.launcherVersion)")
    }

    private static func gfxstream(
        root: FilePath,
        repositoryRoot: FilePath,
        environment: [String: String]
    ) throws -> TaskDeclaration {
        let buildRoot = root.appending(".gfxstream-build")
        let hostSource = repositoryRoot.appending("third-party/gfxstream")
        let guestSource = repositoryRoot.appending("third-party/mesa")
        let hostBuild = buildRoot.appending("host")
        let guestBuild = buildRoot.appending("guest")
        guard let toolchain = environment["SWIFT_TOOLCHAIN"] else {
            throw AndroidRuntimeRecipeFailure.missingSwiftToolchain
        }
        let buildEnvironment = environment.merging([
            "CC": "\(toolchain)/bin/clang",
            "CXX": "\(toolchain)/bin/clang++",
            "LDFLAGS": "-Wl,-rpath,\(toolchain)/lib"
                + environment["LDFLAGS"].map { " \($0)" }.orEmpty,
        ]) { _, required in required }
        return TaskDeclaration(
            id: TaskID(rawValue: "android-runtime.gfxstream"),
            component: component,
            inputs: [
                .tree(hostSource),
                .tree(guestSource),
                .tool(.named("git")),
                .tool(.named("meson")),
            ],
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
                .checkout("android-runtime"),
                .checkout("gfxstream"),
                .checkout("mesa"),
            ],
            operation: .sequence([
                .configureMeson(MesonSetup(
                    source: hostSource,
                    build: hostBuild,
                    arguments: [
                        "-Dbuildtype=release",
                        "-Ddefault_library=static",
                        "-Ddecoders=gles,vulkan,composer",
                        "-Dgfxstream-build=host",
                    ],
                    environment: buildEnvironment)),
                .command(CommandSpec(
                    executable: .named("meson"),
                    arguments: [
                        "compile", "-C", hostBuild.string,
                        "gfxstream_backend",
                    ],
                    workingDirectory: root,
                    environment: buildEnvironment)),
                .configureMeson(MesonSetup(
                    source: guestSource,
                    build: guestBuild,
                    arguments: [
                        "-Dbuildtype=release",
                        "-Dvulkan-drivers=gfxstream",
                        "-Dgallium-drivers=[]",
                        "-Dplatforms=[]",
                        "-Dglx=disabled",
                        "-Degl=disabled",
                        "-Dgbm=disabled",
                        "-Dgles1=disabled",
                        "-Dgles2=disabled",
                        "-Dopengl=false",
                        "-Dllvm=disabled",
                        "-Dshared-glapi=disabled",
                        "-Dvalgrind=disabled",
                        "-Dlibunwind=disabled",
                        "-Dbuild-tests=false",
                        "-Dvideo-codecs=[]",
                        "-Dc_args=[]",
                        "-Dcpp_args=[]",
                    ],
                    environment: buildEnvironment)),
                .command(CommandSpec(
                    executable: .named("meson"),
                    arguments: [
                        "compile", "-C", guestBuild.string,
                        "vulkan_gfxstream",
                        "gfxstream_vk_icd",
                        "gfxstream_vk_devenv_icd",
                    ],
                    workingDirectory: root,
                    environment: buildEnvironment)),
            ]))
    }

    private static func build(
        root: FilePath,
        environment: [String: String]
    ) -> TaskDeclaration {
        swiftTask(
            id: "android-runtime.build",
            root: root,
            environment: environment,
            arguments: ["build"],
            dependencies: [
                TaskID(rawValue: "linux.build"),
                TaskID(rawValue: "android-runtime.gfxstream"),
            ])
    }

    private static func swiftTask(
        id: String,
        root: FilePath,
        environment: [String: String],
        arguments: [String],
        dependencies: [TaskID]
    ) -> TaskDeclaration {
        TaskDeclaration(
            id: TaskID(rawValue: id),
            component: component,
            dependencies: dependencies,
            inputs: [
                .file(root.appending("Package.swift")),
                .tree(root.appending("Sources")),
                .tree(root.appending("Tests")),
                .tree(root.appending(
                    "aosp/device/nucleus/nucleus_x86_64/native")),
                .tool(.named("swift")),
            ],
            outputs: [
                OutputDeclaration(
                    path: root.appending(".build"),
                    validation: .nonEmptyDirectory),
            ],
            locks: [.checkout("android-runtime")],
            operation: .command(CommandSpec(
                executable: .named("swift"),
                arguments: arguments,
                workingDirectory: root,
                environment: environment)))
    }
}

private struct AOSPSourceLock: Decodable {
    struct Platform: Decodable {
        let release: String
        let revision: String
        let manifestURL: String
        let manifestTagObject: String
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

    let platform: Platform
    let repo: Repo

    func validate() throws {
        guard platform.revision == "refs/tags/android-17.0.0_r1" else {
            throw AndroidRuntimeRecipeFailure.invalidAOSPSourceLock(
                "platform revision must be refs/tags/android-17.0.0_r1")
        }
        guard platform.release == "Android 17.0.0 Release 1" else {
            throw AndroidRuntimeRecipeFailure.invalidAOSPSourceLock(
                "platform release must be Android 17.0.0 Release 1")
        }
        guard platform.superprojectRevision
                == "refs/heads/android-17.0.0_r1"
        else {
            throw AndroidRuntimeRecipeFailure.invalidAOSPSourceLock(
                "superproject revision must be "
                    + "refs/heads/android-17.0.0_r1")
        }
        guard platform.manifestURL
                == "https://android.googlesource.com/platform/manifest",
              platform.superprojectURL
                == "https://android.googlesource.com/platform/superproject",
              repo.launcherURL
                == "https://storage.googleapis.com/git-repo-downloads/repo",
              repo.repositoryURL
                == "https://gerrit.googlesource.com/git-repo"
        else {
            throw AndroidRuntimeRecipeFailure.invalidAOSPSourceLock(
                "source URLs do not match the approved upstreams")
        }
        for (name, value, count) in [
            ("manifest tag object", platform.manifestTagObject, 40),
            ("manifest commit", platform.manifestCommit, 40),
            ("manifest digest", platform.defaultManifestSHA256, 64),
            ("superproject commit", platform.superprojectCommit, 40),
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
                sha256Hex: platform.defaultManifestSHA256),
            let launcherDigest = ArtifactDigest(
                sha256Hex: repo.launcherSHA256)
        else {
            throw AndroidRuntimeRecipeFailure.invalidAOSPSourceLock(
                "source digests are invalid")
        }
        return AOSPSourceSpecification(
            platform: AOSPPlatformSource(
                release: platform.release,
                revision: platform.revision,
                manifestURL: platform.manifestURL,
                manifestTagObject: platform.manifestTagObject,
                manifestCommit: platform.manifestCommit,
                defaultManifestDigest: defaultManifestDigest,
                superprojectURL: platform.superprojectURL,
                superprojectRevision: platform.superprojectRevision,
                superprojectCommit: platform.superprojectCommit),
            repo: AOSPRepoSource(
                launcherVersion: repo.launcherVersion,
                launcherDigest: launcherDigest,
                repositoryURL: repo.repositoryURL,
                revision: repo.revision,
                tagObject: repo.tagObject,
                commit: repo.commit))
    }
}

private struct AOSPSourcePatchManifest: Decodable {
    struct Repository: Decodable {
        let path: String
        let patches: [String]
    }

    let repositories: [Repository]
}

private func isSafeRelativePath(_ value: String) -> Bool {
    !value.isEmpty
        && !value.hasPrefix("/")
        && !value.hasSuffix("/")
        && value.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
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

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}

public enum AndroidRuntimeRecipeFailure: Error, CustomStringConvertible {
    case invalidAOSPProductLock(String)
    case invalidAOSPSourceLock(String)
    case missingSwiftToolchain

    public var description: String {
        switch self {
        case .invalidAOSPProductLock(let detail):
            "invalid AOSP product lock: \(detail)"
        case .invalidAOSPSourceLock(let detail):
            "invalid AOSP source lock: \(detail)"
        case .missingSwiftToolchain:
            "SWIFT_TOOLCHAIN is required to build gfxstream"
        }
    }
}
