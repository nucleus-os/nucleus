import ColliderCore
import Foundation
import NativeBuilderColliderRecipe
import SystemPackage

package enum CoreEntrypoints {
    package static let androidBuild = ComponentEntrypointID(rawValue: "android.build")
    package static let androidNative = ComponentEntrypointID(rawValue: "android.native")
    package static let androidVerify = ComponentEntrypointID(rawValue: "android.verify")
}

package enum CoreTaskIDs {
    package static let gnDownload = TaskID(rawValue: "core.gn-download")
    package static let gnInstall = TaskID(rawValue: "core.gn-install")
    package static let sources = TaskID(rawValue: "core.sources")
    package static let androidNativeSDK = TaskID(rawValue: "core.native-sdk.android-arm64")
    package static let androidSkia = TaskID(rawValue: "core.skia.android-arm64")
    package static let androidHostBuild = TaskID(rawValue: "core.android-host.build")
    package static let validateAndroidHost = TaskID(
        rawValue: "core.android-host.validate")
    package static let androidBuild = TaskID(rawValue: "core.android.build")

    package static func skia(_ target: NativeLinuxTarget) -> TaskID {
        TaskID(rawValue: "core.skia.\(target.identifier)")
    }

    package static func nativeSDK(_ target: NativeLinuxTarget) -> TaskID {
        TaskID(rawValue: "core.native-sdk.\(target.identifier)")
    }
}

public enum CoreColliderRecipe: ColliderComponent {
    package struct ComponentArtifacts: Sendable {
        package let component: ComponentDefinition
        package let skiaExternalSources: ArtifactReference<DirectoryArtifact>
        package let linuxICULibraries: [NativeLinuxTarget: ArtifactReference<FileArtifact>]
        package let nativeSDKs: [NativeLinuxTarget: ArtifactReferenceSet]
    }

    package struct SkiaSourceArtifacts: Sendable {
        package let tasks: [TaskDeclaration]
        package let externalSources: ArtifactReference<DirectoryArtifact>
        package let gn: ArtifactReference<ExecutableArtifact>
    }

    package struct SkiaBuildArtifacts: Sendable {
        package let task: TaskDeclaration
        package let buildDirectory: ArtifactReference<DirectoryArtifact>
        package let icuLibrary: ArtifactReference<FileArtifact>
    }

    package struct NativeSDKArtifacts: Sendable {
        package let task: TaskDeclaration
        package let outputs: ArtifactReferenceSet
    }

    package struct AndroidHostArtifacts: Sendable {
        package let task: TaskDeclaration
        package let library: ArtifactReference<FileArtifact>
    }

    package enum AndroidHostValidationResult: TaskResultValue {}

    package struct AndroidHostValidationArtifacts: Sendable {
        package let task: TaskDeclaration
        package let result: TaskResultReference<AndroidHostValidationResult>
    }

    public static let descriptor = ComponentDescriptor(
        id: ComponentID(rawValue: "core"),
        canonicalName: "core",
        directoryName: "core")

    public static func makeComponent(
        in context: RecipeContext
    ) throws -> ComponentDefinition {
        try prepare(in: context).component
    }

    package static func prepare(
        in context: RecipeContext
    ) throws -> ComponentArtifacts {
        let root = context.componentRoot(descriptor)
        let sources = try prepareSkiaDependencies(
            root: root,
            environment: context.environment)
        var tasks = sources.tasks
        var roots: Set<TaskID> = []
        var linuxICULibraries: [NativeLinuxTarget: ArtifactReference<FileArtifact>] = [:]
        var nativeSDKs: [NativeLinuxTarget: ArtifactReferenceSet] = [:]
        for architecture in PlatformArchitecture.allCases {
            let target = NativeLinuxTarget(architecture: architecture)
            let skia = try buildSkiaLinux(
                root: root,
                environment: context.environment,
                target: target,
                sources: sources,
                builder: context.nativeBuilder)
            let sdk = try publishLinuxRenderSDK(
                root: root,
                sdkRoot: context.nativeSDK(for: target),
                target: target,
                skia: skia.buildDirectory)
            tasks += [skia.task, sdk.task]
            roots.insert(sdk.task.id)
            linuxICULibraries[target] = skia.icuLibrary
            nativeSDKs[target] = sdk.outputs
        }
        let androidToolchain = try AndroidToolchainVersions.load(
            workspaceRoot: context.repositoryRoot)
        let ndk = try androidToolchain.ndkRoot(
            environment: context.environment,
            validate: false,
            fallbackHome: context.cacheRoot.appending("nucleus/unconfigured-home"))
        let androidSDKRoot = context.nativeSDKRoot.appending("android-arm64")
        var androidEnvironment = context.environment
        androidEnvironment["NUCLEUS_NATIVE_SDK_ROOT"] = androidSDKRoot.string
        let androidSkia = try buildSkiaAndroid(
            root: root,
            minimumAndroidAPI: androidToolchain.minimumSDK,
            environment: androidEnvironment,
            sources: sources,
            builder: context.nativeBuilder)
        let androidNativeSDK = try publishAndroidRenderSDK(
            root: root,
            sdkRoot: androidSDKRoot,
            skia: androidSkia.buildDirectory)
        let androidSwiftPM = try context.swiftPM(
            .androidARM64(apiLevel: androidToolchain.minimumSDK))
        let androidHost = try buildAndroidHost(
            root: root,
            environment: androidEnvironment,
            swiftPM: androidSwiftPM,
            nativeSDK: androidNativeSDK.outputs)
        let androidValidation = try validateAndroidHost(
            root: root,
            library: androidHost.library,
            ndk: ndk,
            environment: androidEnvironment)
        let androidBuild = try buildAndroidProject(
            root: root,
            environment: androidEnvironment,
            validation: androidValidation.result)
        tasks += [
            androidSkia.task, androidNativeSDK.task, androidHost.task,
            androidValidation.task, androidBuild,
        ]
        let component = try ComponentDefinition(
            descriptor: descriptor,
            tasks: tasks,
            entrypoints: [
                ComponentEntrypoint(id: .bootstrap, roots: roots),
                ComponentEntrypoint(
                    id: CoreEntrypoints.androidBuild,
                    roots: [androidBuild.id]),
                ComponentEntrypoint(
                    id: CoreEntrypoints.androidNative,
                    roots: [androidValidation.task.id]),
                ComponentEntrypoint(
                    id: CoreEntrypoints.androidVerify,
                    roots: [androidValidation.task.id]),
            ])
        return ComponentArtifacts(
            component: component,
            skiaExternalSources: sources.externalSources,
            linuxICULibraries: linuxICULibraries,
            nativeSDKs: nativeSDKs)
    }

