import ColliderCore
import Foundation
import NativeBuilderColliderRecipe
import SystemPackage

package enum ReactNativeTaskIDs {
    package static func nativeSDK(_ target: NativeLinuxTarget) -> TaskID {
        TaskID(rawValue: "rn.native-sdk.\(target.identifier)")
    }
}

package struct BoostArtifacts: Sendable {
    package let tasks: [TaskDeclaration]
    package let active: ArtifactReference<PathArtifact>
}

package struct JavaScriptDependencyArtifacts: Sendable {
    package let task: TaskDeclaration
    package let nodeModules: ArtifactReference<DirectoryArtifact>
}

package struct HermesArtifacts: Sendable {
    package let task: TaskDeclaration
    package let libraries: [ArtifactReference<FileArtifact>]
    package let compiler: ArtifactReference<ExecutableArtifact>
}

package struct SupportLibraryArtifacts: Sendable {
    package let task: TaskDeclaration
    package let libraries: [ArtifactReference<FileArtifact>]
}

package struct CxxRuntimeArtifacts: Sendable {
    package let task: TaskDeclaration
    package let outputs: [ArtifactReference<FileArtifact>]
}

public enum ReactNativeColliderRecipe {
    package struct Artifacts: Sendable {
        package let nativeSDKs: [NativeLinuxTarget: ArtifactReferenceSet]
    }

    package struct PreparedComponent: Sendable {
        package let component: ComponentDefinition
        package let artifacts: Artifacts
    }

    package struct NativeSDKArtifacts: Sendable {
        package let task: TaskDeclaration
        package let outputs: ArtifactReferenceSet
    }

    public static let descriptor = ComponentDescriptor(
        id: ComponentID(rawValue: "rn"),
        canonicalName: "react-native",
        directoryName: "react-native",
        aliases: ["rn"])

    package static func prepare(
        in context: RecipeContext,
        skiaExternalSources: ArtifactReference<DirectoryArtifact>,
        icuLibraries: [NativeLinuxTarget: ArtifactReference<FileArtifact>]
    ) throws -> PreparedComponent {
        let native = try context.configuration(
            NativeBuilderGraphConfiguration.self,
            for: NativeBuilderColliderRecipe.descriptor.id)
        let root = context.componentRoot(descriptor)
        let javascript = try installJavaScriptDependencies(
            root: root,
            cacheRoot: context.cacheRoot,
            environment: context.environment)
        let boost = try provisionBoost(
            root: root,
            environment: context.environment)
        var tasks = [javascript.task] + boost.tasks
        var bootstrapRoots: Set<TaskID> = []
        var nativeSDKs: [NativeLinuxTarget: ArtifactReferenceSet] = [:]
        for architecture in PlatformArchitecture.allCases {
            let target = NativeLinuxTarget(architecture: architecture)
            guard let icuLibrary = icuLibraries[target] else {
                throw ReactNativeRecipeFailure.missingICULibrary(target)
            }
            let hermes = try buildHermes(
                root: root,
                environment: context.environment,
                target: target,
                dependencies: javascript.nodeModules,
                skiaExternalSources: skiaExternalSources,
                icuLibrary: icuLibrary,
                builder: native.builder)
            let support = try buildSupportLibraries(
                root: root,
                environment: context.environment,
                target: target,
                builder: native.builder)
            let cxx = try buildCxxRuntime(
                root: root,
                environment: context.environment,
                target: target,
                dependencies: javascript.nodeModules,
                boost: boost.active,
                hermes: hermes,
                support: support,
                builder: native.builder)
            let sdk = try publishNativeSDK(
                root: root,
                sdkRoot: native.nativeSDK(for: target),
                target: target,
                dependencies: javascript.nodeModules,
                runtime: cxx)
            tasks += [hermes.task, support.task, cxx.task, sdk.task]
            bootstrapRoots.insert(sdk.task.id)
            nativeSDKs[target] = sdk.outputs
        }
        let component = try ComponentDefinition(
            descriptor: descriptor,
            tasks: tasks,
            entrypoints: [
                ComponentEntrypoint(id: .bootstrap, roots: bootstrapRoots)
            ])
        return PreparedComponent(
            component: component,
            artifacts: Artifacts(nativeSDKs: nativeSDKs))
    }

