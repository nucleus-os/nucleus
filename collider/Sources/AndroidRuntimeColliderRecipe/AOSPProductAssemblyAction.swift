import ColliderCore
import SystemPackage

struct AssembleAOSPProductImagesAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let sourceWorkspace: PersistentWorkspaceDeclaration
        let buildRoot: FilePath
        let containerImageID: FilePath
        let entrypoint: OCIMountedEntrypoint
        let product: String
        let expectedPlatformSDK: UInt32

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(sourceWorkspace.identity.key)
            encoder.append(sourceWorkspace.capacityBytes)
            encoder.append(path: buildRoot)
            encoder.append(path: containerImageID)
            encoder.append(
                nested: OCIMountedEntrypointActionIdentity(
                    entrypoint))
            encoder.append(product)
            encoder.append(UInt64(expectedPlatformSDK))
        }
    }

    static let kind: ActionKind = "android-runtime.assemble-aosp-product-images"

    let build: AOSPProductBuild

    var identity: Identity {
        Identity(
            sourceWorkspace: build.sourceWorkspace,
            buildRoot: build.artifactRoot,
            containerImageID: build.artifactEntrypoint.image.path,
            entrypoint: build.artifactEntrypoint,
            product: build.product,
            expectedPlatformSDK: build.expectedPlatformSDK)
    }

    var requirements: ActionRequirements {
        ActionRequirements(
            effects: (build.hostEffects(entrypoint: build.artifactEntrypoint) + [
                ActionEffect(.readWrite, scope: .scratch(build.artifactRoot))
            ]).uniqued(),
            persistentWorkspaceEffects: [
                ActionPersistentWorkspaceEffect(
                    workspace: build.sourceWorkspace,
                    target: "/src",
                    access: .readOnly),
                ActionPersistentWorkspaceEffect(
                    workspace: build.outputWorkspace,
                    target: "/src/out",
                    access: .readOnly),
            ],
            executionPlatform: .linuxARM64OCI,
            artifactTarget: build.artifactTarget)
    }

    var environment: [String: String] { build.environment }

    func execute(in context: ActionContext) async throws {
        let staged = build.artifactRoot.appending("staged")
        try context.files.createDirectory(staged)

        let signedTarget = staged.appending(
            "\(build.product)-target_files.zip")
        try requireRegularFile(signedTarget, files: context.files)
        let imageArchiveCandidate = staged.appending(
            ".\(build.product)-images.candidate.zip")
        try context.files.remove(imageArchiveCandidate)
        defer { try? context.files.remove(imageArchiveCandidate) }

        try await context.containers.run(
            aospProductOCIExecution(
                build: build,
                writableMounts: [(staged, "/staged")],
                readOnlyMounts: [],
                persistentWorkspaceMounts: [build.readOnlyOutputMount],
                executableRequirements: aospX86ExecutableRequirements([
                    "/src/out/host/linux-x86/bin/img_from_target_files"
                ]),
                command: [
                    "/src/out/host/linux-x86/bin/img_from_target_files",
                    "/staged/\(signedTarget.lastComponent?.string ?? "")",
                    "/staged/\(imageArchiveCandidate.lastComponent?.string ?? "")",
                ]))
        try requireRegularFile(imageArchiveCandidate, files: context.files)

        let imageCandidate = build.artifactRoot.appending(".images-candidate")
        try context.files.remove(imageCandidate)
        defer { try? context.files.remove(imageCandidate) }
        try context.files.createDirectory(imageCandidate)
        let extraction = try await context.containers.execute(
            aospProductOCIExecution(
                build: build,
                writableMounts: [(build.artifactRoot, "/export")],
                readOnlyMounts: [],
                persistentWorkspaceMounts: [build.readOnlyOutputMount],
                command: [
                    "/usr/bin/unzip", "-q",
                    "/export/staged/\(imageArchiveCandidate.lastComponent?.string ?? "")",
                    "-d", "/export/.images-candidate",
                ],
                workingDirectory: "/export",
                output: .combined(limit: 4 * 1_024 * 1_024)))
        guard extraction.succeeded else {
            throw extraction.executionFailure(
                reason: "AOSP product image extraction failed")
        }

        for name in aospRequiredProductImages {
            let image = imageCandidate.appending(name)
            try requireRegularFile(image, files: context.files)
            guard try isSparseImage(image, files: context.files) else {
                continue
            }
            let rawImage = FilePath(image.string + ".raw")
            try context.files.remove(rawImage)
            defer { try? context.files.remove(rawImage) }
            try await context.containers.run(
                aospProductOCIExecution(
                    build: build,
                    writableMounts: [(imageCandidate, "/images")],
                    readOnlyMounts: [],
                    persistentWorkspaceMounts: [build.readOnlyOutputMount],
                    executableRequirements: aospX86ExecutableRequirements([
                        "/src/out/host/linux-x86/bin/simg2img"
                    ]),
                    command: [
                        "/src/out/host/linux-x86/bin/simg2img",
                        "/images/\(name)",
                        "/images/\(name).raw",
                    ]))
            try requireRegularFile(rawImage, files: context.files)
            try context.files.remove(image)
            try context.files.move(from: rawImage, to: image)
        }

        let imageArchive = staged.appending("\(build.product)-images.zip")
        try context.files.remove(imageArchive)
        try context.files.move(
            from: imageArchiveCandidate,
            to: imageArchive)
        let stagedImages = staged.appending("images")
        try context.files.remove(stagedImages)
        try context.files.move(from: imageCandidate, to: stagedImages)

        try await stageHostTools(context: context, staged: staged)
    }

    /// Publishes the AVB tool into the generation.
    ///
    /// A consumer of a generation verifies its images against it, and the
    /// native package ships it so an installed runtime can verify them again.
    /// Neither consumer runs in this product's AOSP container, so the tool
    /// travels with the images rather than being reached for where it was
    /// found.
    ///
    /// It is taken from `external/avb` rather than from `out/host`, because
    /// the built host tool is a `python_binary_host` — an x86_64 ELF with an
    /// embedded interpreter, which is both the wrong architecture for an
    /// arm64 payload and a product of this build rather than a pinned input.
    /// The source form is the same program as an architecture-neutral script.
    private func stageHostTools(
        context: ActionContext,
        staged: FilePath
    ) async throws {
        let tools = staged.appending("tools")
        let candidate = staged.appending(".tools-candidate")
        try context.files.remove(candidate)
        defer { try? context.files.remove(candidate) }
        try context.files.createDirectory(candidate)
        try await context.containers.run(
            aospProductOCIExecution(
                build: build,
                writableMounts: [(candidate, "/tools")],
                readOnlyMounts: [],
                command: [
                    "/bin/cp", "--preserve=timestamps",
                    "/src/external/avb/avbtool.py",
                    "/tools/avbtool",
                ]))
        let publishedAVBTool = candidate.appending("avbtool")
        try requireRegularFile(publishedAVBTool, files: context.files)
        try requirePortableProgram(publishedAVBTool, files: context.files)
        try context.files.remove(tools)
        try context.files.move(from: candidate, to: tools)
    }

    /// Asserts at publication that a tool entering the generation is
    /// architecture-neutral, so a host binary staged by mistake fails here
    /// rather than in whichever consumer later tries to run it.
    private func requirePortableProgram(
        _ path: FilePath,
        files: ActionFileSystem
    ) throws {
        let prefix = try files.readPrefix(path, count: 128)
        guard let newline = prefix.firstIndex(of: 0x0a),
            let shebang = String(bytes: prefix[..<newline], encoding: .utf8),
            shebang.hasPrefix("#!"), shebang.contains("python")
        else {
            throw AOSPProductAssemblyFailure.untranslatableHostTool(path)
        }
    }

    private func requireRegularFile(
        _ path: FilePath,
        files: ActionFileSystem
    ) throws {
        guard try files.metadata(for: path)?.type == .regular else {
            throw AOSPProductAssemblyFailure.missingFile(path)
        }
    }

    private func isSparseImage(
        _ path: FilePath,
        files: ActionFileSystem
    ) throws -> Bool {
        let prefix = try files.readPrefix(path, count: 4)
        guard prefix.count == 4 else {
            throw AOSPProductAssemblyFailure.shortImage(path)
        }
        return prefix == [0x3a, 0xff, 0x26, 0xed]
    }
}