    package static func prepareSkiaDependencies(
        root: FilePath,
        environment: [String: String]
    ) throws -> SkiaSourceArtifacts {
        let skia = root.appending("third-party/skia")
        let gnArchive = root.appending(".skia-build/downloads/gn-linux-arm64.zip")
        let dependencies = try skiaGitDependencies(from: skia.appending("DEPS"))
        guard
            let gnURL = URL(
                string:
                    "https://chrome-infra-packages.appspot.com/dl/gn/gn/linux-arm64/+/git_revision:b2afae122eeb6ce09c52d63f67dc53fc517dbdc8"
            ),
            let gnDigest = ArtifactDigest(
                sha256Hex:
                    "376e1358ded109d955b8eb55ba2a7dec0e95ab1f8dfe0e18011e06eed78a011f")
        else {
            preconditionFailure("the pinned Linux arm64 GN artifact is invalid")
        }
        let gnDownload = try DownloadSpec(
            url: gnURL,
            permittedRedirectOrigins: [
                "https://chrome-infra-packages.appspot.com",
                "https://storage.googleapis.com",
            ],
            expectedDigest: gnDigest,
            maximumResponseSize: 16 * 1_024 * 1_024,
            acceptedMediaTypes: ["application/octet-stream"])
        var downloadBuilder = TaskBuilder(
            id: CoreTaskIDs.gnDownload,
            component: ComponentID(rawValue: "core"))
        let archive: ArtifactReference<FileArtifact> = try downloadBuilder.output(
            "archive",
            path: gnArchive,
            validation: .regularFile)
        let download = downloadBuilder.build(
            locks: [.checkout("core-sources")],
            action:
                try AnyColliderAction(
                    DownloadSkiaGNAction(
                        specification: gnDownload,
                        destination: gnArchive)))

        var sourceBuilder = TaskBuilder(
            id: CoreTaskIDs.sources,
            component: ComponentID(rawValue: "core"))
        let externalSources: ArtifactReference<DirectoryArtifact> = try sourceBuilder.output(
            "external-sources",
            path: skia.appending("third_party/externals"),
            validation: .nonEmptyDirectory)
        let sources = sourceBuilder.build(
            inputs: [
                .file(skia.appending("DEPS"))
            ],
            locks: [.checkout("core-sources")],
            assessmentPolicy: .always,
            action:
                try AnyColliderAction(
                    MaterializeSkiaDependenciesAction(
                        skia: skia,
                        dependencies: dependencies,
                        environment: environment)))

        var installBuilder = TaskBuilder(
            id: CoreTaskIDs.gnInstall,
            component: ComponentID(rawValue: "core"))
        installBuilder.consume(archive)
        let gn: ArtifactReference<ExecutableArtifact> = try installBuilder.output(
            "gn",
            path: skia.appending("bin/gn"),
            validation: .executableFile)
        let install = installBuilder.build(
            locks: [.checkout("core-sources")],
            action:
                try AnyColliderAction(
                    InstallSkiaGNAction(
                        archive: gnArchive,
                        executable: skia.appending("bin/gn"),
                        environment: environment)))
        return SkiaSourceArtifacts(
            tasks: [download, sources, install],
            externalSources: externalSources,
            gn: gn)
    }