    package static func installJavaScriptDependencies(
        root: FilePath,
        cacheRoot: FilePath,
        environment: [String: String]
    ) throws -> JavaScriptDependencyArtifacts {
        let packageManifest = root.appending("package.json")
        let lockfile = root.appending("bun.lock")
        let active = root.appending("node_modules")
        var task = TaskBuilder(
            id: TaskID(rawValue: "rn.javascript-dependencies"),
            component: ComponentID(rawValue: "rn"))
        let nodeModules: ArtifactReference<DirectoryArtifact> = try task.output(
            "node-modules",
            path: active,
            validation: .nonEmptyDirectory)
        let cache = cacheRoot.appending("nucleus/bun/linux-multiarch")
        let declaration = task.build(
            inputs: [
                .file(lockfile),
                .file(packageManifest),
                .sourceCheckout(root),
            ],
            locks: [
                .checkout("rn-javascript-dependencies"),
                .shared(cache.appending(".collider.lock")),
            ],
            action:
                try AnyColliderAction(
                    InstallReactNativeJavaScriptDependenciesAction(
                        root: root,
                        cache: cache,
                        environment: environment)))
        return JavaScriptDependencyArtifacts(
            task: declaration,
            nodeModules: nodeModules)
    }

    package static func provisionBoost(
        root: FilePath,
        environment: [String: String]
    ) throws -> BoostArtifacts {
        guard let digest = ArtifactDigest(sha256Hex: boostArchiveSHA256),
            let url = URL(
                string:
                    "https://archives.boost.io/release/\(boostVersion)/source/"
                    + boostArchiveName)
        else {
            throw ReactNativeRecipeFailure.invalidBoostSpecification
        }
        let download = try DownloadSpec(
            url: url,
            permittedRedirectOrigins: ["https://archives.boost.io"],
            expectedDigest: digest,
            maximumResponseSize: 200 * 1_024 * 1_024,
            acceptedMediaTypes: [
                "application/gzip",
                "application/octet-stream",
                "application/x-gzip",
            ])
        let archive = root.appending(
            ".rn-build/downloads/\(boostArchiveName)")
        let generations = root.appending(".rn-build/dependencies/boost")
        let candidate = generations.appending(
            ".candidate-\(boostArchiveSHA256)")
        let generation = generations.appending(boostArchiveSHA256)
        let active = generations.appending("current")
        var downloadBuilder = TaskBuilder(
            id: TaskID(rawValue: "rn.boost-download"),
            component: ComponentID(rawValue: "rn"))
        let downloadedArchive: ArtifactReference<FileArtifact> = try downloadBuilder.output(
            "archive",
            path: archive,
            validation: .regularFile)
        let downloadTask = downloadBuilder.build(
            locks: [.checkout("rn-boost")],
            action:
                try AnyColliderAction(
                    DownloadBoostAction(
                        specification: download,
                        destination: archive)))

        var boostBuilder = TaskBuilder(
            id: TaskID(rawValue: "rn.boost"),
            component: ComponentID(rawValue: "rn"))
        boostBuilder.consume(downloadedArchive)
        let _: ArtifactReference<FileArtifact> = try boostBuilder.output(
            "version-header",
            path: generation.appending("version.hpp"),
            validation: .regularFile)
        let activeArtifact: ArtifactReference<PathArtifact> = try boostBuilder.output(
            "active-generation",
            path: active,
            validation: .symlinkTarget)
        let boostTask = boostBuilder.build(
            inputs: [
                .string(
                    name: "boost-version",
                    value: boostVersion),
                .tool(.named("tar")),
            ],
            locks: [.checkout("rn-boost")],
            action:
                try AnyColliderAction(
                    ProvisionBoostAction(
                        archive: archive,
                        candidate: candidate,
                        generation: generation,
                        active: active,
                        workingDirectory: root,
                        environment: environment)))
        return BoostArtifacts(
            tasks: [downloadTask, boostTask],
            active: activeArtifact)
    }