let aospRequiredProductImages = [
    "system.img",
    "system_ext.img",
    "product.img",
    "vendor.img",
    "vbmeta.img",
    "vbmeta_system.img",
]

enum AOSPContainerPhase: Sendable {
    case build
    case artifact
}

package func aospX86ExecutableRequirements(
    _ executables: [String]
) -> Set<OCIExecutableRequirement> {
    Set(
        executables.map {
            OCIExecutableRequirement(
                architecture: .x86_64,
                executable: $0)
        })
}

func aospProductOCIExecution(
    build: AOSPProductBuild,
    writableMounts: [(FilePath, String)],
    readOnlyMounts: [(FilePath, String)],
    persistentWorkspaceMounts: [OCIPersistentWorkspaceMount] = [],
    executableRequirements: Set<OCIExecutableRequirement> = [],
    command: [String],
    phase: AOSPContainerPhase = .artifact,
    workingDirectory: String = "/src",
    containerEnvironment: [String: String] = aospProductContainerToolEnvironment(),
    output: CommandSpec.Output = .logged
) -> OCIExecution {
    let entrypoint =
        phase == .build ? build.buildEntrypoint : build.artifactEntrypoint
    return OCIExecution(
        executionPlatform: .linuxARM64OCI,
        artifactTarget: build.artifactTarget,
        imageID: entrypoint.image.path,
        hostname: "android-build",
        workingDirectory: workingDirectory,
        hostWorkingDirectory: build.deviceSource,
        mounts: [entrypoint.mount, build.sourceInputsMount]
            + readOnlyMounts.map {
                OCIMount(source: $0.0, target: $0.1, access: .readOnly)
            }
            + writableMounts.map {
                OCIMount(boundedExport: $0.0, target: $0.1)
            },
        persistentWorkspaceMounts: [build.sourceMount] + persistentWorkspaceMounts,
        userPolicy: .builder,
        capabilityPolicy: .dropAll,
        privilegePolicy: .prohibitAcquisition,
        processFilesystemPolicy: .unmasked,
        executableRequirements: executableRequirements,
        resourceLimits: .build,
        containerEnvironment: containerEnvironment,
        imageEntrypointOverride: entrypoint.containerPath,
        command: command,
        environment: build.environment,
        output: output)
}