    private static func skiaGitDependencies(
        from deps: FilePath
    ) throws -> [SkiaGitDependency] {
        let source = try String(
            contentsOf: URL(fileURLWithPath: deps.string),
            encoding: .utf8)
        let expression = try NSRegularExpression(
            pattern:
                #"(?m)^\s*["']([^"']+)["']\s*:\s*["'](https://[^"']+)@([0-9a-f]{40})["']\s*,?\s*$"#)
        let range = NSRange(source.startIndex..., in: source)
        var paths: Set<String> = []
        let dependencies = expression.matches(in: source, range: range).map { match in
            func capture(_ index: Int) -> String {
                String(source[Range(match.range(at: index), in: source)!])
            }
            return SkiaGitDependency(
                relativePath: capture(1),
                remote: capture(2),
                commit: capture(3))
        }.sorted { $0.relativePath < $1.relativePath }
        guard !dependencies.isEmpty else {
            throw SkiaDependencyFailure.noGitDependencies(deps)
        }
        for dependency in dependencies {
            let path = FilePath(dependency.relativePath)
            guard !path.isAbsolute,
                !dependency.relativePath.split(separator: "/").contains(".."),
                paths.insert(dependency.relativePath).inserted
            else {
                throw SkiaDependencyFailure.invalidCheckout(
                    dependency.relativePath)
            }
        }
        return dependencies
    }

    package static func buildSkiaLinux(
        root: FilePath,
        environment: [String: String],
        target: NativeLinuxTarget,
        sources: SkiaSourceArtifacts,
        builder: NativeOCIConfiguration
    ) throws -> SkiaBuildArtifacts {
        try skiaTask(
            id: CoreTaskIDs.skia(target),
            root: root,
            environment: environment,
            buildDirectory: root.appending(".skia-build/\(target.identifier)"),
            gnArguments: linuxGNArguments(target),
            mode: "linux",
            artifactTarget: target.artifactTarget,
            intelBinaryTranslationPolicy: target.intelBinaryTranslationPolicy,
            containerEnvironment: targetEnvironment(target),
            externalSources: sources.externalSources,
            gn: sources.gn,
            builder: builder)
    }

    package static func buildSkiaAndroid(
        root: FilePath,
        minimumAndroidAPI: UInt32,
        environment: [String: String],
        sources: SkiaSourceArtifacts,
        builder: NativeOCIConfiguration
    ) throws -> SkiaBuildArtifacts {
        let ndk = "/opt/android-ndk-r30-beta2"
        return try skiaTask(
            id: CoreTaskIDs.androidSkia,
            root: root,
            environment: environment,
            buildDirectory: root.appending(".skia-build/android-arm64"),
            gnArguments: [
                #"target_os="android""#,
                #"target_cpu="arm64""#,
                #"ndk="\#(ndk)""#,
                "ndk_api=\(minimumAndroidAPI)",
                "skia_use_fontconfig=false",
            ] + commonGNArguments,
            mode: "android",
            artifactTarget: .androidARM64(apiLevel: minimumAndroidAPI),
            intelBinaryTranslationPolicy: .required,
            containerEnvironment: [:],
            externalSources: sources.externalSources,
            gn: sources.gn,
            builder: builder)
    }

    package static func buildAndroidHost(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation,
        nativeSDK: ArtifactReferenceSet
    ) throws -> AndroidHostArtifacts {
        let package = root.appending("platform-android")
        let product = swiftPM.configurationProducts.appending(
            "libnucleus-android.so")
        var builder = TaskBuilder(
            id: CoreTaskIDs.androidHostBuild,
            component: ComponentID(rawValue: "core"))
        builder.consume(nativeSDK)
        let library: ArtifactReference<FileArtifact> = try builder.output(
            "android-library",
            path: product,
            validation: .regularFile)
        let task = builder.build(
            swiftProducts: [
                swiftPM.product(
                    package: "platform-android",
                    product: "nucleus-android",
                    packageRoot: package,
                    environment: environment,
                    expectedOutputs: [
                        PathPostcondition(
                            path: swiftPM.executable("nucleus-android"),
                            validation: .executableFile)
                    ])
            ],
            inputs: [
                .tree(package.appending("c")),
                .tree(package.appending("swift-core")),
                .tree(package.appending("swift-jni")),
                swiftPM.identityInput,
            ],
            postconditions: [
                swiftPM.postcondition,
                PathPostcondition(
                    path: product,
                    validation: .regularFile),
            ],
            locks: [.checkout("core-android-host")])
        return AndroidHostArtifacts(task: task, library: library)
    }

    package static func validateAndroidHost(
        root: FilePath,
        library: ArtifactReference<FileArtifact>,
        ndk: FilePath,
        environment: [String: String]
    ) throws -> AndroidHostValidationArtifacts {
        let hostLibrary = library.path
        let kotlinContract = root.appending(
            "android/nucleus/src/main/kotlin/dev/nucleus/android/"
                + "NucleusNative.kt")
        let readelf = androidNDKReadELFPath(ndk)
        var builder = TaskBuilder(
            id: CoreTaskIDs.validateAndroidHost,
            component: ComponentID(rawValue: "core"))
        builder.consume(library)
        let result: TaskResultReference<AndroidHostValidationResult> =
            try builder.result("validation")
        let task = builder.build(
            inputs: [.file(kotlinContract)],
            assessmentPolicy: .always,
            action:
                try AnyColliderAction(
                    ValidateAndroidHostAction(
                        library: hostLibrary,
                        kotlinContract: kotlinContract,
                        readelf: readelf,
                        minimumSwiftJavaThunkCount: 20,
                        environment: environment)))
        return AndroidHostValidationArtifacts(task: task, result: result)
    }

    package static func buildAndroidProject(
        root: FilePath,
        environment: [String: String],
        validation: TaskResultReference<AndroidHostValidationResult>
    ) throws -> TaskDeclaration {
        let android = root.appending("android")
        var builder = TaskBuilder(
            id: CoreTaskIDs.androidBuild,
            component: descriptor.id)
        builder.consume(validation)
        return builder.build(
            inputs: [
                .file(android.appending("settings.gradle.kts")),
                .file(android.appending("build.gradle.kts")),
                .file(android.appending("gradle/libs.versions.toml")),
                .tree(android.appending("nucleus/src")),
                .tree(android.appending("smoke-app/src")),
                .tool(.path(android.appending("gradlew"))),
            ],
            locks: [.checkout("core-android-gradle")],
            assessmentPolicy: .always,
            action:
                try AnyColliderAction(
                    VerifyAndroidProjectAction(
                        project: android,
                        environment: environment)))
    }

    package static func publishAndroidRenderSDK(
        root: FilePath,
        sdkRoot: FilePath,
        skia: ArtifactReference<DirectoryArtifact>
    ) throws -> NativeSDKArtifacts {
        let sdk = sdkRoot.appending("render")
        let links: [(String, FilePath)] = [
            ("include/skia", root.appending("third-party/skia")),
            ("lib/skia-graphite", skia.path),
            ("include/skia-text", root.appending("render-cxx/skia")),
        ]
        var builder = TaskBuilder(
            id: CoreTaskIDs.androidNativeSDK,
            component: ComponentID(rawValue: "core"))
        builder.consume(skia)
        var outputs = ArtifactReferenceSet()
        for (name, _) in links {
            let output: ArtifactReference<PathArtifact> = try builder.output(
                OutputSlotID(rawValue: name),
                path: sdk.appending(name),
                validation: .symlinkTarget)
            outputs.append(output)
        }
        let task = builder.build(
            inputs: links.map {
                .value(
                    name: $0.0,
                    bytes: Array($0.1.string.utf8))
            },
            locks: [
                .shared(sdkRoot.appending(".render.lock"))
            ],
            action:
                try AnyColliderAction(
                    PublishRenderSDKAction(sdk: sdk, links: links)))
        return NativeSDKArtifacts(task: task, outputs: outputs)
    }

    package static func publishLinuxRenderSDK(
        root: FilePath,
        sdkRoot: FilePath,
        target: NativeLinuxTarget,
        skia: ArtifactReference<DirectoryArtifact>
    ) throws -> NativeSDKArtifacts {
        let sdk = sdkRoot.appending("render")
        let links: [(String, FilePath)] = [
            ("include/skia", root.appending("third-party/skia")),
            (
                "lib/skia-graphite",
                skia.path
            ),
            ("include/skia-text", root.appending("render-cxx/skia")),
        ]
        var builder = TaskBuilder(
            id: CoreTaskIDs.nativeSDK(target),
            component: ComponentID(rawValue: "core"))
        builder.consume(skia)
        var outputs = ArtifactReferenceSet()
        for (name, _) in links {
            let output: ArtifactReference<PathArtifact> = try builder.output(
                OutputSlotID(rawValue: name),
                path: sdk.appending(name),
                validation: .symlinkTarget)
            outputs.append(output)
        }
        let task = builder.build(
            inputs: links.map {
                .value(name: $0.0, bytes: Array($0.1.string.utf8))
            },
            locks: [.shared(sdkRoot.appending(".render.lock"))],
            action:
                try AnyColliderAction(
                    PublishRenderSDKAction(sdk: sdk, links: links)))
        return NativeSDKArtifacts(task: task, outputs: outputs)
    }
}

private struct ValidateAndroidHostAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let library: FilePath
        let kotlinContract: FilePath
        let readelf: FilePath
        let minimumSwiftJavaThunkCount: UInt32

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: library.string)
            encoder.append(tag: 2, string: kotlinContract.string)
            encoder.append(tag: 3, string: readelf.string)
            encoder.append(tag: 4, integer: UInt64(minimumSwiftJavaThunkCount))
        }
    }

    static let kind: ActionKind = "core.validate-android-host"

    let library: FilePath
    let kotlinContract: FilePath
    let readelf: FilePath
    let minimumSwiftJavaThunkCount: UInt32
    let environment: [String: String]

    var identity: Identity {
        Identity(
            library: library,
            kotlinContract: kotlinContract,
            readelf: readelf,
            minimumSwiftJavaThunkCount: minimumSwiftJavaThunkCount)
    }

    var requirements: ActionRequirements {
        ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "llvm-readelf",
                    executable: .path(readelf),
                    role: .semantic)
            ],
            effects: [
                ActionEffect(.read, scope: .input(library)),
                ActionEffect(.read, scope: .input(kotlinContract)),
            ],
            executionPlatform: .macOSARM64Native)
    }

    func execute(in context: ActionContext) async throws {
        guard try context.files.metadata(for: library)?.type == .regular else {
            throw AndroidHostValidationFailure.invalidOutput(
                "Android host library is missing: \(library)")
        }
        guard try context.files.metadata(for: kotlinContract)?.type == .regular else {
            throw AndroidHostValidationFailure.invalidOutput(
                "Android Kotlin JNI contract is missing: \(kotlinContract)")
        }

        func inspect(_ arguments: [String]) async throws -> String {
            let result = try await context.commands.execute(
                CommandSpec(
                    executable: .path(readelf),
                    arguments: arguments + [library.string],
                    workingDirectory: library.removingLastComponent(),
                    environment: environment,
                    output: .captured(limit: 64 * 1_024 * 1_024)))
            guard result.status == 0 else {
                throw AndroidHostValidationFailure.commandFailed(result.status)
            }
            return result.standardOutput
        }

        let header = try await inspect(["-h"])
        let dynamic = try await inspect(["-d"])
        let symbols = try await inspect(["-Ws"])
        var failures: [String] = []
        func require(_ condition: Bool, _ description: String) {
            if !condition { failures.append(description) }
        }
        require(
            header.contains("Machine:") && header.contains("AArch64"),
            "ELF machine is not AArch64")
        for dependency in ["libandroid.so", "libvulkan.so", "libSwiftJava.so"] {
            require(
                dynamic.contains("[\(dependency)]"),
                "missing dynamic dependency \(dependency)")
        }
        require(!dynamic.contains("[libswiftCore.so]"), "must not link libswiftCore.so")
        require(symbols.contains("JNI_OnLoad"), "missing JNI_OnLoad export")
        require(
            symbols.range(
                of: #"\sFUNC\s+LOCAL\s+PROTECTED\s+\d+\s+swift_retain(?:\s|$)"#,
                options: .regularExpression) != nil,
            "missing static Swift runtime")

        let sourceBytes = try context.files.read(kotlinContract)
        guard let source = String(bytes: sourceBytes, encoding: .utf8) else {
            throw AndroidHostValidationFailure.invalidOutput(
                "Android Kotlin JNI contract is not UTF-8")
        }
        let expression = try NSRegularExpression(
            pattern: #"external\s+fun\s+([A-Za-z0-9_]+)"#)
        let range = NSRange(source.startIndex..., in: source)
        let functions = expression.matches(in: source, range: range).compactMap {
            match -> String? in
            guard let value = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[value])
        }
        require(!functions.isEmpty, "Kotlin contract declares no external functions")
        for function in functions {
            require(
                symbols.contains("Java_dev_nucleus_android_NucleusNative_\(function)"),
                "missing JNI export for NucleusNative.\(function)")
        }
        let thunkCount =
            symbols.components(separatedBy: "Java_dev_nucleus_android_AndroidHost__")
            .count - 1
        require(
            thunkCount >= Int(minimumSwiftJavaThunkCount),
            "found \(thunkCount) swift-java AndroidHost thunks; expected at least "
                + "\(minimumSwiftJavaThunkCount)")
        guard failures.isEmpty else {
            throw AndroidHostValidationFailure.invalidOutput(
                "Android host validation failed:\n  "
                    + failures.joined(separator: "\n  "))
        }
    }
}