    package static func buildHermes(
        root: FilePath,
        environment: [String: String],
        target: NativeLinuxTarget,
        dependencies: ArtifactReference<DirectoryArtifact>,
        skiaExternalSources: ArtifactReference<DirectoryArtifact>,
        icuLibrary: ArtifactReference<FileArtifact>,
        builder: NativeOCIConfiguration
    ) throws -> HermesArtifacts {
        let source = root.appending("third-party/hermes")
        let reactNativeJSI = root.appending(
            "node_modules/react-native/ReactCommon/jsi")
        let build = root.appending(".rn-build/\(target.identifier)/hermes")
        let combined = build.appending("libhermes_lean_combined.a")
        let hermesc = build.appending("bin/hermesc")
        let icuSource = root.appending(
            "../core/third-party/skia/third_party/externals/icu/source")
        let icuLibraryDirectory = icuLibrary.path.removingLastComponent()
        let cmakeArguments: [String] = []
        let ninjaEnvironment = environment
        var taskBuilder = TaskBuilder(
            id: TaskID(rawValue: "rn.hermes.\(target.identifier)"),
            component: ComponentID(rawValue: "rn"))
        taskBuilder.consume(builder.image)
        taskBuilder.consume(builder.swiftSDK)
        taskBuilder.consume(dependencies)
        taskBuilder.consume(skiaExternalSources)
        taskBuilder.consume(icuLibrary)
        let combinedArtifact: ArtifactReference<FileArtifact> = try taskBuilder.output(
            "combined-library",
            path: combined,
            validation: .regularFile)
        let compilerArtifact: ArtifactReference<ExecutableArtifact> = try taskBuilder.output(
            "compiler",
            path: hermesc,
            validation: .executableFile)
        let task = taskBuilder.build(
            inputs: [
                .sourceCheckout(source),
                .file(root.appending("../tools/merge-static-archives.sh")),
            ],
            locks: [.checkout("rn-native-\(target.identifier)")],
            action:
                try AnyColliderAction(
                    RunReactNativeNativeBuildAction(executions: [
                        try nativeCMake(
                            source: source,
                            containerSource: "/src/hermes",
                            build: build,
                            containerBuild: "/build/hermes",
                            arguments: [
                                "-DBUILD_SHARED_LIBS=OFF",
                                "-DHERMES_BUILD_SHARED_JSI=OFF",
                                "-DHERMES_BUILD_APPLE_FRAMEWORK=OFF",
                                "-DHERMES_ENABLE_DEBUGGER=OFF",
                                "-DHERMES_ENABLE_INTL=ON",
                                "-DJSI_DIR=\(nativePath(reactNativeJSI, "/react-native/ReactCommon/jsi"))",
                                "-DICU_FOUND=ON",
                                "-DICU_INCLUDE_DIRS=/icu/common;/icu/i18n",
                                "-DICU_LIBRARIES=/icu/lib/libicu.a",
                            ] + cmakeArguments,
                            root: root,
                            environment: environment,
                            target: target,
                            builder: builder,
                            compileDefinitions: [
                                "U_DISABLE_RENAMING=1",
                                "U_STATIC_IMPLEMENTATION",
                            ],
                            additionalCXXFlags: [
                                "-I/icu/common",
                                "-I/icu/i18n",
                            ],
                            additionalMounts: [
                                OCIMount(
                                    source: icuSource.appending("common"),
                                    target: "/icu/common",
                                    access: .readOnly),
                                OCIMount(
                                    source: icuSource.appending("i18n"),
                                    target: "/icu/i18n",
                                    access: .readOnly),
                                OCIMount(
                                    source: icuLibraryDirectory,
                                    target: "/icu/lib",
                                    access: .readOnly),
                            ]),
                        try nativeNinja(
                            build: build,
                            containerBuild: "/build/hermes",
                            targets: ["hermesvmlean", "jsi", "hermesc"],
                            root: root,
                            environment: ninjaEnvironment,
                            target: target,
                            builder: builder,
                            additionalMounts: [
                                OCIMount(
                                    source: icuLibraryDirectory,
                                    target: "/icu/lib",
                                    access: .readOnly)
                            ]),
                        try nativeContainerOperation(
                            root: root,
                            builder: builder,
                            command: [
                                "/tools/merge-static-archives.sh",
                                "/build/hermes",
                                "/build/hermes/libhermes_lean_combined.a",
                                "libgtest",
                            ],
                            environment: environment,
                            target: target),
                    ]))
        )
        return HermesArtifacts(
            task: task,
            libraries: [combinedArtifact],
            compiler: compilerArtifact)
    }

