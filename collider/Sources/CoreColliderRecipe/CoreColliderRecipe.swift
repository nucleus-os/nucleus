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
        package let skiaExternalSources: ArtifactReference
        package let linuxICULibraries: [NativeLinuxTarget: ArtifactReference]
        package let nativeSDKs: [NativeLinuxTarget: ArtifactReferenceSet]
    }

    package struct SkiaSourceArtifacts: Sendable {
        package let tasks: [TaskDeclaration]
        package let externalSources: ArtifactReference
        package let gn: ExecutableReference
    }

    package struct SkiaBuildArtifacts: Sendable {
        package let task: TaskDeclaration
        package let buildDirectory: ArtifactReference
        package let icuLibrary: ArtifactReference
    }

    package struct NativeSDKArtifacts: Sendable {
        package let task: TaskDeclaration
        package let outputs: ArtifactReferenceSet
    }

    package struct AndroidHostArtifacts: Sendable {
        package let task: TaskDeclaration
        package let library: ArtifactReference
        package let swiftJavaLibrary: ArtifactReference
        package let generatedJava: ArtifactReference
    }

    package struct AndroidHostValidationArtifacts: Sendable {
        package let task: TaskDeclaration
        package let ordering: TaskOrderingReference
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
        let native = try context.configuration(
            NativeBuilderGraphConfiguration.self,
            for: NativeBuilderColliderRecipe.descriptor.id)
        let root = context.componentRoot(descriptor)
        let skiaInputRoot = context.cacheRoot.appending("inputs/skia")
        let sources = try prepareSkiaDependencies(
            root: root,
            downloadRoot: skiaInputRoot,
            environment: context.environment,
            builder: native.builder.base)
        var tasks = sources.tasks
        var roots: Set<TaskID> = []
        var linuxICULibraries: [NativeLinuxTarget: ArtifactReference] = [:]
        var nativeSDKs: [NativeLinuxTarget: ArtifactReferenceSet] = [:]
        for architecture in PlatformArchitecture.allCases {
            let target = NativeLinuxTarget(architecture: architecture)
            let sdkRoot = native.nativeSDK(for: target)
            let skia = try buildSkiaLinux(
                root: root,
                sdkRoot: sdkRoot,
                environment: context.environment,
                target: target,
                sources: sources,
                builder: native.builder)
            let sdk = try publishLinuxRenderSDK(
                root: root,
                sdkRoot: sdkRoot,
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
            fallbackHome: context.cacheRoot.appending("unconfigured-home"))
        let androidSDKRoot = native.nativeSDKRoot.appending("android-arm64")
        let androidSkia = try buildSkiaAndroid(
            root: root,
            sdkRoot: androidSDKRoot,
            minimumAndroidAPI: androidToolchain.minimumSDK,
            environment: context.environment,
            sources: sources,
            builder: native.builder)
        let androidNativeSDK = try publishAndroidRenderSDK(
            root: root,
            sdkRoot: androidSDKRoot,
            skia: androidSkia.buildDirectory)
        let androidSwiftPM = try context.swiftPM(
            .androidARM64(apiLevel: androidToolchain.minimumSDK))
        let androidHost = try buildAndroidHost(
            root: root,
            environment: context.environment,
            swiftPM: androidSwiftPM,
            nativeSDK: androidNativeSDK.outputs)
        let androidValidation = try validateAndroidHost(
            root: root,
            library: androidHost.library,
            ndk: ndk,
            environment: context.environment)
        let androidBuild = try buildAndroidProject(
            root: root,
            environment: context.environment,
            validation: androidValidation.ordering,
            host: androidHost,
            ndk: ndk)
        tasks += [
            androidSkia.task, androidNativeSDK.task, androidHost.task,
            androidValidation.task, androidBuild,
        ]
        func producers(_ matches: (String) -> Bool) -> Set<StorageProducer> {
            Set(tasks.compactMap { matches($0.id.rawValue) ? .task($0.id) : nil })
        }
        var storage: [StorageDeclaration] = [
            StorageDeclaration(
                id: "core-skia-source-materialization",
                owner: descriptor.id,
                producers: producers {
                    $0 == CoreTaskIDs.sources.rawValue
                        || $0 == CoreTaskIDs.gnInstall.rawValue
                },
                storageClass: .source,
                root: root.appending("third-party/skia"),
                safetyRoot: root,
                retentionPolicy: .protected),
            StorageDeclaration(
                id: "core-android-project",
                owner: descriptor.id,
                producers: producers { $0 == "core.android.build" },
                storageClass: .source,
                root: root.appending("android"),
                safetyRoot: root,
                retentionPolicy: .protected),
            StorageDeclaration(
                id: "core-skia-inputs",
                owner: descriptor.id,
                producers: producers {
                    $0 == CoreTaskIDs.gnDownload.rawValue
                        || $0 == CoreTaskIDs.gnInstall.rawValue
                },
                storageClass: .cache,
                root: skiaInputRoot,
                safetyRoot: skiaInputRoot.removingLastComponent(),
                retentionPolicy: .singleWorkingSet),
        ]
        for architecture in PlatformArchitecture.allCases {
            let target = NativeLinuxTarget(architecture: architecture)
            let sdkRoot = native.nativeSDK(for: target)
            storage.append(
                StorageDeclaration(
                    id: "core-render-sdk-\(target.identifier)",
                    owner: descriptor.id,
                    producers: producers {
                        $0 == CoreTaskIDs.skia(target).rawValue
                            || $0 == CoreTaskIDs.nativeSDK(target).rawValue
                    },
                    storageClass: .published,
                    root: sdkRoot.appending("render"),
                    safetyRoot: sdkRoot,
                    retentionPolicy: .singleWorkingSet))
        }
        storage.append(
            StorageDeclaration(
                id: "core-render-sdk-android-arm64",
                owner: descriptor.id,
                producers: [
                    .task(CoreTaskIDs.androidSkia),
                    .task(CoreTaskIDs.androidNativeSDK),
                ],
                storageClass: .published,
                root: androidSDKRoot.appending("render"),
                safetyRoot: androidSDKRoot,
                retentionPolicy: .singleWorkingSet))
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
                    roots: [androidBuild.id]),
            ],
            storage: storage)
        return ComponentArtifacts(
            component: component,
            skiaExternalSources: sources.externalSources,
            linuxICULibraries: linuxICULibraries,
            nativeSDKs: nativeSDKs)
    }

    package static func prepareSkiaDependencies(
        root: FilePath,
        downloadRoot: FilePath,
        environment: [String: String],
        builder: NativeOCIBaseConfiguration
    ) throws -> SkiaSourceArtifacts {
        let skia = root.appending("third-party/skia")
        let gnArchive = downloadRoot.appending("gn-linux-arm64.zip")
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
        let archive: ArtifactReference = try downloadBuilder.output(
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
        let externalSources: ArtifactReference = try sourceBuilder.output(
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
        installBuilder.consume(builder.image)
        // GN is a build tool the checkout happens to name a location for, not
        // source. Installing it into the tree would have a build write the
        // source it is reading, which the executing identity is denied and
        // which no build may do.
        let gnExecutable = downloadRoot.appending("bin/gn")
        let gn: ExecutableReference = try installBuilder.executableOutput(
            "gn",
            path: gnExecutable)
        let install = installBuilder.build(
            locks: [.checkout("core-sources")],
            action:
                try AnyColliderAction(
                    InstallSkiaGNAction(
                        archive: gnArchive,
                        executable: gnExecutable,
                        builder: builder)))
        return SkiaSourceArtifacts(
            tasks: [download, sources, install],
            externalSources: externalSources,
            gn: gn)
    }

    package static func skiaGitDependencies(
        from deps: FilePath
    ) throws -> [SkiaGitDependency] {
        let source = try String(
            contentsOf: URL(fileURLWithPath: deps.string),
            encoding: .utf8)
        let expression =
            #/(?m)^  ["']([^"']+)["']\s*:\s*["'](https://[^"']+)@([0-9a-f]{40})["']\s*,?\s*$/#
        var paths: Set<String> = []
        let dependencies = source.matches(of: expression).map { match in
            return SkiaGitDependency(
                relativePath: String(match.1),
                remote: String(match.2),
                commit: String(match.3))
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
        sdkRoot: FilePath,
        environment: [String: String],
        target: NativeLinuxTarget,
        sources: SkiaSourceArtifacts,
        builder: NativeOCIConfiguration
    ) throws -> SkiaBuildArtifacts {
        try skiaTask(
            id: CoreTaskIDs.skia(target),
            root: root,
            environment: environment,
            exportDirectory: sdkRoot.appending("render/lib/skia-graphite"),
            gnArguments: linuxGNArguments(target),
            mode: "linux",
            artifactTarget: target.artifactTarget,
            containerEnvironment: targetEnvironment(target),
            externalSources: sources.externalSources,
            gn: sources.gn,
            builder: builder)
    }

    package static func buildSkiaAndroid(
        root: FilePath,
        sdkRoot: FilePath,
        minimumAndroidAPI: UInt32,
        environment: [String: String],
        sources: SkiaSourceArtifacts,
        builder: NativeOCIConfiguration
    ) throws -> SkiaBuildArtifacts {
        let ndk = "/opt/android-ndk-r30-beta2"
        let target = "aarch64-linux-android\(minimumAndroidAPI)"
        let sysroot = "\(ndk)/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
        return try skiaTask(
            id: CoreTaskIDs.androidSkia,
            root: root,
            environment: environment,
            exportDirectory: sdkRoot.appending("render/lib/skia-graphite"),
            gnArguments: [
                #"target_os="android""#,
                #"target_cpu="arm64""#,
                #"ndk="\#(ndk)""#,
                "ndk_api=\(minimumAndroidAPI)",
                #"target_ar="/usr/bin/llvm-ar""#,
                #"target_cc="/usr/bin/clang --target=\#(target) --sysroot=\#(sysroot) -fno-addrsig""#,
                #"target_cxx="/usr/bin/clang++ --target=\#(target) --sysroot=\#(sysroot) -fno-addrsig""#,
                "skia_use_fontconfig=false",
            ] + commonGNArguments,
            mode: "android",
            artifactTarget: .androidARM64(apiLevel: minimumAndroidAPI),
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
        let product = swiftPM.productsDirectory.appending(
            "libnucleus-android.so")
        let swiftJavaProduct = swiftPM.productsDirectory.appending(
            "libSwiftJava.so")
        let generatedJava = swiftPM.scratchPath.appending(
            "plugins/outputs/nucleus/NucleusAndroidJNI/destination/"
                + "JExtractSwiftPlugin/src/generated/java")
        var builder = TaskBuilder(
            id: CoreTaskIDs.androidHostBuild,
            component: ComponentID(rawValue: "core"))
        builder.consume(nativeSDK)
        let library: ArtifactReference = try builder.output(
            "android-library",
            path: product,
            validation: .regularFile)
        let swiftJavaLibrary: ArtifactReference = try builder.output(
            "swift-java-library",
            path: swiftJavaProduct,
            validation: .regularFile)
        let generatedJavaArtifact: ArtifactReference =
            try builder.output(
                "generated-java",
                path: generatedJava,
                validation: .nonEmptyDirectory)
        let task = builder.build(
            swiftProducts: [
                swiftPM.product(
                    package: "platform-android",
                    product: "nucleus-android",
                    packageRoot: package,
                    environment: environment,
                    expectedOutputs: [
                        PathPostcondition(
                            path: product,
                            validation: .regularFile),
                        PathPostcondition(
                            path: swiftJavaProduct,
                            validation: .regularFile),
                        PathPostcondition(
                            path: generatedJava,
                            validation: .nonEmptyDirectory),
                    ])
            ],
            inputs: [
                .sourceCheckout(package.appending("c")),
                .sourceCheckout(package.appending("swift-core")),
                .sourceCheckout(package.appending("swift-jni")),
                swiftPM.identityInput,
            ],
            postconditions: [
                swiftPM.postcondition,
                PathPostcondition(
                    path: product,
                    validation: .regularFile),
                PathPostcondition(
                    path: swiftJavaProduct,
                    validation: .regularFile),
                PathPostcondition(
                    path: generatedJava,
                    validation: .nonEmptyDirectory),
            ],
            locks: [.checkout("core-android-host")])
        return AndroidHostArtifacts(
            task: task,
            library: library,
            swiftJavaLibrary: swiftJavaLibrary,
            generatedJava: generatedJavaArtifact)
    }

    package static func validateAndroidHost(
        root: FilePath,
        library: ArtifactReference,
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
        let ordering = builder.ordering
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
        return AndroidHostValidationArtifacts(task: task, ordering: ordering)
    }

    package static func buildAndroidProject(
        root: FilePath,
        environment: [String: String],
        validation: TaskOrderingReference,
        host: AndroidHostArtifacts,
        ndk: FilePath
    ) throws -> TaskDeclaration {
        let android = root.appending("android")
        var builder = TaskBuilder(
            id: CoreTaskIDs.androidBuild,
            component: descriptor.id)
        builder.after(validation)
        builder.consume(host.library)
        builder.consume(host.swiftJavaLibrary)
        builder.consume(host.generatedJava)
        return builder.build(
            inputs: [
                .file(android.appending("settings.gradle.kts")),
                .file(android.appending("build.gradle.kts")),
                .file(android.appending("gradle/libs.versions.toml")),
                .sourceCheckout(android.appending("nucleus/src")),
                .sourceCheckout(android.appending("smoke-app/src")),
                .tool(.path(android.appending("gradlew"))),
            ],
            locks: [.checkout("core-android-gradle")],
            assessmentPolicy: .always,
            action:
                try AnyColliderAction(
                    VerifyAndroidProjectAction(
                        project: android,
                        ndk: ndk,
                        nucleusLibrary: host.library.path,
                        swiftJavaLibrary: host.swiftJavaLibrary.path,
                        generatedJava: host.generatedJava.path,
                        environment: environment)))
    }

    package static func publishAndroidRenderSDK(
        root: FilePath,
        sdkRoot: FilePath,
        skia: ArtifactReference
    ) throws -> NativeSDKArtifacts {
        let sdk = sdkRoot.appending("render")
        let links: [(String, FilePath)] = [
            ("include/skia", root.appending("third-party/skia")),
            ("include/skia-text", root.appending("render-cxx/skia")),
        ]
        var builder = TaskBuilder(
            id: CoreTaskIDs.androidNativeSDK,
            component: ComponentID(rawValue: "core"))
        builder.consume(skia)
        var outputs = ArtifactReferenceSet(skia)
        for (name, _) in links {
            let output: ArtifactReference = try builder.output(
                OutputSlotID(rawValue: name),
                path: sdk.appending(name),
                validation: .symlinkTarget)
            outputs.append(output)
        }
        let task = builder.build(
            inputs: links.map {
                .string(
                    name: $0.0,
                    value: $0.1.string)
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
        skia: ArtifactReference
    ) throws -> NativeSDKArtifacts {
        let sdk = sdkRoot.appending("render")
        let links: [(String, FilePath)] = [
            ("include/skia", root.appending("third-party/skia")),
            ("include/skia-text", root.appending("render-cxx/skia")),
        ]
        var builder = TaskBuilder(
            id: CoreTaskIDs.nativeSDK(target),
            component: ComponentID(rawValue: "core"))
        builder.consume(skia)
        var outputs = ArtifactReferenceSet(skia)
        for (name, _) in links {
            let output: ArtifactReference = try builder.output(
                OutputSlotID(rawValue: name),
                path: sdk.appending(name),
                validation: .symlinkTarget)
            outputs.append(output)
        }
        let task = builder.build(
            inputs: links.map {
                .string(name: $0.0, value: $0.1.string)
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

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: library)
            encoder.append(path: kotlinContract)
            encoder.append(path: readelf)
            encoder.append(UInt64(minimumSwiftJavaThunkCount))
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
            guard result.succeeded else {
                throw result.executionFailure(reason: "Android host validation failed")
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
        let functions = source.matches(of: /external\s+fun\s+([A-Za-z0-9_]+)/)
            .map { String($0.1) }
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
            ],
            networkAccess: .contentAddressed,
            executionPlatform: .macOSARM64Native)
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

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: sdk)
            encoder.appendSequence(links) { linkEncoder, link in
                linkEncoder.append(link.name)
                linkEncoder.append(path: link.target)
            }
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
        let ndk: FilePath
        let nucleusLibrary: FilePath
        let swiftJavaLibrary: FilePath
        let generatedJava: FilePath

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: project)
            encoder.append("verifyDebug")
            encoder.append(path: ndk)
            encoder.append(path: nucleusLibrary)
            encoder.append(path: swiftJavaLibrary)
            encoder.append(path: generatedJava)
        }
    }

    static let kind: ActionKind = "core.verify-android-project"

    let project: FilePath
    let ndk: FilePath
    let nucleusLibrary: FilePath
    let swiftJavaLibrary: FilePath
    let generatedJava: FilePath
    let environment: [String: String]

    var identity: Identity {
        Identity(
            project: project,
            ndk: ndk,
            nucleusLibrary: nucleusLibrary,
            swiftJavaLibrary: swiftJavaLibrary,
            generatedJava: generatedJava)
    }

    var requirements: ActionRequirements {
        ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "gradle-wrapper",
                    executable: .path(project.appending("gradlew")),
                    role: .semantic)
            ],
            effects: [
                ActionEffect(.readWrite, scope: .checkout(project)),
                ActionEffect(.read, scope: .input(nucleusLibrary)),
                ActionEffect(.read, scope: .input(swiftJavaLibrary)),
                ActionEffect(.read, scope: .input(generatedJava)),
            ],
            executionPlatform: .macOSARM64Native)
    }

    func execute(in context: ActionContext) async throws {
        let result = try await context.commands.execute(
            CommandSpec(
                executable: .path(project.appending("gradlew")),
                arguments: [
                    "verifyDebug",
                    "-Pnucleus.androidNdk=\(ndk.string)",
                    "-Pnucleus.nativeLibrary=\(nucleusLibrary.string)",
                    "-Pnucleus.swiftJavaLibrary=\(swiftJavaLibrary.string)",
                    "-Pnucleus.generatedJava=\(generatedJava.string)",
                    "-Pnucleus.cxxRuntime=\(androidNDKCxxRuntimePath(ndk).string)",
                ],
                workingDirectory: project,
                environment: environment))
        guard result.succeeded else {
            throw result.executionFailure(reason: "Android project verification failed")
        }
    }
}