private enum AndroidHostValidationFailure: Error {
    case commandFailed(Int32)
    case invalidOutput(String)
}

private struct DownloadSkiaGNAction: ColliderAction {
    static let kind: ActionKind = "core.download-skia-gn"

    let identity: DownloadActionIdentity

    init(specification: DownloadSpec, destination: FilePath) {
        identity = DownloadActionIdentity(
            specification: specification,
            destination: destination)
    }

    var requirements: ActionRequirements {
        ActionRequirements(
            effects: [
                ActionEffect(.readWrite, scope: .output(identity.destination))
            ], executionPlatform: .macOSARM64Native)
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

private struct PublishRenderSDKAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let sdk: FilePath
        let links: [(name: String, target: FilePath)]

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.sdk == rhs.sdk
                && lhs.links.elementsEqual(rhs.links) {
                    $0.name == $1.name && $0.target == $1.target
                }
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(sdk)
            for link in links {
                hasher.combine(link.name)
                hasher.combine(link.target)
            }
        }

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: sdk.string)
            encoder.append(
                tag: 2,
                string: links.map { "\($0.name)\u{0}\($0.target.string)" }
                    .joined(separator: "\u{1}"))
        }
    }

    static let kind: ActionKind = "core.publish-render-sdk"

    let sdk: FilePath
    let links: [(name: String, target: FilePath)]

    var identity: Identity { Identity(sdk: sdk, links: links) }

    var requirements: ActionRequirements {
        ActionRequirements(
            effects: [
                ActionEffect(.write, scope: .publication(sdk))
            ], executionPlatform: .macOSARM64Native)
    }

    func execute(in context: ActionContext) async throws {
        for link in links {
            try context.files.replaceSymlink(
                at: sdk.appending(link.name),
                target: link.target.string)
        }
    }
}