    package static func buildSupportLibraries(
        root: FilePath,
        environment: [String: String],
        target: NativeLinuxTarget,
        builder: NativeOCIConfiguration
    ) throws -> SupportLibraryArtifacts {
        let buildRoot = root.appending(".rn-build/\(target.identifier)")
        let fmtBuild = buildRoot.appending("fmt")
        let conversionBuild = buildRoot.appending("double-conversion")
        var taskBuilder = TaskBuilder(
            id: TaskID(rawValue: "rn.support.\(target.identifier)"),
            component: ComponentID(rawValue: "rn"))
        taskBuilder.consume(builder.image)
        taskBuilder.consume(builder.swiftSDK)
        let fmt: ArtifactReference<FileArtifact> = try taskBuilder.output(
            "fmt-library",
            path: fmtBuild.appending("libfmt.a"),
            validation: .regularFile)
        let conversion: ArtifactReference<FileArtifact> = try taskBuilder.output(
            "double-conversion-library",
            path: conversionBuild.appending("src/libdouble-conversion.a"),
            validation: .regularFile)
        let task = taskBuilder.build(
            inputs: [
                .sourceCheckout(root.appending("third-party/fmt")),
                .sourceCheckout(
                    root.appending(
                        "third-party/double-conversion")),
            ],
            locks: [.checkout("rn-native-\(target.identifier)")],
            action:
                try AnyColliderAction(
                    RunReactNativeNativeBuildAction(executions: [
                        try nativeCMake(
                            source: root.appending("third-party/fmt"),
                            containerSource: "/src/fmt",
                            build: fmtBuild,
                            containerBuild: "/build/fmt",
                            arguments: [
                                "-DFMT_TEST=OFF", "-DFMT_DOC=OFF", "-DFMT_INSTALL=OFF",
                            ],
                            root: root,
                            environment: environment,
                            target: target,
                            builder: builder),
                        try nativeNinja(
                            build: fmtBuild,
                            containerBuild: "/build/fmt",
                            targets: ["fmt"],
                            root: root, environment: environment,
                            target: target,
                            builder: builder),
                        try nativeCMake(
                            source: root.appending("third-party/double-conversion"),
                            containerSource: "/src/double-conversion",
                            build: conversionBuild,
                            containerBuild: "/build/double-conversion",
                            arguments: [
                                "-DCMAKE_POLICY_VERSION_MINIMUM=3.5",
                                "-DCMAKE_EXPORT_NO_PACKAGE_REGISTRY=ON",
                            ],
                            root: root,
                            environment: environment,
                            target: target,
                            builder: builder),
                        try nativeNinja(
                            build: conversionBuild,
                            containerBuild: "/build/double-conversion",
                            targets: ["double-conversion"],
                            root: root, environment: environment,
                            target: target,
                            builder: builder),
                    ]))
        )
        return SupportLibraryArtifacts(
            task: task,
            libraries: [fmt, conversion])
    }

