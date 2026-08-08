import ColliderCore
import SystemPackage

struct AssembleAOSPProductImagesAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let source: FilePath
        let buildRoot: FilePath
        let containerImageID: FilePath
        let product: String
        let expectedPlatformSDK: UInt32

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: source.string)
            encoder.append(tag: 2, string: buildRoot.string)
            encoder.append(tag: 3, string: containerImageID.string)
            encoder.append(tag: 4, string: product)
            encoder.append(tag: 5, integer: UInt64(expectedPlatformSDK))
        }
    }

    static let kind: ActionKind = "android-runtime.assemble-aosp-product-images"

    let build: AOSPProductBuild

    var identity: Identity {
        Identity(
            source: build.source,
            buildRoot: build.buildRoot,
            containerImageID: build.containerImageID,
            product: build.product,
            expectedPlatformSDK: build.expectedPlatformSDK)
    }

    var requirements: ActionRequirements {
        ActionRequirements(
            effects: [
                ActionEffect(.read, scope: .input(build.source)),
                ActionEffect(.read, scope: .input(build.containerImageID)),
                ActionEffect(.readWrite, scope: .scratch(build.buildRoot)),
            ],
            executionPlatform: .linuxARM64OCI,
            artifactTarget: .androidX86_64(
                apiLevel: build.expectedPlatformSDK))
    }

    var environment: [String: String] { build.environment }

    func execute(in context: ActionContext) async throws {
        let output = build.buildRoot.appending("out")
        let staged = build.buildRoot.appending("staged")
        try context.files.createDirectory(staged)
        let hostTools = output.appending("host/linux-x86/bin")
        let imageTool = hostTools.appending("img_from_target_files")
        try requireExecutable(imageTool, files: context.files)

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
                readOnlyMounts: [
                    (build.source, "/src"),
                    (output, "/src/out/nucleus"),
                ],
                command: [
                    "/src/out/nucleus/host/linux-x86/bin/img_from_target_files",
                    "/staged/\(signedTarget.lastComponent?.string ?? "")",
                    "/staged/\(imageArchiveCandidate.lastComponent?.string ?? "")",
                ]))
        try requireRegularFile(imageArchiveCandidate, files: context.files)

        let imageCandidate = build.buildRoot.appending(".images-candidate")
        try context.files.remove(imageCandidate)
        defer { try? context.files.remove(imageCandidate) }
        try context.files.createDirectory(imageCandidate)
        let extraction = try await context.containers.execute(
            aospProductOCIExecution(
                build: build,
                writableMounts: [(build.buildRoot, "/build")],
                readOnlyMounts: [(build.source, "/src")],
                command: [
                    "/usr/bin/unzip", "-q",
                    "/build/staged/\(imageArchiveCandidate.lastComponent?.string ?? "")",
                    "-d", "/build/.images-candidate",
                ],
                workingDirectory: "/build",
                output: .combined(limit: 4 * 1_024 * 1_024)))
        guard extraction.status == 0 else {
            throw AOSPProductAssemblyFailure.commandFailed(
                "unzip", extraction.status)
        }

        let sparseImageTool = hostTools.appending("simg2img")
        for name in aospRequiredProductImages {
            let image = imageCandidate.appending(name)
            try requireRegularFile(image, files: context.files)
            guard try isSparseImage(image, files: context.files) else {
                continue
            }
            try requireExecutable(sparseImageTool, files: context.files)
            let rawImage = FilePath(image.string + ".raw")
            try context.files.remove(rawImage)
            defer { try? context.files.remove(rawImage) }
            try await context.containers.run(
                aospProductOCIExecution(
                    build: build,
                    writableMounts: [(imageCandidate, "/images")],
                    readOnlyMounts: [
                        (build.source, "/src"),
                        (output, "/src/out/nucleus"),
                    ],
                    command: [
                        "/src/out/nucleus/host/linux-x86/bin/simg2img",
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
    }

    private func requireExecutable(
        _ path: FilePath,
        files: ActionFileSystem
    ) throws {
        guard let metadata = try files.metadata(for: path),
            metadata.type == .regular,
            metadata.ownerExecutable
        else {
            throw AOSPProductAssemblyFailure.missingExecutable(path)
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

func aospProductOCIExecution(
    build: AOSPProductBuild,
    writableMounts: [(FilePath, String)],
    readOnlyMounts: [(FilePath, String)],
    command: [String],
    workingDirectory: String = "/src",
    containerEnvironment: [String: String] = aospProductContainerToolEnvironment(),
    output: CommandSpec.Output = .logged
) -> OCIExecution {
    OCIExecution(
        executionPlatform: .linuxARM64OCI,
        artifactTarget: .androidX86_64(apiLevel: build.expectedPlatformSDK),
        imageID: build.containerImageID,
        hostname: "android-build",
        workingDirectory: workingDirectory,
        hostWorkingDirectory: build.source,
        mounts: readOnlyMounts.map {
            OCIMount(source: $0.0, target: $0.1, access: .readOnly)
        }
            + writableMounts.map {
                OCIMount(source: $0.0, target: $0.1, access: .readWrite)
            },
        userPolicy: .builder,
        capabilityPolicy: .dropAll,
        privilegePolicy: .prohibitAcquisition,
        processFilesystemPolicy: .unmasked,
        intelBinaryTranslationPolicy: .required,
        resourceLimits: .build,
        containerEnvironment: containerEnvironment,
        command: command,
        environment: build.environment,
        output: output)
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
            + "/src/out/nucleus/host/linux-x86/bin:"
            + "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "TZ": "UTC",
    ]
}

private enum AOSPProductAssemblyFailure: Error, CustomStringConvertible {
    case commandFailed(String, Int32)
    case missingExecutable(FilePath)
    case missingFile(FilePath)
    case shortImage(FilePath)

    var description: String {
        switch self {
        case .commandFailed(let command, let status):
            "\(command) failed with status \(status)"
        case .missingExecutable(let path):
            "required AOSP host executable is missing: \(path)"
        case .missingFile(let path):
            "required AOSP image assembly input is missing: \(path)"
        case .shortImage(let path):
            "Android image is too short: \(path)"
        }
    }
}