private struct VerifyAndroidProjectAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let project: FilePath

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: project.string)
            encoder.append(tag: 2, string: "verifyDebug")
        }
    }

    static let kind: ActionKind = "core.verify-android-project"

    let project: FilePath
    let environment: [String: String]

    var identity: Identity { Identity(project: project) }

    var requirements: ActionRequirements {
        ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "gradle-wrapper",
                    executable: .path(project.appending("gradlew")),
                    role: .semantic)
            ],
            effects: [
                ActionEffect(.readWrite, scope: .checkout(project))
            ],
            executionPlatform: .macOSARM64Native)
    }

    func execute(in context: ActionContext) async throws {
        let result = try await context.commands.execute(
            CommandSpec(
                executable: .path(project.appending("gradlew")),
                arguments: ["verifyDebug"],
                workingDirectory: project,
                environment: environment))
        guard result.status == 0 else {
            throw AndroidProjectVerificationFailure.commandFailed(result.status)
        }
    }
}

private enum AndroidProjectVerificationFailure: Error {
    case commandFailed(Int32)
}

private struct SkiaGitDependency: Hashable, Sendable {
    let relativePath: String
    let remote: String
    let commit: String
}

private struct MaterializeSkiaDependenciesAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let skia: FilePath
        let dependencies: [SkiaGitDependency]

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: skia.string)
            encoder.append(
                tag: 2,
                string: dependencies.map {
                    "\($0.relativePath)\u{1}\($0.remote)\u{1}\($0.commit)"
                }.joined(separator: "\0"))
        }
    }

    static let kind: ActionKind = "core.materialize-skia-dependencies"

    let skia: FilePath
    let dependencies: [SkiaGitDependency]
    let environment: [String: String]

    var identity: Identity { Identity(skia: skia, dependencies: dependencies) }

    var requirements: ActionRequirements {
        let checkouts = dependencies.map { skia.appending($0.relativePath) }
        let parents = Set(checkouts.map { $0.removingLastComponent() }).sorted {
            $0.string < $1.string
        }
        return ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "git", executable: .named("git"), role: .operational)
            ],
            effects: [
                ActionEffect(.read, scope: .input(skia.appending("DEPS"))),
                ActionEffect(
                    .read,
                    scope: .input(skia.appending("sync-deps.disable"))),
            ]
                + parents.map {
                    ActionEffect(.readWrite, scope: .checkout($0))
                }
                + checkouts.map {
                    ActionEffect(.readWrite, scope: .checkout($0))
                },
            executionPlatform: .macOSARM64Native)
    }

    func execute(in context: ActionContext) async throws {
        let disabled = skia.appending("sync-deps.disable")
        guard try context.files.metadata(for: disabled) == nil else {
            throw SkiaDependencyFailure.disabled(disabled)
        }
        for dependency in dependencies {
            try context.cancellation.check()
            let checkout = skia.appending(dependency.relativePath)
            try context.files.createDirectory(checkout.removingLastComponent())
            let gitDirectory = checkout.appending(".git")
            if try context.files.metadata(for: gitDirectory) == nil {
                try await requireSuccess(
                    ["init", checkout.string],
                    workingDirectory: skia,
                    context: context)
                try await requireSuccess(
                    ["-C", checkout.string, "remote", "add", "origin", dependency.remote],
                    workingDirectory: skia,
                    context: context)
            } else {
                let dirty = try await git(
                    [
                        "-C", checkout.string, "status", "--porcelain",
                        "--untracked-files=no",
                    ],
                    workingDirectory: skia,
                    context: context)
                guard dirty.status == 0, dirty.standardOutput.isEmpty else {
                    throw SkiaDependencyFailure.trackedModifications(
                        dependency.relativePath)
                }
                try await requireSuccess(
                    [
                        "-C", checkout.string, "remote", "set-url", "origin",
                        dependency.remote,
                    ],
                    workingDirectory: skia,
                    context: context)
            }

            let object = try await git(
                ["-C", checkout.string, "cat-file", "-e", "\(dependency.commit)^{commit}"],
                workingDirectory: skia,
                context: context)
            if object.status != 0 {
                try await requireSuccess(
                    [
                        "-C", checkout.string, "fetch", "--no-tags", "--depth=1",
                        "origin", dependency.commit,
                    ],
                    workingDirectory: skia,
                    context: context)
            }
            try await requireSuccess(
                ["-C", checkout.string, "checkout", "--detach", "--force", dependency.commit],
                workingDirectory: skia,
                context: context)
            let resolved = try await git(
                ["-C", checkout.string, "rev-parse", "HEAD"],
                workingDirectory: skia,
                context: context)
            guard resolved.status == 0,
                resolved.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                    == dependency.commit
            else {
                throw SkiaDependencyFailure.wrongCommit(
                    dependency.relativePath,
                    expected: dependency.commit,
                    actual: resolved.standardOutput)
            }
            let dirty = try await git(
                [
                    "-C", checkout.string, "status", "--porcelain",
                    "--untracked-files=no",
                ],
                workingDirectory: skia,
                context: context)
            guard dirty.status == 0, dirty.standardOutput.isEmpty else {
                throw SkiaDependencyFailure.trackedModifications(
                    dependency.relativePath)
            }
        }
    }

    private func requireSuccess(
        _ arguments: [String],
        workingDirectory: FilePath,
        context: ActionContext
    ) async throws {
        let result = try await git(
            arguments,
            workingDirectory: workingDirectory,
            context: context)
        guard result.status == 0 else {
            throw SkiaDependencyFailure.gitFailed(arguments, result.status)
        }
    }

    private func git(
        _ arguments: [String],
        workingDirectory: FilePath,
        context: ActionContext
    ) async throws -> CommandResult {
        try await context.commands.execute(
            CommandSpec(
                executable: .named("git"),
                arguments: arguments,
                workingDirectory: workingDirectory,
                environment: environment,
                output: .combined(limit: 1_048_576)))
    }
}