    package static func buildCxxRuntime(
        root: FilePath,
        environment: [String: String],
        target: NativeLinuxTarget,
        dependencies: ArtifactReference<DirectoryArtifact>,
        boost: ArtifactReference<PathArtifact>,
        hermes: HermesArtifacts,
        support: SupportLibraryArtifacts,
        builder: NativeOCIConfiguration
    ) throws -> CxxRuntimeArtifacts {
        let buildRoot = root.appending(".rn-build/\(target.identifier)")
        let glogBuild = buildRoot.appending("glog")
        let nativeBuild = buildRoot.appending("reactnative")
        let reactNative = root.appending(
            "node_modules/react-native")
        let reactCxxPlatform = root.appending(
            "third-party/react-native/packages/react-native/ReactCxxPlatform")
        var taskBuilder = TaskBuilder(
            id: TaskID(rawValue: "rn.cxx.\(target.identifier)"),
            component: ComponentID(rawValue: "rn"))
        taskBuilder.consume(builder.image)
        taskBuilder.consume(builder.swiftSDK)
        taskBuilder.consume(dependencies)
        taskBuilder.consume(boost)
        for library in hermes.libraries + support.libraries {
            taskBuilder.consume(library)
        }
        taskBuilder.consume(hermes.compiler)
        var outputArtifacts: [ArtifactReference<FileArtifact>] = []
        for output in [
            glogBuild.appending("libglog.a"),
            glogBuild.appending("glog/logging.h"),
        ]
            + [
                "libfolly_runtime.a", "libjsi.a", "libreact_native.a",
                "libreact_cxx_platform.a", "libyogacore.a",
            ].map({ nativeBuild.appending($0) })
        {
            let artifact: ArtifactReference<FileArtifact> = try taskBuilder.output(
                OutputSlotID(rawValue: output.lastComponent?.string ?? "output"),
                path: output,
                validation: .regularFile)
            outputArtifacts.append(artifact)
        }
        let task = taskBuilder.build(
            inputs: [
                .sourceCheckout(root.appending("third-party/glog")),
                .sourceCheckout(root.appending("third-party/folly")),
                .sourceCheckout(root.appending("third-party/fast_float")),
                .sourceCheckout(root.appending("third-party/hermes")),
                .sourceCheckout(root.appending("third-party/react-native")),
                .sourceCheckout(root.appending("../core/swiftpm/cmake/reactnative")),
            ],
            locks: [.checkout("rn-native-\(target.identifier)")],
            action:
                try AnyColliderAction(
                    RunReactNativeNativeBuildAction(executions: [
                        try nativeCMake(
                            source: root.appending("third-party/glog"),
                            containerSource: "/src/glog",
                            build: glogBuild,
                            containerBuild: "/build/glog",
                            arguments: [
                                "-DCMAKE_POLICY_VERSION_MINIMUM=3.5",
                                "-DCMAKE_EXPORT_NO_PACKAGE_REGISTRY=ON",
                                "-DWITH_GFLAGS=OFF", "-DBUILD_TESTING=OFF",
                                "-DHAVE_EXECINFO_H=0", "-DHAVE_UNWIND_H=0",
                            ],
                            root: root,
                            environment: environment,
                            target: target,
                            builder: builder),
                        try nativeNinja(
                            build: glogBuild,
                            containerBuild: "/build/glog",
                            targets: ["glog"],
                            root: root, environment: environment,
                            target: target,
                            builder: builder),
                        try nativeCMake(
                            source: root.appending("../core/swiftpm/cmake/reactnative"),
                            containerSource: "/core-cmake",
                            build: nativeBuild,
                            containerBuild: "/build/reactnative",
                            arguments: [
                                "-DFOLLY_DIR=\(nativePath(root.appending("third-party/folly"), "/src/folly"))",
                                "-DBOOST_INC=\(nativePath(root.appending(".rn-build/dependencies/boost/current"), "/dependencies/boost/current"))",
                                "-DGLOG_INC=\(nativePath(glogBuild, "/build/glog"))",
                                "-DGLOG_SRC_INC=\(nativePath(root.appending("third-party/glog/src"), "/src/glog/src"))",
                                "-DDOUBLE_CONVERSION_SOURCE_DIR=/src/double-conversion/src",
                                "-DFMT_INC=\(nativePath(root.appending("third-party/fmt/include"), "/src/fmt/include"))",
                                "-DFAST_FLOAT_INC=\(nativePath(root.appending("third-party/fast_float/include"), "/src/fast_float/include"))",
                                "-DJSI_DIR=\(nativePath(reactNative.appending("ReactCommon/jsi"), "/react-native/ReactCommon/jsi"))",
                                "-DRN_ROOT=\(nativePath(reactNative, "/react-native"))",
                                "-DRCXXP_ROOT=\(nativePath(reactCxxPlatform, "/src/react-native/packages/react-native/ReactCxxPlatform"))",
                                "-DRN_CODEGEN_ROOT=/react-native/React/FBReactNativeSpec",
                                "-DHERMES_DIR=\(nativePath(root.appending("third-party/hermes"), "/src/hermes"))",
                            ],
                            root: root,
                            environment: environment,
                            target: target,
                            builder: builder),
                        try nativeNinja(
                            build: nativeBuild,
                            containerBuild: "/build/reactnative",
                            targets: [
                                "folly_runtime", "jsi", "react_native",
                                "react_cxx_platform", "yogacore",
                            ],
                            root: root,
                            environment: environment,
                            target: target,
                            builder: builder),
                    ]))
        )
        return CxxRuntimeArtifacts(task: task, outputs: outputArtifacts)
    }