func aospDeviceSourceMounts(
    build: AOSPProductBuild
) -> [(FilePath, String)] {
    return [(build.assembledDeviceSource, "/src/device/nucleus")]
}

func aospProductContainerToolEnvironment() -> [String: String] {
    let javaHome = "/src/prebuilts/jdk/jdk21/linux-x86"
    return [
        "ANDROID_JAVA_HOME": javaHome,
        "HOME": "/home/nucleus-build",
        "JAVA_HOME": javaHome,
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "PATH": "\(javaHome)/bin:"
            + "/src/out/host/linux-x86/bin:"
            + "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "REPO_TRACE": "0",
        "SOONG_BOOTSTRAP_PREBUILT_TAG": "linux-x86",
        "SOONG_OUTER_SANDBOX": "1",
        "TZ": "UTC",
    ]
}

private enum AOSPProductAssemblyFailure: Error, CustomStringConvertible {
    case missingFile(FilePath)
    case shortImage(FilePath)
    case untranslatableHostTool(FilePath)

    var description: String {
        switch self {
        case .missingFile(let path):
            "required AOSP image assembly input is missing: \(path)"
        case .shortImage(let path):
            "Android image is too short: \(path)"
        case .untranslatableHostTool(let path):
            """
            a tool published into a generation must be architecture-neutral, \
            and this one is not: \(path)
            """
        }
    }
}