private struct InstallSkiaGNAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let archive: FilePath
        let executable: FilePath

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: archive.string)
            encoder.append(tag: 2, string: executable.string)
            encoder.append(tag: 3, string: "gn")
            encoder.append(tag: 4, integer: 0o755)
        }
    }

    static let kind: ActionKind = "core.install-skia-gn"

    let archive: FilePath
    let executable: FilePath
    let environment: [String: String]

    var identity: Identity { Identity(archive: archive, executable: executable) }

    var requirements: ActionRequirements {
        ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "unzip", executable: .named("unzip"), role: .operational)
            ],
            effects: [
                ActionEffect(.read, scope: .input(archive)),
                ActionEffect(
                    .readWrite,
                    scope: .output(executable.removingLastComponent())),
            ],
            executionPlatform: .macOSARM64Native)
    }

    func execute(in context: ActionContext) async throws {
        let destination = executable.removingLastComponent()
        try context.files.createDirectory(destination)
        let result = try await context.commands.execute(
            CommandSpec(
                executable: .named("unzip"),
                arguments: ["-o", archive.string, "gn", "-d", destination.string],
                workingDirectory: destination,
                environment: environment))
        guard result.status == 0 else {
            throw SkiaDependencyFailure.unzipFailed(result.status)
        }
        try context.files.setPermissions(0o755, for: executable)
    }
}