    package static func publishNativeSDK(
        root: FilePath,
        sdkRoot: FilePath,
        target: NativeLinuxTarget,
        dependencies: ArtifactReference<DirectoryArtifact>,
        runtime: CxxRuntimeArtifacts
    ) throws -> NativeSDKArtifacts {
        let buildRoot = root.appending(".rn-build/\(target.identifier)")
        let sdk = sdkRoot.appending("rn")
        let links: [(String, FilePath)] = [
            ("include/hermes", root.appending("third-party/hermes")),
            ("include/folly", root.appending("third-party/folly")),
            (
                "include/boost",
                root.appending(".rn-build/dependencies/boost/current")
            ),
            ("include/glog", root.appending("third-party/glog")),
            ("include/glog-gen", buildRoot.appending("glog")),
            (
                "include/rn-codegen",
                root.appending(
                    "node_modules/react-native/React/FBReactNativeSpec")
            ),
            ("include/fmt", root.appending("third-party/fmt")),
            ("include/fast_float", root.appending("third-party/fast_float")),
            (
                "include/double-conversion",
                root.appending("third-party/double-conversion/src")
            ),
            (
                "include/react-native",
                root.appending("node_modules/react-native")
            ),
            (
                "include/react-cxx-platform",
                root.appending(
                    "third-party/react-native/packages/react-native/ReactCxxPlatform")
            ),
            ("lib/rn", buildRoot),
            (
                "include/react-bridge",
                root.appending(
                    "swiftpm/cmodules/NucleusReactRuntimeCxxBridge")
            ),
            (
                "include/react-runtime",
                root.appending(
                    "swift/Sources/NucleusReactRuntime/cxx")
            ),
        ]
        var builder = TaskBuilder(
            id: TaskID(rawValue: "rn.native-sdk.\(target.identifier)"),
            component: ComponentID(rawValue: "rn"))
        for output in runtime.outputs {
            builder.consume(output)
        }
        builder.consume(dependencies)
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
                .string(
                    name: $0.0,
                    value: $0.1.string)
            },
            locks: [
                .shared(sdkRoot.appending(".rn.lock"))
            ],
            action:
                try AnyColliderAction(
                    PublishReactNativeSDKAction(sdk: sdk, links: links))
        )
        return NativeSDKArtifacts(task: task, outputs: outputs)
    }

}

private struct DownloadBoostAction: ColliderAction {
    static let kind: ActionKind = "rn.download-boost"

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

private struct PublishReactNativeSDKAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let sdk: FilePath
        let encodedLinks: String

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: sdk.string)
            encoder.append(tag: 2, string: encodedLinks)
        }
    }

    static let kind: ActionKind = "rn.publish-native-sdk"

    let sdk: FilePath
    let links: [(name: String, target: FilePath)]

    var identity: Identity {
        Identity(
            sdk: sdk,
            encodedLinks: links.map { "\($0.name)\u{0}\($0.target.string)" }
                .joined(separator: "\u{1}"))
    }

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

private struct ProvisionBoostAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let archive: FilePath
        let candidate: FilePath
        let generation: FilePath
        let active: FilePath

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: archive.string)
            encoder.append(tag: 2, string: candidate.string)
            encoder.append(tag: 3, string: generation.string)
            encoder.append(tag: 4, string: active.string)
            encoder.append(tag: 5, string: "boost_1_84_0/boost")
            encoder.append(tag: 6, integer: 2)
        }
    }

    static let kind: ActionKind = "rn.provision-boost"

    let archive: FilePath
    let candidate: FilePath
    let generation: FilePath
    let active: FilePath
    let workingDirectory: FilePath
    let environment: [String: String]

    var identity: Identity {
        Identity(
            archive: archive,
            candidate: candidate,
            generation: generation,
            active: active)
    }

    var requirements: ActionRequirements {
        ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "tar", executable: .named("tar"), role: .operational)
            ],
            effects: [
                ActionEffect(.read, scope: .input(archive)),
                ActionEffect(.readWrite, scope: .scratch(candidate)),
                ActionEffect(.readWrite, scope: .output(generation)),
                ActionEffect(.readWrite, scope: .publication(active)),
            ],
            executionPlatform: .macOSARM64Native)
    }

    func execute(in context: ActionContext) async throws {
        try context.files.remove(candidate)
        try context.files.createDirectory(candidate)
        let result = try await context.commands.execute(
            CommandSpec(
                executable: .named("tar"),
                arguments: [
                    "xzf", archive.string,
                    "--strip-components=2",
                    "-C", candidate.string,
                    "boost_1_84_0/boost",
                ],
                workingDirectory: workingDirectory,
                environment: environment))
        guard result.status == 0 else {
            throw BoostProvisioningFailure.commandFailed(result.status)
        }
        try context.files.replaceSymlink(
            at: candidate.appending("boost"),
            target: ".")
        try context.files.publishGeneration(
            candidate: candidate,
            generation: generation,
            active: active)
    }
}