package struct SkiaGitDependency: Hashable, Sendable {
    package let relativePath: String
    package let remote: String
    package let commit: String

    package init(relativePath: String, remote: String, commit: String) {
        self.relativePath = relativePath
        self.remote = remote
        self.commit = commit
    }
}

package struct MaterializeSkiaDependenciesAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        let skia: FilePath
        let dependencies: [SkiaGitDependency]

        package func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: skia)
            encoder.appendSequence(dependencies) { dependencyEncoder, dependency in
                dependencyEncoder.append(dependency.relativePath)
                dependencyEncoder.append(dependency.remote)
                dependencyEncoder.append(dependency.commit)
            }
        }
    }

    package static let kind: ActionKind = "core.materialize-skia-dependencies"

    package let skia: FilePath
    package let dependencies: [SkiaGitDependency]
    package let environment: [String: String]

    package init(
        skia: FilePath,
        dependencies: [SkiaGitDependency],
        environment: [String: String]
    ) {
        self.skia = skia
        self.dependencies = dependencies
        self.environment = environment
    }

    package var identity: Identity {
        Identity(skia: skia, dependencies: dependencies)
    }

    package var requirements: ActionRequirements {
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

    package func execute(in context: ActionContext) async throws {
        let disabled = skia.appending("sync-deps.disable")
        guard try context.files.metadata(for: disabled) == nil else {
            throw SkiaDependencyFailure.disabled(disabled)
        }
        let concurrencyLimit = 8
        for start in stride(from: 0, to: dependencies.count, by: concurrencyLimit) {
            let end = min(start + concurrencyLimit, dependencies.count)
            let batch = dependencies[start..<end]
            try await withThrowingTaskGroup(of: Void.self) { group in
                for dependency in batch {
                    group.addTask {
                        try await materialize(dependency, context: context)
                    }
                }
                try await group.waitForAll()
            }
        }
    }

    private func materialize(
        _ dependency: SkiaGitDependency,
        context: ActionContext
    ) async throws {
        try context.cancellation.check()
        let checkout = skia.appending(dependency.relativePath)
        if try await checkoutIsExact(dependency, at: checkout, context: context) {
            return
        }

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
            let origin = try await git(
                ["-C", checkout.string, "remote", "get-url", "origin"],
                workingDirectory: skia,
                context: context)
            let operation = origin.succeeded ? "set-url" : "add"
            try await requireSuccess(
                [
                    "-C", checkout.string, "remote", operation, "origin",
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
        guard try await checkoutIsExact(dependency, at: checkout, context: context)
        else {
            let resolved = try await git(
                ["-C", checkout.string, "rev-parse", "HEAD"],
                workingDirectory: skia,
                context: context)
            throw SkiaDependencyFailure.wrongCommit(
                dependency.relativePath,
                expected: dependency.commit,
                actual: resolved.standardOutput)
        }
    }

    private func checkoutIsExact(
        _ dependency: SkiaGitDependency,
        at checkout: FilePath,
        context: ActionContext
    ) async throws -> Bool {
        guard try context.files.metadata(for: checkout.appending(".git")) != nil else {
            return false
        }
        async let origin = git(
            ["-C", checkout.string, "remote", "get-url", "origin"],
            workingDirectory: skia,
            context: context)
        async let head = git(
            ["-C", checkout.string, "rev-parse", "HEAD"],
            workingDirectory: skia,
            context: context)
        async let expected = git(
            ["-C", checkout.string, "rev-parse", "\(dependency.commit)^{commit}"],
            workingDirectory: skia,
            context: context)
        async let status = git(
            [
                "-C", checkout.string, "status", "--porcelain",
                "--untracked-files=no",
            ],
            workingDirectory: skia,
            context: context)
        let (resolvedOrigin, resolvedHead, resolvedExpected, resolvedStatus) = try await (
            origin, head, expected, status
        )
        guard resolvedStatus.succeeded else {
            throw SkiaDependencyFailure.invalidCheckout(dependency.relativePath)
        }
        guard resolvedStatus.standardOutput.isEmpty else {
            throw SkiaDependencyFailure.trackedModifications(dependency.relativePath)
        }
        return resolvedOrigin.succeeded && resolvedHead.succeeded
            && resolvedExpected.succeeded
            && resolvedOrigin.standardOutput.trimmingCharacters(
                in: .whitespacesAndNewlines) == dependency.remote
            && resolvedHead.standardOutput.trimmingCharacters(
                in: .whitespacesAndNewlines)
                == resolvedExpected.standardOutput.trimmingCharacters(
                    in: .whitespacesAndNewlines)
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
        guard result.succeeded else {
            throw result.executionFailure(reason: "Skia dependency git command failed")
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
        let execution: OCIExecution
        let executable: FilePath

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(nested: OCIExecutionActionIdentity(execution))
            encoder.append(path: executable)
        }
    }

    static let kind: ActionKind = "core.install-skia-gn"

    let execution: OCIExecution
    let executable: FilePath

    init(
        archive: FilePath,
        executable: FilePath,
        builder: NativeOCIBaseConfiguration
    ) {
        self.executable = executable
        execution = OCIExecution(
            executionPlatform: .linuxARM64OCI,
            artifactTarget: .linuxARM64,
            imageID: builder.imageID,
            hostname: "native-gn-extract",
            workingDirectory: "/output",
            hostWorkingDirectory: executable.removingLastComponent(),
            mounts: [
                OCIMount(
                    source: archive.removingLastComponent(),
                    target: "/archive",
                    access: .readOnly),
                OCIMount(
                    boundedExport: executable.removingLastComponent(),
                    target: "/output"),
            ],
            userPolicy: .builder,
            capabilityPolicy: .dropAll,
            privilegePolicy: .prohibitAcquisition,
            processFilesystemPolicy: .standard,
            resourceLimits: OCIResourceLimits(
                cpuCount: 1,
                memoryBytes: 1 * 1_024 * 1_024 * 1_024,
                processCount: 64),
            containerEnvironment: [:],
            command: ["extract-gn"],
            environment: builder.environment,
            output: .logged)
    }

    var identity: Identity {
        Identity(execution: execution, executable: executable)
    }

    var requirements: ActionRequirements {
        ociActionRequirements(execution: execution)
    }

    var environment: [String: String] { execution.environment }

    func execute(in context: ActionContext) async throws {
        try context.files.createDirectory(executable.removingLastComponent())
        let result = try await context.containers.execute(execution)
        guard result.succeeded else {
            throw result.executionFailure(reason: "Skia dependency extraction failed")
        }
    }
}

private enum SkiaDependencyFailure: Error {
    case noGitDependencies(FilePath)
    case invalidCheckout(String)
    case disabled(FilePath)
    case trackedModifications(String)
    case wrongCommit(String, expected: String, actual: String)
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
        #"extra_cflags_cc=["--target=\#(target.targetTriple)","--sysroot=\#(sysroot)","-stdlib=libc++","-nostdinc++","-isystem\#(target.containerLibCXXIncludeRoot)","-idirafter/usr/include","-idirafter/usr/include/\#(target.gnuArchitecture)"]"#,
        #"extra_asmflags=["--target=\#(target.targetTriple)","--sysroot=\#(sysroot)"]"#,
        #"extra_ldflags=["--target=\#(target.targetTriple)","--sysroot=\#(sysroot)","-stdlib=libc++","-fuse-ld=lld","-L\#(target.containerLibCXXLibraryRoot)"]"#,
        #"cc="/usr/bin/clang""#,
        #"cxx="/usr/bin/clang++""#,
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

private func androidNDKCxxRuntimePath(_ ndk: FilePath) -> FilePath {
    #if os(macOS)
    let host = "darwin-x86_64"
    #else
    let host = "linux-x86_64"
    #endif
    return ndk.appending(
        "toolchains/llvm/prebuilt/\(host)/sysroot/usr/lib/"
            + "aarch64-linux-android/libc++_shared.so")
}

private func skiaTask(
    id: TaskID,
    root: FilePath,
    environment: [String: String],
    exportDirectory: FilePath,
    gnArguments: [String],
    mode: String,
    artifactTarget: ArtifactTarget,
    containerEnvironment: [String: String],
    externalSources: ArtifactReference,
    gn: ExecutableReference,
    builder: NativeOCIConfiguration
) throws -> CoreColliderRecipe.SkiaBuildArtifacts {
    let skia = root.appending("third-party/skia")
    let containerBuildDirectory = "/build"
    let buildWorkspace = PersistentWorkspaceDeclaration(
        identity: PersistentWorkspaceIdentity(
            key: "core-skia-intermediates",
            artifactTarget: artifactTarget,
            role: "build"),
        capacityBytes: 100 * 1_024 * 1_024 * 1_024,
        filesystem: .ext4,
        journal: .writeback64MiB)
    let compilerCacheWorkspace = PersistentWorkspaceDeclaration(
        identity: PersistentWorkspaceIdentity(
            key: "core-skia-ccache",
            artifactTarget: artifactTarget,
            role: "compiler-cache"),
        capacityBytes: 50 * 1_024 * 1_024 * 1_024,
        filesystem: .ext4,
        journal: .writeback64MiB,
        retentionPolicy: .toolManagedLimit(maximumBytes: 50 * 1_024 * 1_024 * 1_024))
    let mounts = [
        OCIMount(
            source: skia,
            target: "/src",
            access: .readOnly),
        OCIMount(
            boundedExport: exportDirectory,
            target: "/export"),
        OCIMount(
            source: builder.swiftSDKRoot,
            target: "/swift-sdk",
            access: .readOnly),
        // GN is mounted from the storage it was installed into, rather than
        // read out of the read-only source mount it used to be written into.
        OCIMount(
            source: gn.path.removingLastComponent(),
            target: "/gn",
            access: .readOnly),
    ]
    let persistentWorkspaceMounts = [
        OCIPersistentWorkspaceMount(
            workspace: buildWorkspace,
            target: containerBuildDirectory,
            access: .readWrite),
        OCIPersistentWorkspaceMount(
            workspace: compilerCacheWorkspace,
            target: "/ccache",
            access: .readWrite),
    ]
    func execution(
        _ command: [String],
        entrypointMode: String = "skia-\(mode)"
    ) -> OCIExecution {
        OCIExecution(
            executionPlatform: .linuxARM64OCI,
            artifactTarget: artifactTarget,
            imageID: builder.imageID,
            hostname: "native-\(mode)-build",
            workingDirectory: "/src",
            hostWorkingDirectory: skia,
            mounts: mounts,
            persistentWorkspaceMounts: persistentWorkspaceMounts,
            userPolicy: .builder,
            capabilityPolicy: .dropAll,
            privilegePolicy: .prohibitAcquisition,
            processFilesystemPolicy: .standard,
            resourceLimits: .parallelBuild,
            containerEnvironment: containerEnvironment.merging(
                ["CCACHE_LOGFILE": "/ccache/ccache.log"],
                uniquingKeysWith: { configured, _ in configured }),
            command: [entrypointMode] + command,
            environment: builder.environment,
            output: .logged)
    }
    let executions = [
        execution([
            "/gn/gn", "gen", containerBuildDirectory,
            "--args=" + gnArguments.joined(separator: " "),
        ]),
        execution(
            ["ninja", "-C", containerBuildDirectory] + ninjaTargets),
        execution(requiredArchives, entrypointMode: "skia-export"),
    ]
    var task = TaskBuilder(
        id: id,
        component: ComponentID(rawValue: "core"))
    task.consume(externalSources)
    task.consume(gn)
    task.consume(builder.image)
    task.consume(builder.swiftSDK)
    let directory: ArtifactReference = try task.output(
        "archives",
        path: exportDirectory,
        validation: .nonEmptyDirectory)
    let icuLibrary: ArtifactReference = try task.output(
        "libicu.a",
        path: exportDirectory.appending("libicu.a"),
        validation: .regularFile)
    for archive in requiredArchives where archive != "libicu.a" {
        let _: ArtifactReference = try task.output(
            OutputSlotID(rawValue: archive),
            path: exportDirectory.appending(archive),
            validation: .regularFile)
    }
    let declaration = task.build(
        inputs: [
            .string(
                name: "gn-arguments",
                value: gnArguments.joined(separator: "\u{0}"))
        ],
        locks: [.checkout(id.rawValue)],
        action:
            try AnyColliderAction(
                RunSkiaBuildAction(
                    executions: executions,
                    exportDirectory: exportDirectory))
    )
    return CoreColliderRecipe.SkiaBuildArtifacts(
        task: declaration,
        buildDirectory: directory,
        icuLibrary: icuLibrary)
}

private struct RunSkiaBuildAction: ColliderAction {
    static let kind: ActionKind = "core.build-skia"

    let pipeline: OCIExecutionPipeline
    let exportDirectory: FilePath

    init(executions: [OCIExecution], exportDirectory: FilePath) throws {
        pipeline = try OCIExecutionPipeline(executions)
        self.exportDirectory = exportDirectory
    }

    var identity: OCIExecutionPipelineIdentity { pipeline.identity }

    var requirements: ActionRequirements { pipeline.requirements }

    var environment: [String: String] { pipeline.environment }

    func execute(in context: ActionContext) async throws {
        if let metadata = try context.files.metadataWithoutFollowingSymlinks(
            for: exportDirectory),
            metadata.type != .directory
        {
            try context.files.remove(exportDirectory)
        }
        try context.files.createDirectory(exportDirectory)
        try await pipeline.execute(in: context)
    }
}