private enum SkiaDependencyFailure: Error {
    case noGitDependencies(FilePath)
    case invalidCheckout(String)
    case disabled(FilePath)
    case trackedModifications(String)
    case wrongCommit(String, expected: String, actual: String)
    case gitFailed([String], Int32)
    case unzipFailed(Int32)
}

private let ninjaTargets = ["skia", "skshaper", "skparagraph", "skunicode", "svg"]
private let requiredArchives = [
    "libskia.a", "libskshaper.a", "libskparagraph.a",
    "libskunicode_core.a", "libskunicode_icu.a", "libsvg.a",
    "libskcms.a", "libskresources.a", "libfreetype2.a",
    "libharfbuzz.a", "libicu.a", "libpng.a", "libjpeg.a",
    "libjpeg12.a", "libjpeg16.a", "libwebp.a", "libwebp_sse41.a",
    "libexpat.a", "libzlib.a", "libwuffs.a", "libdng_sdk.a",
    "libpiex.a",
]
private let commonGNArguments = [
    #"cc_wrapper="ccache""#,
    "is_official_build=true", "skia_enable_tools=false",
    "skia_enable_graphite=true", "skia_use_dawn=false", "skia_use_vulkan=true",
    "skia_use_freetype=true", "skia_use_harfbuzz=true", "skia_use_icu=true",
    "skia_use_expat=true", "skia_use_zlib=true", "skia_use_wuffs=true",
    "skia_use_libpng_decode=true", "skia_use_libpng_encode=true",
    "skia_use_libjpeg_turbo_decode=true",
    "skia_use_libjpeg_turbo_encode=true",
    "skia_use_libwebp_decode=true", "skia_use_libwebp_encode=true",
    "skia_enable_skshaper=true", "skia_enable_skparagraph=true",
    "skia_enable_skunicode=true", "skia_enable_svg=true",
    "skia_enable_pdf=true", "skia_enable_precompile=true",
    "skia_use_system_expat=false", "skia_use_system_freetype2=false",
    "skia_use_system_harfbuzz=false", "skia_use_system_icu=false",
    "skia_use_system_libjpeg_turbo=false", "skia_use_system_libpng=false",
    "skia_use_system_libwebp=false", "skia_use_system_zlib=false",
]
private func linuxGNArguments(_ target: NativeLinuxTarget) -> [String] {
    let sysroot = target.containerSwiftSDKRoot
    return [
        #"target_os="linux""#,
        #"target_cpu="\#(target.architecture == .arm64 ? "arm64" : "x64")""#,
        "skia_use_partition_alloc=false",
        "skia_use_fontconfig=true",
        #"extra_cflags=["--target=\#(target.targetTriple)","--sysroot=\#(sysroot)","-idirafter/usr/include","-idirafter/usr/include/\#(target.gnuArchitecture)"]"#,
        #"extra_cflags_cc=["--target=\#(target.targetTriple)","--sysroot=\#(sysroot)","-stdlib=libc++","-idirafter/usr/include","-idirafter/usr/include/\#(target.gnuArchitecture)"]"#,
        #"extra_asmflags=["--target=\#(target.targetTriple)","--sysroot=\#(sysroot)"]"#,
        #"extra_ldflags=["--target=\#(target.targetTriple)","--sysroot=\#(sysroot)","-stdlib=libc++","-fuse-ld=lld","-L/usr/lib/\#(target.gnuArchitecture)"]"#,
        #"cc="clang""#,
        #"cxx="clang++""#,
    ] + commonGNArguments
}