private enum BoostProvisioningFailure: Error {
    case commandFailed(Int32)
}

private let boostVersion = "1.84.0"
private let boostArchiveName = "boost_1_84_0.tar.gz"
private let boostArchiveSHA256 =
    "a5800f405508f5df8114558ca9855d2640a2de8f0445f051fa1c7c3383045724"

package enum ReactNativeRecipeFailure: Error, CustomStringConvertible {
    case invalidBoostSpecification
    case missingICULibrary(NativeLinuxTarget)

    package var description: String {
        switch self {
        case .invalidBoostSpecification:
            "the pinned Boost download specification is invalid"
        case .missingICULibrary(let target):
            "React Native is missing Core's ICU artifact for \(target.identifier)"
        }
    }
}

private func commonCMakeArguments(
    _ target: NativeLinuxTarget,
    compileDefinitions: [String] = [],
    additionalCXXFlags: [String] = []
) -> [String] {
    let sysroot = target.containerSwiftSDKRoot
    let definitions = compileDefinitions.map { "-D\($0)" }.joined(separator: " ")
    let cxxFlags =
        [
            "-stdlib=libc++",
            "-idirafter/usr/include",
            "-idirafter/usr/include/\(target.gnuArchitecture)",
            definitions,
        ] + additionalCXXFlags
    let joinedCXXFlags = cxxFlags.filter { !$0.isEmpty }.joined(separator: " ")
    return [
        "-G", "Ninja",
        "-DCMAKE_BUILD_TYPE=Release",
        "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
        "-DCMAKE_SYSTEM_NAME=Linux",
        "-DCMAKE_SYSTEM_PROCESSOR=\(target.architecture.rawValue)",
        "-DCMAKE_C_COMPILER=clang",
        "-DCMAKE_CXX_COMPILER=clang++",
        "-DCMAKE_C_COMPILER_TARGET=\(target.targetTriple)",
        "-DCMAKE_CXX_COMPILER_TARGET=\(target.targetTriple)",
        "-DCMAKE_ASM_COMPILER_TARGET=\(target.targetTriple)",
        "-DCMAKE_SYSROOT=\(sysroot)",
        "-DCMAKE_C_FLAGS=-idirafter/usr/include -idirafter/usr/include/\(target.gnuArchitecture)",
        "-DCMAKE_CXX_FLAGS=\(joinedCXXFlags)",
        "-DCMAKE_EXE_LINKER_FLAGS=-stdlib=libc++ -fuse-ld=lld -L/usr/lib/\(target.gnuArchitecture)",
        "-DCMAKE_SHARED_LINKER_FLAGS=-stdlib=libc++ -fuse-ld=lld -L/usr/lib/\(target.gnuArchitecture)",
        "-DCMAKE_C_COMPILER_LAUNCHER=ccache",
        "-DCMAKE_CXX_COMPILER_LAUNCHER=ccache",
    ]
}

private func nativePath(_ host: FilePath, _ container: String) -> String {
    container
}

private func nativeCMake(
    source: FilePath,
    containerSource: String,
    build: FilePath,
    containerBuild: String,
    arguments: [String],
    root: FilePath,
    environment: [String: String],
    target: NativeLinuxTarget,
    builder: NativeOCIConfiguration,
    compileDefinitions: [String] = [],
    additionalCXXFlags: [String] = [],
    additionalMounts: [OCIMount] = []
) throws -> OCIExecution {
    _ = source
    _ = build
    return try nativeContainerOperation(
        root: root,
        builder: builder,
        command: [
            "cmake",
            "-S", containerSource,
            "-B", containerBuild,
        ]
            + commonCMakeArguments(
                target,
                compileDefinitions: compileDefinitions,
                additionalCXXFlags: additionalCXXFlags) + arguments,
        environment: environment,
        target: target,
        additionalMounts: additionalMounts)
}

private func nativeNinja(
    build: FilePath,
    containerBuild: String,
    targets: [String],
    root: FilePath,
    environment: [String: String],
    target: NativeLinuxTarget,
    builder: NativeOCIConfiguration,
    additionalMounts: [OCIMount] = []
) throws -> OCIExecution {
    _ = build
    return try nativeContainerOperation(
        root: root,
        builder: builder,
        command: ["ninja", "-C", containerBuild] + targets,
        environment: environment,
        target: target,
        additionalMounts: additionalMounts)
}

private func nativeContainerOperation(
    root: FilePath,
    builder: NativeOCIConfiguration,
    command: [String],
    environment: [String: String],
    target: NativeLinuxTarget,
    additionalMounts: [OCIMount] = []
) throws -> OCIExecution {
    return OCIExecution(
        executionPlatform: .linuxARM64OCI,
        artifactTarget: target.artifactTarget,
        imageID: builder.imageID,
        hostname: "native-react-build",
        workingDirectory: "/src",
        hostWorkingDirectory: root,
        mounts: [
            OCIMount(
                source: root.appending("third-party"),
                target: "/src",
                access: .readOnly),
            OCIMount(
                source: root.appending("node_modules/react-native"),
                target: "/react-native",
                access: .readOnly),
            OCIMount(
                source: root.appending(".rn-build/dependencies"),
                target: "/dependencies",
                access: .readOnly),
            OCIMount(
                source: root.appending(".rn-build/generated"),
                target: "/generated",
                access: .readOnly),
            OCIMount(
                source: root.appending(".rn-build/\(target.identifier)"),
                target: "/build",
                access: .readWrite),
            OCIMount(
                source: root.appending("../core/swiftpm/cmake/reactnative"),
                target: "/core-cmake",
                access: .readOnly),
            OCIMount(
                source: root.appending("../tools"),
                target: "/tools",
                access: .readOnly),
            OCIMount(
                source: builder.ccache(for: target),
                target: "/ccache",
                access: .readWrite),
            OCIMount(
                source: builder.swiftSDKRoot,
                target: "/swift-sdk",
                access: .readOnly),
        ] + additionalMounts,
        userPolicy: .builder,
        capabilityPolicy: .dropAll,
        privilegePolicy: .prohibitAcquisition,
        processFilesystemPolicy: .standard,
        intelBinaryTranslationPolicy: target.intelBinaryTranslationPolicy,
        resourceLimits: .parallelBuild,
        containerEnvironment: [
            "PKG_CONFIG_LIBDIR":
                "/usr/lib/\(target.gnuArchitecture)/pkgconfig:/usr/share/pkgconfig",
            "LD_LIBRARY_PATH": target.containerRuntimeLibraryPath,
        ],
        command: ["react-native"] + command,
        environment: environment,
        output: .logged)
}

private struct InstallReactNativeJavaScriptDependenciesAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let root: FilePath
        let cache: FilePath

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: root.string)
            encoder.append(tag: 2, string: cache.string)
            encoder.append(tag: 3, string: "linux")
            encoder.append(tag: 4, string: "multiarch")
            encoder.append(tag: 5, string: "copyfile")
        }
    }

    static let kind: ActionKind = "rn.install-javascript-dependencies"

    let root: FilePath
    let cache: FilePath
    let environment: [String: String]

    var identity: Identity { Identity(root: root, cache: cache) }

    var requirements: ActionRequirements {
        ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "bun", executable: .named("bun"), role: .semantic)
            ],
            effects: [
                ActionEffect(.read, scope: .checkout(root)),
                ActionEffect(
                    .readWrite,
                    scope: .publication(root.appending("node_modules"))),
                ActionEffect(.readWrite, scope: .scratch(cache)),
            ],
            lane: .hostExclusive,
            networkAccess: .unrestricted,
            executionPlatform: .macOSARM64Native)
    }

    func execute(in context: ActionContext) async throws {
        let result = try await context.commands.execute(
            CommandSpec(
                executable: .named("bun"),
                arguments: [
                    "install",
                    "--frozen-lockfile",
                    "--no-save",
                    "--os", "linux",
                    "--cpu", "*",
                    "--backend", "copyfile",
                    "--cache-dir", cache.string,
                ],
                workingDirectory: root,
                environment: environment))
        guard result.status == 0 else {
            throw JavaScriptDependencyInstallFailure.commandFailed(result.status)
        }
    }
}

private enum JavaScriptDependencyInstallFailure: Error {
    case commandFailed(Int32)
}

private struct RunReactNativeNativeBuildAction: ColliderAction {
    static let kind: ActionKind = "rn.run-native-build"

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