private func targetEnvironment(
    _ target: NativeLinuxTarget
) -> [String: String] {
    [
        "PKG_CONFIG_LIBDIR":
            "/usr/lib/\(target.gnuArchitecture)/pkgconfig:/usr/share/pkgconfig"
    ]
}

private func androidNDKReadELFPath(_ ndk: FilePath) -> FilePath {
    #if os(macOS)
    let host = "darwin-x86_64"
    #else
    let host = "linux-x86_64"
    #endif
    return ndk.appending(
        "toolchains/llvm/prebuilt/\(host)/bin/llvm-readelf")
}

private func skiaTask(
    id: TaskID,
    root: FilePath,
    environment: [String: String],
    buildDirectory: FilePath,
    gnArguments: [String],
    mode: String,
    artifactTarget: ArtifactTarget,
    intelBinaryTranslationPolicy: OCIIntelBinaryTranslationPolicy,
    containerEnvironment: [String: String],
    externalSources: ArtifactReference<DirectoryArtifact>,
    gn: ArtifactReference<ExecutableArtifact>,
    builder: NativeOCIConfiguration
) throws -> CoreColliderRecipe.SkiaBuildArtifacts {
    let skia = root.appending("third-party/skia")
    let containerBuildDirectory = "/build/\(buildDirectory.lastComponent!)"
    let mounts = [
        OCIMount(
            source: skia,
            target: "/src",
            access: .readOnly),
        OCIMount(
            source: root.appending(".skia-build"),
            target: "/build",
            access: .readWrite),
        OCIMount(
            source: builder.ccache,
            target: "/ccache",
            access: .readWrite),
        OCIMount(
            source: builder.swiftSDKRoot,
            target: "/swift-sdk",
            access: .readOnly),
    ]
    func execution(_ command: [String]) -> OCIExecution {
        OCIExecution(
            executionPlatform: .linuxARM64OCI,
            artifactTarget: artifactTarget,
            imageID: builder.imageID,
            hostname: "native-\(mode)-build",
            workingDirectory: "/src",
            hostWorkingDirectory: skia,
            mounts: mounts,
            networkPolicy: .externalDisabled,
            userPolicy: .builder,
            capabilityPolicy: .dropAll,
            privilegePolicy: .prohibitAcquisition,
            processFilesystemPolicy: .standard,
            intelBinaryTranslationPolicy: intelBinaryTranslationPolicy,
            resourceLimits: .parallelBuild,
            containerEnvironment: containerEnvironment.merging(
                ["CCACHE_LOGFILE": "/ccache/ccache.log"],
                uniquingKeysWith: { configured, _ in configured }),
            command: ["skia-\(mode)"] + command,
            environment: builder.environment,
            output: .logged)
    }
    let executions = [
        execution([
            "/src/bin/gn", "gen", containerBuildDirectory,
            "--args=" + gnArguments.joined(separator: " "),
        ]),
        execution(
            ["ninja", "-C", containerBuildDirectory] + ninjaTargets),
    ]
    var task = TaskBuilder(
        id: id,
        component: ComponentID(rawValue: "core"))
    task.consume(externalSources)
    task.consume(gn)
    task.consume(builder.image)
    task.consume(builder.swiftSDK)
    let directory: ArtifactReference<DirectoryArtifact> = try task.output(
        "build-directory",
        path: buildDirectory,
        validation: .nonEmptyDirectory)
    let icuLibrary: ArtifactReference<FileArtifact> = try task.output(
        "libicu.a",
        path: buildDirectory.appending("libicu.a"),
        validation: .regularFile)
    for archive in requiredArchives where archive != "libicu.a" {
        let _: ArtifactReference<FileArtifact> = try task.output(
            OutputSlotID(rawValue: archive),
            path: buildDirectory.appending(archive),
            validation: .regularFile)
    }
    let declaration = task.build(
        inputs: [
            .value(
                name: "gn-arguments",
                bytes: Array(gnArguments.joined(separator: "\u{0}").utf8))
        ],
        locks: [.checkout(id.rawValue)],
        action:
            try AnyColliderAction(
                RunSkiaBuildAction(executions: executions))
    )
    return CoreColliderRecipe.SkiaBuildArtifacts(
        task: declaration,
        buildDirectory: directory,
        icuLibrary: icuLibrary)
}

private struct RunSkiaBuildAction: ColliderAction {
    static let kind: ActionKind = "core.build-skia"

    let pipeline: OCIExecutionPipeline

    init(executions: [OCIExecution]) throws {
        pipeline = try OCIExecutionPipeline(executions)
    }

    var identity: OCIExecutionPipelineIdentity { pipeline.identity }

    var requirements: ActionRequirements { pipeline.requirements }

    var environment: [String: String] { pipeline.environment }

    func execute(in context: ActionContext) async throws {
        try await pipeline.execute(in: context)
    }
}
