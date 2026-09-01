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
    package let active: ArtifactReference
}

package struct JavaScriptDependencyArtifacts: Sendable {
    package let task: TaskDeclaration
    package let nodeModules: ArtifactReference
}

package struct ReactNativeCodegenArtifacts: Sendable {
    package let task: TaskDeclaration
    package let output: ArtifactReference
}

package struct HermesArtifacts: Sendable {
    package let task: TaskDeclaration
    package let libraries: [ArtifactReference]
    package let compiler: ExecutableReference
    package let hostTools: ArtifactReference?
}

package struct SupportLibraryArtifacts: Sendable {
    package let task: TaskDeclaration
    package let libraries: [ArtifactReference]
}

package struct CxxRuntimeArtifacts: Sendable {
    package let task: TaskDeclaration
    package let outputs: [ArtifactReference]
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
        skiaExternalSources: ArtifactReference,
        icuLibraries: [NativeLinuxTarget: ArtifactReference]
    ) throws -> PreparedComponent {
        let native = try context.configuration(
            NativeBuilderGraphConfiguration.self,
            for: NativeBuilderColliderRecipe.descriptor.id)
        let root = context.componentRoot(descriptor)
        let javascript = try installJavaScriptDependencies(
            root: root,
            cacheRoot: context.cacheRoot,
            environment: context.environment)
        let codegen = try generateReactNativeCode(
            root: root,
            cacheRoot: context.cacheRoot,
            dependencies: javascript.nodeModules,
            environment: context.environment)
        let boost = try provisionBoost(
            root: root,
            cacheRoot: context.cacheRoot,
            environment: context.environment)
        var tasks = [javascript.task, codegen.task] + boost.tasks
        var bootstrapRoots: Set<TaskID> = []
        var nativeSDKs: [NativeLinuxTarget: ArtifactReferenceSet] = [:]
        var hermesHostTools: ArtifactReference?
        let nodeModules = javaScriptWorkspace(cacheRoot: context.cacheRoot)
            .appending("node_modules")
        for architecture in PlatformArchitecture.allCases {
            let target = NativeLinuxTarget(architecture: architecture)
            guard let icuLibrary = icuLibraries[target] else {
                throw ReactNativeRecipeFailure.missingICULibrary(target)
            }
            let hermes = try buildHermes(
                root: root,
                nodeModules: nodeModules,
                sdkRoot: native.nativeSDK(for: target),
                environment: context.environment,
                target: target,
                dependencies: javascript.nodeModules,
                skiaExternalSources: skiaExternalSources,
                icuLibrary: icuLibrary,
                importedHostTools: hermesHostTools,
                builder: native.builder)
            if architecture == .arm64 {
                hermesHostTools = hermes.hostTools
            }
            let support = try buildSupportLibraries(
                root: root,
                nodeModules: nodeModules,
                sdkRoot: native.nativeSDK(for: target),
                environment: context.environment,
                target: target,
                dependencies: javascript.nodeModules,
                builder: native.builder)
            let cxx = try buildCxxRuntime(
                root: root,
                nodeModules: nodeModules,
                sdkRoot: native.nativeSDK(for: target),
                environment: context.environment,
                target: target,
                dependencies: javascript.nodeModules,
                codegen: codegen.output,
                boost: boost.active,
                hermes: hermes,
                support: support,
                builder: native.builder)
            let sdk = try publishNativeSDK(
                root: root,
                executionPath: context.executionPath,
                nodeModules: javaScriptWorkspace(cacheRoot: context.cacheRoot)
                    .appending("node_modules"),
                codegen: codegenRoot(cacheRoot: context.cacheRoot),
                sdkRoot: native.nativeSDK(for: target),
                target: target,
                dependencies: javascript.nodeModules,
                boost: boost.active,
                hermes: hermes,
                support: support,
                runtime: cxx)
            tasks += [hermes.task, support.task, cxx.task, sdk.task]
            bootstrapRoots.insert(sdk.task.id)
            nativeSDKs[target] = sdk.outputs
        }
        func producers(_ matches: (String) -> Bool) -> Set<StorageProducer> {
            Set(tasks.compactMap { matches($0.id.rawValue) ? .task($0.id) : nil })
        }
        let javascriptProducers = producers { $0 == "rn.javascript-dependencies" }
        let codegenProducers = producers { $0 == "rn.codegen" }
        let boostProducers = producers {
            $0 == "rn.boost-download" || $0 == "rn.boost"
        }
        var storage = [
            StorageDeclaration(
                id: "rn-boost-inputs",
                owner: descriptor.id,
                producers: boostProducers,
                storageClass: .cache,
                root: context.cacheRoot.appending("inputs/react-native/boost"),
                safetyRoot: context.cacheRoot.appending("inputs/react-native"),
                retentionPolicy: .singleWorkingSet),
            StorageDeclaration(
                // The materialized workspace, manifests and installed packages
                // alike: it is one derived working set, and the installer
                // writes all of it.
                id: "rn-javascript-workspace",
                owner: descriptor.id,
                producers: javascriptProducers,
                storageClass: .incremental,
                root: ReactNativeColliderRecipe.javaScriptWorkspace(
                    cacheRoot: context.cacheRoot),
                safetyRoot: context.cacheRoot,
                retentionPolicy: .singleWorkingSet),
            StorageDeclaration(
                id: "rn-codegen",
                owner: descriptor.id,
                producers: codegenProducers,
                storageClass: .incremental,
                root: ReactNativeColliderRecipe.codegenRoot(
                    cacheRoot: context.cacheRoot),
                safetyRoot: context.cacheRoot,
                retentionPolicy: .singleWorkingSet),
            StorageDeclaration(
                id: "rn-javascript-cache",
                owner: descriptor.id,
                producers: javascriptProducers,
                storageClass: .cache,
                root: context.cacheRoot.appending("bun/linux-multiarch"),
                safetyRoot: context.cacheRoot.appending("bun"),
                retentionPolicy: .singleWorkingSet),
        ]
        for architecture in PlatformArchitecture.allCases {
            let target = NativeLinuxTarget(architecture: architecture)
            let sdkRoot = native.nativeSDK(for: target)
            storage.append(
                StorageDeclaration(
                    id: "rn-sdk-\(target.identifier)",
                    owner: descriptor.id,
                    producers: producers {
                        $0 == "rn.native-sdk.\(target.identifier)"
                            || $0 == "rn.hermes.\(target.identifier)"
                            || $0 == "rn.support.\(target.identifier)"
                            || $0 == "rn.cxx.\(target.identifier)"
                    },
                    storageClass: .published,
                    root: sdkRoot.appending("rn"),
                    safetyRoot: sdkRoot,
                    retentionPolicy: .singleWorkingSet))
        }
        let component = try ComponentDefinition(
            descriptor: descriptor,
            tasks: tasks,
            entrypoints: [
                ComponentEntrypoint(id: .bootstrap, roots: bootstrapRoots)
            ],
            storage: storage)
        return PreparedComponent(
            component: component,
            artifacts: Artifacts(nativeSDKs: nativeSDKs))
    }

    /// The materialized JavaScript workspace. It is derived from the checkout
    /// and lives in declared storage, so no build writes the tree it reads.
    package static func javaScriptWorkspace(cacheRoot: FilePath) -> FilePath {
        cacheRoot.appending("js-workspace")
    }

    /// Generated JavaScript-side sources, derived from the workspace and the
    /// checkout and therefore stored beside the workspace rather than in the
    /// checkout they are derived from.
    package static func codegenRoot(cacheRoot: FilePath) -> FilePath {
        cacheRoot.appending("codegen")
    }

    package static func installJavaScriptDependencies(
        root: FilePath,
        cacheRoot: FilePath,
        environment: [String: String]
    ) throws -> JavaScriptDependencyArtifacts {
        let packageManifest = root.appending("package.json")
        let lockfile = root.appending("bun.lock")
        // The materialized JavaScript workspace, in declared storage rather
        // than in the checkout it is derived from.
        let workspace = javaScriptWorkspace(cacheRoot: cacheRoot)
        let active = workspace.appending("node_modules")
        var task = TaskBuilder(
            id: TaskID(rawValue: "rn.javascript-dependencies"),
            component: ComponentID(rawValue: "rn"))
        let nodeModules: ArtifactReference = try task.output(
            "node-modules",
            path: active,
            validation: .nonEmptyDirectory)
        let cache = cacheRoot.appending("bun/linux-multiarch")
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
                        workspace: workspace,
                        cache: cache,
                        environment: environment)))
        return JavaScriptDependencyArtifacts(
            task: declaration,
            nodeModules: nodeModules)
    }

    package static func generateReactNativeCode(
        root: FilePath,
        cacheRoot: FilePath,
        dependencies: ArtifactReference,
        environment: [String: String]
    ) throws -> ReactNativeCodegenArtifacts {
        let output = codegenRoot(cacheRoot: cacheRoot)
        var builder = TaskBuilder(
            id: TaskID(rawValue: "rn.codegen"),
            component: ComponentID(rawValue: "rn"))
        builder.consume(dependencies)
        let artifact: ArtifactReference = try builder.output(
            "codegen",
            path: output,
            validation: .nonEmptyDirectory)
        let task = builder.build(
            inputs: [
                .file(root.appending("package.json")),
                .file(root.appending("bun.lock")),
            ],
            locks: [.checkout("rn-codegen")],
            action: try AnyColliderAction(
                GenerateReactNativeCodeAction(
                    root: root,
                    nodeModules: javaScriptWorkspace(cacheRoot: cacheRoot)
                        .appending("node_modules"),
                    output: output,
                    environment: environment)))
        return ReactNativeCodegenArtifacts(task: task, output: artifact)
    }

    package static func provisionBoost(
        root: FilePath,
        cacheRoot: FilePath,
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
        let boostRoot = cacheRoot.appending("inputs/react-native/boost")
        let archive = boostRoot.appending("downloads/\(boostArchiveName)")
        let generations = boostRoot.appending("generations")
        let candidate = generations.appending(
            ".candidate-\(boostArchiveSHA256)")
        let generation = generations.appending(boostArchiveSHA256)
        let active = generations.appending("current")
        var downloadBuilder = TaskBuilder(
            id: TaskID(rawValue: "rn.boost-download"),
            component: ComponentID(rawValue: "rn"))
        let downloadedArchive: ArtifactReference = try downloadBuilder.output(
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
        let _: ArtifactReference = try boostBuilder.output(
            "version-header",
            path: generation.appending("version.hpp"),
            validation: .regularFile)
        let activeArtifact: ArtifactReference = try boostBuilder.output(
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
        nodeModules: FilePath,
        sdkRoot: FilePath,
        environment: [String: String],
        target: NativeLinuxTarget,
        dependencies: ArtifactReference,
        skiaExternalSources: ArtifactReference,
        icuLibrary: ArtifactReference,
        importedHostTools: ArtifactReference? = nil,
        builder: NativeOCIConfiguration
    ) throws -> HermesArtifacts {
        guard target.architecture == .arm64 || importedHostTools != nil else {
            throw ReactNativeRecipeFailure.missingHermesHostTools
        }
        let source = root.appending("third-party/hermes")
        let artifacts = sdkRoot.appending("rn/lib/rn/hermes")
        let combined = artifacts.appending("libhermes_lean_combined.a")
        let hermesc = artifacts.appending("bin/hermesc")
        let hostToolsRoot = artifacts.appending("host-tools")
        let workspaces = ReactNativeBuildWorkspaces(
            component: "hermes",
            target: target)
        let icuSource = root.appending(
            "../core/third-party/skia/third_party/externals/icu/source"
        ).lexicallyNormalized()
        let icuLibraryDirectory = icuLibrary.path.removingLastComponent()
        var taskBuilder = TaskBuilder(
            id: TaskID(rawValue: "rn.hermes.\(target.identifier)"),
            component: ComponentID(rawValue: "rn"))
        taskBuilder.consume(builder.image)
        taskBuilder.consume(builder.nativeSysroot)
        taskBuilder.consume(dependencies)
        taskBuilder.consume(skiaExternalSources)
        taskBuilder.consume(icuLibrary)
        if let importedHostTools {
            taskBuilder.consume(importedHostTools)
        }
        let combinedArtifact: ArtifactReference = try taskBuilder.output(
            "combined-library",
            path: combined,
            validation: .regularFile)
        let compilerArtifact: ExecutableReference = try taskBuilder.executableOutput(
            "compiler",
            path: hermesc)
        let hostToolsArtifact: ArtifactReference? =
            if target.architecture == .arm64 {
                try taskBuilder.output(
                    "host-tools",
                    path: hostToolsRoot,
                    validation: .nonEmptyDirectory)
            } else {
                nil
            }
        let importedHostToolsMounts =
            importedHostTools.map {
                [
                    OCIMount(
                        source: $0.path,
                        target: "/host-hermes",
                        access: .readOnly)
                ]
            } ?? []
        let importedHostToolsArguments =
            importedHostTools == nil
            ? [] : ["-DIMPORT_HOST_COMPILERS=/host-hermes/ImportHostCompilers.cmake"]
        let task = taskBuilder.build(
            inputs: [
                .sourceCheckout(source),
                .file(root.appending("../tools/merge-static-archives.sh").lexicallyNormalized()),
            ],
            locks: [.checkout("rn-hermes-\(target.identifier)")],
            action:
                try AnyColliderAction(
                    RunReactNativeNativeBuildAction(
                        artifactRoots: [artifacts],
                        executions: [
                            try nativeCMake(
                                containerSource: "/src/hermes",
                                containerBuild: "/build/hermes",
                                arguments: [
                                    "-DBUILD_SHARED_LIBS=OFF",
                                    "-DHERMES_BUILD_SHARED_JSI=OFF",
                                    "-DHERMES_BUILD_APPLE_FRAMEWORK=OFF",
                                    "-DHERMES_ENABLE_DEBUGGER=OFF",
                                    "-DHERMES_ENABLE_INTL=ON",
                                    "-DJSI_DIR=/react-native/ReactCommon/jsi",
                                    "-DICU_FOUND=ON",
                                    "-DICU_INCLUDE_DIRS=/icu/common;/icu/i18n",
                                    "-DICU_LIBRARIES=/icu/lib/libicu.a",
                                ] + importedHostToolsArguments,
                                root: root,
                                nodeModules: nodeModules,
                                environment: environment,
                                target: target,
                                builder: builder,
                                workspaces: workspaces,
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
                                ] + importedHostToolsMounts),
                            try nativeNinja(
                                containerBuild: "/build/hermes",
                                targets: ["hermesvmlean", "jsi", "hermesc"],
                                root: root,
                                nodeModules: nodeModules,
                                environment: environment,
                                target: target,
                                builder: builder,
                                workspaces: workspaces,
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
                                ] + importedHostToolsMounts),
                            try nativeContainerOperation(
                                root: root,
                                nodeModules: nodeModules,
                                builder: builder,
                                command: [
                                    "/tools/merge-static-archives.sh",
                                    "/build/hermes",
                                    "/build/hermes/libhermes_lean_combined.a",
                                    "libgtest",
                                ],
                                environment: environment,
                                target: target,
                                workspaces: workspaces),
                            try nativeContainerOperation(
                                root: root,
                                nodeModules: nodeModules,
                                builder: builder,
                                command: [
                                    "bash", "-lc",
                                    "install -d /export/bin"
                                        + " && install -m 0644"
                                        + " /build/hermes/libhermes_lean_combined.a"
                                        + " /export/libhermes_lean_combined.a"
                                        + " && install -m 0755 /build/hermes/bin/hermesc"
                                        + " /export/bin/hermesc"
                                        + (target.architecture == .arm64
                                            ? " && install -d /export/host-tools/bin"
                                                + " && install -m 0755"
                                                + " /build/hermes/bin/hermesc"
                                                + " /build/hermes/bin/shermes"
                                                + " /export/host-tools/bin/"
                                                + " && install -m 0644"
                                                + " /build/hermes/ImportHostCompilers.cmake"
                                                + " /export/host-tools/ImportHostCompilers.cmake"
                                                + " && sed -i"
                                                + " 's#/build/hermes#/host-hermes#g'"
                                                + " /export/host-tools/ImportHostCompilers.cmake"
                                            : ""),
                                ],
                                environment: environment,
                                target: target,
                                workspaces: workspaces,
                                additionalMounts: [
                                    OCIMount(
                                        boundedExport: artifacts,
                                        target: "/export")
                                ]),
                        ]))
        )
        return HermesArtifacts(
            task: task,
            libraries: [combinedArtifact],
            compiler: compilerArtifact,
            hostTools: hostToolsArtifact)
    }

    package static func buildSupportLibraries(
        root: FilePath,
        nodeModules: FilePath,
        sdkRoot: FilePath,
        environment: [String: String],
        target: NativeLinuxTarget,
        dependencies: ArtifactReference,
        builder: NativeOCIConfiguration
    ) throws -> SupportLibraryArtifacts {
        let artifacts = sdkRoot.appending("rn/lib/rn/support")
        let workspaces = ReactNativeBuildWorkspaces(
            component: "support",
            target: target)
        var taskBuilder = TaskBuilder(
            id: TaskID(rawValue: "rn.support.\(target.identifier)"),
            component: ComponentID(rawValue: "rn"))
        taskBuilder.consume(dependencies)
        taskBuilder.consume(builder.image)
        taskBuilder.consume(builder.nativeSysroot)
        let fmt: ArtifactReference = try taskBuilder.output(
            "fmt-library",
            path: artifacts.appending("fmt/libfmt.a"),
            validation: .regularFile)
        let conversion: ArtifactReference = try taskBuilder.output(
            "double-conversion-library",
            path: artifacts.appending(
                "double-conversion/src/libdouble-conversion.a"),
            validation: .regularFile)
        let task = taskBuilder.build(
            inputs: [
                .sourceCheckout(root.appending("third-party/fmt")),
                .sourceCheckout(
                    root.appending(
                        "third-party/double-conversion")),
            ],
            locks: [.checkout("rn-support-\(target.identifier)")],
            action:
                try AnyColliderAction(
                    RunReactNativeNativeBuildAction(
                        artifactRoots: [artifacts],
                        executions: [
                            try nativeCMake(
                                containerSource: "/src/fmt",
                                containerBuild: "/build/fmt",
                                arguments: [
                                    "-DFMT_TEST=OFF", "-DFMT_DOC=OFF", "-DFMT_INSTALL=OFF",
                                ],
                                root: root,
                                nodeModules: nodeModules,
                                environment: environment,
                                target: target,
                                builder: builder,
                                workspaces: workspaces),
                            try nativeNinja(
                                containerBuild: "/build/fmt",
                                targets: ["fmt"],
                                root: root,
                                nodeModules: nodeModules, environment: environment,
                                target: target,
                                builder: builder,
                                workspaces: workspaces),
                            try nativeCMake(
                                containerSource: "/src/double-conversion",
                                containerBuild: "/build/double-conversion",
                                arguments: [
                                    "-DCMAKE_POLICY_VERSION_MINIMUM=3.5",
                                    "-DCMAKE_EXPORT_NO_PACKAGE_REGISTRY=ON",
                                ],
                                root: root,
                                nodeModules: nodeModules,
                                environment: environment,
                                target: target,
                                builder: builder,
                                workspaces: workspaces),
                            try nativeNinja(
                                containerBuild: "/build/double-conversion",
                                targets: ["double-conversion"],
                                root: root,
                                nodeModules: nodeModules, environment: environment,
                                target: target,
                                builder: builder,
                                workspaces: workspaces),
                            try nativeContainerOperation(
                                root: root,
                                nodeModules: nodeModules,
                                builder: builder,
                                command: [
                                    "bash", "-lc",
                                    "install -d /export/fmt /export/double-conversion/src"
                                        + " && install -m 0644 /build/fmt/libfmt.a"
                                        + " /export/fmt/libfmt.a"
                                        + " && install -m 0644"
                                        + " /build/double-conversion/src/libdouble-conversion.a"
                                        + " /export/double-conversion/src/libdouble-conversion.a",
                                ],
                                environment: environment,
                                target: target,
                                workspaces: workspaces,
                                additionalMounts: [
                                    OCIMount(
                                        boundedExport: artifacts,
                                        target: "/export")
                                ]),
                        ]))
        )
        return SupportLibraryArtifacts(
            task: task,
            libraries: [fmt, conversion])
    }

    package static func buildCxxRuntime(
        root: FilePath,
        nodeModules: FilePath,
        sdkRoot: FilePath,
        environment: [String: String],
        target: NativeLinuxTarget,
        dependencies: ArtifactReference,
        codegen: ArtifactReference,
        boost: ArtifactReference,
        hermes: HermesArtifacts,
        support: SupportLibraryArtifacts,
        builder: NativeOCIConfiguration
    ) throws -> CxxRuntimeArtifacts {
        let artifacts = sdkRoot.appending("rn/lib/rn/runtime")
        let workspaces = ReactNativeBuildWorkspaces(
            component: "runtime",
            target: target)
        var taskBuilder = TaskBuilder(
            id: TaskID(rawValue: "rn.cxx.\(target.identifier)"),
            component: ComponentID(rawValue: "rn"))
        taskBuilder.consume(builder.image)
        taskBuilder.consume(builder.nativeSysroot)
        taskBuilder.consume(dependencies)
        taskBuilder.consume(codegen)
        taskBuilder.consume(boost)
        for library in hermes.libraries + support.libraries {
            taskBuilder.consume(library)
        }
        taskBuilder.consume(hermes.compiler)
        var outputArtifacts: [ArtifactReference] = []
        let generatedGlogHeaders =
            ["logging.h", "raw_logging.h", "stl_logging.h", "vlog_is_on.h"].map {
                artifacts.appending("glog/glog/\($0)")
            }
        let runtimeOutputs =
            [artifacts.appending("glog/libglog.a")]
            + generatedGlogHeaders
            + [
                "libfolly_runtime.a", "libjsi.a", "libreact_native.a", "libworklets.a",
                "libreanimated.a",
                "libreact_cxx_platform.a", "libyogacore.a",
            ].map({ artifacts.appending("reactnative/\($0)") })
        for output in runtimeOutputs {
            let artifact: ArtifactReference = try taskBuilder.output(
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
                .sourceCheckout(
                    root.appending("../core/swiftpm/cmake/reactnative").lexicallyNormalized()),
            ],
            locks: [.checkout("rn-runtime-\(target.identifier)")],
            action:
                try AnyColliderAction(
                    RunReactNativeNativeBuildAction(
                        artifactRoots: [artifacts],
                        executions: [
                            try nativeCMake(
                                containerSource: "/src/glog",
                                containerBuild: "/build/glog",
                                arguments: [
                                    "-DCMAKE_POLICY_VERSION_MINIMUM=3.5",
                                    "-DCMAKE_EXPORT_NO_PACKAGE_REGISTRY=ON",
                                    "-DWITH_GFLAGS=OFF", "-DBUILD_TESTING=OFF",
                                    "-DHAVE_EXECINFO_H=0", "-DHAVE_UNWIND_H=0",
                                ],
                                root: root,
                                nodeModules: nodeModules,
                                environment: environment,
                                target: target,
                                builder: builder,
                                workspaces: workspaces),
                            try nativeNinja(
                                containerBuild: "/build/glog",
                                targets: ["glog"],
                                root: root,
                                nodeModules: nodeModules, environment: environment,
                                target: target,
                                builder: builder,
                                workspaces: workspaces),
                            try nativeCMake(
                                containerSource: "/core-cmake",
                                containerBuild: "/build/reactnative",
                                arguments: [
                                    "-DFOLLY_DIR=/src/folly",
                                    "-DBOOST_INC=/dependencies/boost/current",
                                    "-DGLOG_INC=/build/glog",
                                    "-DGLOG_SRC_INC=/src/glog/src",
                                    "-DDOUBLE_CONVERSION_SOURCE_DIR=/src/double-conversion/src",
                                    "-DFMT_INC=/src/fmt/include",
                                    "-DFAST_FLOAT_INC=/src/fast_float/include",
                                    "-DJSI_DIR=/react-native/ReactCommon/jsi",
                                    "-DRN_ROOT=/react-native",
                                    "-DRCXXP_ROOT=/src/react-native/packages/react-native/ReactCxxPlatform",
                                    "-DRN_CODEGEN_ROOT=/react-native/React/FBReactNativeSpec",
                                    "-DHERMES_DIR=/src/hermes",
                                    "-DWORKLETS_ROOT=/worklets",
                                    "-DREANIMATED_ROOT=/reanimated",
                                    "-DRN_LIBRARY_CODEGEN_ROOT=/rn-codegen/android/app/build/generated/source/codegen/jni",
                                ],
                                root: root,
                                nodeModules: nodeModules,
                                environment: environment,
                                target: target,
                                builder: builder,
                                workspaces: workspaces,
                                additionalMounts: [
                                    OCIMount(
                                        source: boost.path.removingLastComponent(),
                                        target: "/dependencies/boost",
                                        access: .readOnly),
                                    OCIMount(
                                        source: codegen.path,
                                        target: "/rn-codegen",
                                        access: .readOnly),
                                ]),
                            try nativeNinja(
                                containerBuild: "/build/reactnative",
                                targets: [
                                    "folly_runtime", "jsi", "react_native",
                                    "react_cxx_platform", "yogacore", "worklets", "reanimated",
                                ],
                                root: root,
                                nodeModules: nodeModules,
                                environment: environment,
                                target: target,
                                builder: builder,
                                workspaces: workspaces,
                                additionalMounts: [
                                    OCIMount(
                                        source: boost.path.removingLastComponent(),
                                        target: "/dependencies/boost",
                                        access: .readOnly),
                                    OCIMount(
                                        source: codegen.path,
                                        target: "/rn-codegen",
                                        access: .readOnly),
                                ]),
                            try nativeContainerOperation(
                                root: root,
                                nodeModules: nodeModules,
                                builder: builder,
                                command: [
                                    "bash", "-lc",
                                    "install -d /export/glog/glog /export/reactnative"
                                        + " && install -m 0644 /build/glog/libglog.a"
                                        + " /export/glog/libglog.a"
                                        + " && for header in"
                                        + " logging.h raw_logging.h stl_logging.h"
                                        + " vlog_is_on.h; do"
                                        + " install -m 0644 /build/glog/glog/$header"
                                        + " /export/glog/glog/$header; done"
                                        + " && for library in"
                                        + " libfolly_runtime.a libjsi.a libreact_native.a"
                                        + " libreact_cxx_platform.a libyogacore.a"
                                        + " libworklets.a libreanimated.a; do"
                                        + " install -m 0644 /build/reactnative/$library"
                                        + " /export/reactnative/$library; done",
                                ],
                                environment: environment,
                                target: target,
                                workspaces: workspaces,
                                additionalMounts: [
                                    OCIMount(
                                        boundedExport: artifacts,
                                        target: "/export")
                                ]),
                        ]))
        )
        return CxxRuntimeArtifacts(task: task, outputs: outputArtifacts)
    }

    /// The React Native SDK include links for a checkout and staged SDK pair.
    ///
    /// One definition, used both to create the links and to work out which
    /// checkout directories a container following them has to be able to see.
    /// Each states what a root-relative include reaches rather than its whole
    /// linked root: Hermes vendors 7,704 files of `external` and 3,499 more of
    /// tests, tools, and benchmarks that no include names, against 536 in the
    /// three subtrees flags do name.
    package static func nativeSDKCheckoutLinks(
        root: FilePath,
        sdkRoot: FilePath
    ) -> [StagedSDKCheckoutLink] {
        let sdk = sdkRoot.appending("rn")
        let links: [(name: String, checkout: String, reached: [String])] = [
            ("include/hermes", "third-party/hermes", ["API", "public", "include"]),
            ("include/folly", "third-party/folly", ["folly"]),
            ("include/glog", "third-party/glog", ["src"]),
            ("include/fmt", "third-party/fmt", ["include"]),
            ("include/fast_float", "third-party/fast_float", ["include"]),
            ("include/double-conversion", "third-party/double-conversion/src", []),
            (
                "include/react-cxx-platform",
                "third-party/react-native/packages/react-native/ReactCxxPlatform",
                []
            ),
            (
                "include/react-bridge",
                "swiftpm/cmodules/NucleusReactRuntimeCxxBridge",
                []
            ),
            ("include/react-runtime", "swift/Sources/NucleusReactRuntime/cxx", []),
        ]
        return links.map { link in
            let checkout = root.appending(link.checkout)
            return StagedSDKCheckoutLink(
                link: sdk.appending(link.name),
                checkout: checkout,
                // An empty list is a root small enough to name whole, which is
                // cheaper than establishing which part of it is read.
                rootRelativeSubtrees: link.reached.isEmpty
                    ? [checkout]
                    : link.reached.map { checkout.appending($0) })
        }
    }

    package static func publishNativeSDK(
        root: FilePath,
        executionPath: (FilePath) -> String,
        nodeModules: FilePath,
        codegen: FilePath,
        sdkRoot: FilePath,
        target: NativeLinuxTarget,
        dependencies: ArtifactReference,
        boost: ArtifactReference,
        hermes: HermesArtifacts,
        support: SupportLibraryArtifacts,
        runtime: CxxRuntimeArtifacts
    ) throws -> NativeSDKArtifacts {
        let sdk = sdkRoot.appending("rn")
        let boostHeaders = sdk.appending("include/boost")
        let hostLinks: [(String, FilePath)] =
            nativeSDKCheckoutLinks(root: root, sdkRoot: sdkRoot).map {
                (String($0.link.string.dropFirst(sdk.string.count + 1)), $0.checkout)
            } + [
                (
                    "include/glog-gen",
                    sdk.appending("lib/rn/runtime/glog")
                ),
                (
                    "include/rn-codegen",
                    nodeModules.appending("react-native/React/FBReactNativeSpec")
                ),
                (
                    "include/react-native",
                    nodeModules.appending("react-native")
                ),
                (
                    "include/react-native-worklets",
                    nodeModules.appending("react-native-worklets/Common/cpp")
                ),
                (
                    "include/react-native-reanimated",
                    nodeModules.appending("react-native-reanimated/Common/cpp")
                ),
                (
                    "include/react-native-reanimated-native-view",
                    nodeModules.appending("react-native-reanimated/Common/NativeView")
                ),
                (
                    "include/rn-library-codegen",
                    codegen.appending("android/app/build/generated/source/codegen/jni")
                ),
            ]
        // Read only inside containers, where the checkout and the cache are
        // mounted at their canonical locations, so a link naming this host's
        // paths resolves where it is written and dangles where it is used.
        let links = hostLinks.map { ($0.0, executionPath($0.1)) }
        var builder = TaskBuilder(
            id: TaskID(rawValue: "rn.native-sdk.\(target.identifier)"),
            component: ComponentID(rawValue: "rn"))
        let nativeLibraries = hermes.libraries + support.libraries + runtime.outputs
        for output in nativeLibraries {
            builder.consume(output)
        }
        builder.consume(hermes.compiler)
        builder.consume(dependencies)
        builder.consume(boost)
        var outputs = ArtifactReferenceSet()
        let boostOutput: ArtifactReference = try builder.output(
            OutputSlotID(rawValue: "include/boost"),
            path: boostHeaders,
            validation: .nonEmptyDirectory)
        outputs.append(boostOutput)
        for (name, _) in links {
            let output: ArtifactReference = try builder.output(
                OutputSlotID(rawValue: name),
                path: sdk.appending(name),
                validation: .symlink)
            outputs.append(output)
        }
        for output in nativeLibraries {
            outputs.append(output)
        }
        outputs.append(hermes.compiler)
        let task = builder.build(
            inputs: links.map {
                .string(name: $0.0, value: $0.1)
            },
            locks: [
                .shared(sdkRoot.appending(".rn.lock"))
            ],
            action:
                try AnyColliderAction(
                    PublishReactNativeSDKAction(
                        sdk: sdk,
                        boostSource: boost.path,
                        boostHeaders: boostHeaders,
                        links: links))
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
    struct SDKLink: Hashable, Sendable {
        let name: String
        /// Names what the consumer sees, not where this host keeps it.
        let target: String

        init(_ link: (name: String, target: String)) {
            name = link.name
            target = link.target
        }
    }

    struct Identity: ColliderActionIdentity {
        let sdk: FilePath
        let boostSource: FilePath
        let boostHeaders: FilePath
        let links: [SDKLink]

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: sdk)
            encoder.append(path: boostSource)
            encoder.append(path: boostHeaders)
            encoder.appendSequence(links) { linkEncoder, link in
                linkEncoder.append(link.name)
                linkEncoder.append(canonicalizingPathsIn: link.target)
            }
            // Bumped when what this action does with identical inputs changes,
            // so a published tree that predates the change is republished
            // everywhere rather than only where someone thinks to delete it.
            // 2: the declared links became the complete set, and publishing
            // removes the ones it no longer names.
            encoder.appendBehaviorRevision(2)
        }
    }

    static let kind: ActionKind = "rn.publish-native-sdk"

    let sdk: FilePath
    let boostSource: FilePath
    let boostHeaders: FilePath
    let links: [(name: String, target: String)]

    var identity: Identity {
        Identity(
            sdk: sdk,
            boostSource: boostSource,
            boostHeaders: boostHeaders,
            links: links.map(SDKLink.init))
    }

    var requirements: ActionRequirements {
        ActionRequirements(
            effects: [
                ActionEffect(.read, scope: .input(boostSource)),
                // Read as well as written: publishing now reads what the
                // include directory holds so it can remove links it no longer
                // declares.
                ActionEffect(.readWrite, scope: .publication(sdk)),
            ], executionPlatform: .macOSARM64Native)
    }

    func execute(in context: ActionContext) async throws {
        try context.files.remove(boostHeaders)
        try context.files.copyTree(from: boostSource, to: boostHeaders)
        for link in links {
            try context.files.replaceSymlink(
                at: sdk.appending(link.name),
                target: link.target)
        }
        try pruneUndeclaredLinks(in: context)
    }

    /// Removes links this action no longer declares.
    ///
    /// The declared set is the whole set: a link that stops being declared
    /// keeps naming wherever it pointed when it was, which outlives the layout
    /// that produced it. Publishing writes each declared link and would
    /// otherwise leave the rest untouched, so a renamed or retired one stays on
    /// the include path forever, pointing at a tree that has since moved or
    /// disappeared. Only symbolic links are considered: the boost headers next
    /// to them are a real directory this action copies.
    private func pruneUndeclaredLinks(in context: ActionContext) throws {
        let includeRoot = sdk.appending("include")
        let prefix = "include/"
        let declared = Set(
            links.map(\.name)
                .filter { $0.hasPrefix(prefix) }
                .map { String($0.dropFirst(prefix.count)) })
        for entry in try context.files.listDirectory(includeRoot)
        where entry.metadata.type == .symbolicLink
            && !declared.contains(entry.relativePath)
        {
            try context.files.remove(entry.path)
        }
    }
}

private struct ProvisionBoostAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let archive: FilePath
        let candidate: FilePath
        let generation: FilePath
        let active: FilePath

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: archive)
            encoder.append(path: candidate)
            encoder.append(path: generation)
            encoder.append(path: active)
            encoder.append(boostArchiveMember)
            encoder.append(UInt64(boostStrippedComponents))
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
                    "--strip-components=\(boostStrippedComponents)",
                    "-C", candidate.string,
                    boostArchiveMember,
                ],
                workingDirectory: workingDirectory,
                environment: environment))
        guard result.succeeded else {
            throw result.executionFailure(reason: "Boost provisioning failed")
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

private let boostVersion = "1.84.0"
// What is extracted and how deeply it is unwrapped, named once so the identity
// and the command cannot describe different extractions. The identity's bare
// `2` read as a revision marker until the command was consulted.
private let boostArchiveMember = "boost_1_84_0/boost"
private let boostStrippedComponents = 2
private let boostArchiveName = "boost_1_84_0.tar.gz"
private let boostArchiveSHA256 =
    "a5800f405508f5df8114558ca9855d2640a2de8f0445f051fa1c7c3383045724"

package enum ReactNativeRecipeFailure: Error, CustomStringConvertible {
    case invalidBoostSpecification
    case missingHermesHostTools
    case missingICULibrary(NativeLinuxTarget)

    package var description: String {
        switch self {
        case .invalidBoostSpecification:
            "the pinned Boost download specification is invalid"
        case .missingHermesHostTools:
            "the x86_64 Hermes build requires the ARM64 host compiler artifact"
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
    // Compile flags only. `-stdlib=libc++` and `-fuse-ld=lld` live on the link
    // lines below and nowhere else: the first selects a C++ header set that
    // `-nostdinc++` has already switched off and the explicit `-isystem`
    // replaces, and the second selects a linker. CMake forwards these variables
    // to every compile, so each one there costs a
    // `-Wunused-command-line-argument` per translation unit and buys nothing.
    let cxxFlags =
        [
            "-nostdinc++",
            "-isystem\(target.containerLibCXXIncludeRoot)",
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
        "-DCMAKE_C_COMPILER=/usr/bin/clang",
        "-DCMAKE_CXX_COMPILER=/usr/bin/clang++",
        "-DCMAKE_C_COMPILER_TARGET=\(target.targetTriple)",
        "-DCMAKE_CXX_COMPILER_TARGET=\(target.targetTriple)",
        "-DCMAKE_ASM_COMPILER_TARGET=\(target.targetTriple)",
        "-DCMAKE_SYSROOT=\(sysroot)",
        "-DCMAKE_C_FLAGS=-idirafter/usr/include -idirafter/usr/include/\(target.gnuArchitecture)",
        "-DCMAKE_CXX_FLAGS=\(joinedCXXFlags)",
        "-DCMAKE_EXE_LINKER_FLAGS=-stdlib=libc++ -fuse-ld=lld -L\(target.containerLibCXXLibraryRoot)",
        "-DCMAKE_SHARED_LINKER_FLAGS=-stdlib=libc++ -fuse-ld=lld -L\(target.containerLibCXXLibraryRoot)",
        "-DCMAKE_C_COMPILER_LAUNCHER=ccache",
        "-DCMAKE_CXX_COMPILER_LAUNCHER=ccache",
    ]
}

private struct ReactNativeBuildWorkspaces {
    let intermediates: PersistentWorkspaceDeclaration
    let compilerCache: PersistentWorkspaceDeclaration

    init(component: String, target: NativeLinuxTarget) {
        intermediates = PersistentWorkspaceDeclaration(
            identity: PersistentWorkspaceIdentity(
                key: "rn-\(component)-intermediates",
                artifactTarget: target.artifactTarget,
                role: "build"),
            capacityBytes: 100 * 1_024 * 1_024 * 1_024,
            filesystem: .ext4,
            journal: .writeback64MiB)
        compilerCache = PersistentWorkspaceDeclaration(
            identity: PersistentWorkspaceIdentity(
                key: "rn-\(component)-ccache",
                artifactTarget: target.artifactTarget,
                role: "compiler-cache"),
            capacityBytes: 50 * 1_024 * 1_024 * 1_024,
            filesystem: .ext4,
            journal: .writeback64MiB,
            retentionPolicy: .toolManagedLimit(maximumBytes: 50 * 1_024 * 1_024 * 1_024))
    }
}

private func nativeCMake(
    containerSource: String,
    containerBuild: String,
    arguments: [String],
    root: FilePath,
    nodeModules: FilePath,
    environment: [String: String],
    target: NativeLinuxTarget,
    builder: NativeOCIConfiguration,
    workspaces: ReactNativeBuildWorkspaces,
    compileDefinitions: [String] = [],
    additionalCXXFlags: [String] = [],
    additionalMounts: [OCIMount] = []
) throws -> OCIExecution {
    return try nativeContainerOperation(
        root: root,
        nodeModules: nodeModules,
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
        workspaces: workspaces,
        additionalMounts: additionalMounts)
}

private func nativeNinja(
    containerBuild: String,
    targets: [String],
    root: FilePath,
    nodeModules: FilePath,
    environment: [String: String],
    target: NativeLinuxTarget,
    builder: NativeOCIConfiguration,
    workspaces: ReactNativeBuildWorkspaces,
    additionalMounts: [OCIMount] = []
) throws -> OCIExecution {
    return try nativeContainerOperation(
        root: root,
        nodeModules: nodeModules,
        builder: builder,
        command: ["ninja", "-C", containerBuild] + targets,
        environment: environment,
        target: target,
        workspaces: workspaces,
        additionalMounts: additionalMounts)
}

private func nativeContainerOperation(
    root: FilePath,
    nodeModules: FilePath,
    builder: NativeOCIConfiguration,
    command: [String],
    environment: [String: String],
    target: NativeLinuxTarget,
    workspaces: ReactNativeBuildWorkspaces,
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
                source: nodeModules.appending("react-native"),
                target: "/react-native",
                access: .readOnly),
            OCIMount(
                source: nodeModules.appending("react-native-worklets"),
                target: "/worklets",
                access: .readOnly),
            OCIMount(
                source: nodeModules.appending("react-native-reanimated"),
                target: "/reanimated",
                access: .readOnly),
            OCIMount(
                source: root.appending("../core/swiftpm/cmake/reactnative").lexicallyNormalized(),
                target: "/core-cmake",
                access: .readOnly),
            OCIMount(
                source: root.appending("../tools").lexicallyNormalized(),
                target: "/tools",
                access: .readOnly),
            OCIMount(
                source: builder.swiftSDKRoot,
                target: "/swift-sdk",
                access: .readOnly),
        ] + additionalMounts,
        persistentWorkspaceMounts: [
            OCIPersistentWorkspaceMount(
                workspace: workspaces.intermediates,
                target: "/build",
                access: .readWrite),
            OCIPersistentWorkspaceMount(
                workspace: workspaces.compilerCache,
                target: "/ccache",
                access: .readWrite),
        ],
        userPolicy: .builder,
        capabilityPolicy: .dropAll,
        privilegePolicy: .prohibitAcquisition,
        processFilesystemPolicy: .standard,
        resourceLimits: .parallelBuild,
        containerEnvironment: [
            "CCACHE_DIR": "/ccache",
            "PKG_CONFIG_LIBDIR":
                "/usr/lib/\(target.gnuArchitecture)/pkgconfig:/usr/share/pkgconfig",
        ],
        command: ["react-native"] + command,
        environment: environment,
        output: .logged)
}

private struct InstallReactNativeJavaScriptDependenciesAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let root: FilePath
        let cache: FilePath

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: root)
            encoder.append(path: cache)
            encoder.append("linux")
            encoder.append("multiarch")
            encoder.append("copyfile")
        }
    }

    static let kind: ActionKind = "rn.install-javascript-dependencies"

    let root: FilePath
    let workspace: FilePath
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
                ActionEffect(.readWrite, scope: .scratch(workspace)),
                ActionEffect(.readWrite, scope: .scratch(cache)),
            ],
            lane: .hostExclusive,
            networkAccess: .unrestricted,
            executionPlatform: .macOSARM64Native)
    }

    /// The manifests bun reads to resolve `bun.lock`. Staging exactly these
    /// materializes the workspace without copying the sources it describes.
    private func stagedManifests(
        in context: ActionContext
    ) throws -> [(source: FilePath, relative: String)] {
        var staged: [(FilePath, String)] = [
            (root.appending("package.json"), "package.json"),
            (root.appending("bun.lock"), "bun.lock"),
        ]
        // `packages/*` and `packages/*/js`, declared by the workspace itself.
        let packages = root.appending("packages")
        for entry in try context.files.listRecursively(packages)
        where entry.relativePath.hasSuffix("package.json")
            && entry.relativePath.split(separator: "/").count <= 3
        {
            staged.append((entry.path, "packages/\(entry.relativePath)"))
        }
        let patches = root.appending("patches")
        if (try? context.files.listRecursively(patches)) != nil {
            for entry in try context.files.listRecursively(patches)
            where entry.metadata.type == .regular {
                staged.append((entry.path, "patches/\(entry.relativePath)"))
            }
        }
        return staged.map { (source: $0.0, relative: $0.1) }
    }

    func execute(in context: ActionContext) async throws {
        // bun installs into its working directory, and the working directory
        // may not be the checkout: a build that writes `node_modules` into a
        // checkout leaves that checkout permanently dirty, so source identity
        // would carry an exception for a directory the build itself created.
        // The workspace it needs is exactly a set of manifests, materialized
        // here the way every other build input is.
        for staged in try stagedManifests(in: context) {
            try context.files.copy(
                from: staged.source,
                to: workspace.appending(staged.relative))
        }
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
                workingDirectory: workspace,
                environment: environment))
        guard result.succeeded else {
            throw result.executionFailure(
                reason: "JavaScript dependency installation failed")
        }
    }
}

private struct GenerateReactNativeCodeAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let root: FilePath
        let nodeModules: FilePath
        let output: FilePath

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: root)
            encoder.append(path: nodeModules)
            encoder.append(path: output)
            encoder.append("android")
            encoder.append("app")
            encoder.append(true)
            // Bumped when what this action does with identical inputs changes,
            // so the stale output invalidates everywhere rather than only where
            // someone thinks to delete it. 2: discovery scans the materialized
            // workspace instead of the checkout.
            encoder.appendBehaviorRevision(2)
        }
    }

    static let kind: ActionKind = "rn.generate-codegen"

    let root: FilePath
    let nodeModules: FilePath
    let output: FilePath
    let environment: [String: String]

    var identity: Identity {
        Identity(root: root, nodeModules: nodeModules, output: output)
    }

    var requirements: ActionRequirements {
        ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "node", executable: .named("node"), role: .semantic)
            ],
            effects: [
                ActionEffect(.read, scope: .checkout(root)),
                ActionEffect(.read, scope: .input(nodeModules)),
                ActionEffect(.write, scope: .output(output)),
            ],
            executionPlatform: .macOSARM64Native)
    }

    func execute(in context: ActionContext) async throws {
        try context.files.remove(output)
        try context.files.createDirectory(output)
        let result = try await context.commands.execute(
            CommandSpec(
                executable: .named("node"),
                arguments: [
                    // Named absolutely in the materialized workspace: the
                    // checkout carries no `node_modules`, because a build that
                    // installed one there would be writing the tree it reads.
                    nodeModules.appending(
                        "react-native/scripts/generate-codegen-artifacts.js"
                    ).string,
                    // The workspace, not the checkout: the script discovers
                    // which libraries declare a codegen configuration by
                    // scanning `node_modules` under this path, and pointing it
                    // at a tree without one silently generates the application
                    // spec alone, leaving every library's component headers
                    // missing at C++ compile time rather than failing here.
                    "--path", nodeModules.removingLastComponent().string,
                    "--targetPlatform", "android",
                    "--outputPath", output.string,
                    "--source", "app",
                    "--forceOutputPath",
                ],
                workingDirectory: nodeModules.removingLastComponent(),
                environment: environment))
        guard result.succeeded else {
            throw result.executionFailure(reason: "React Native code generation failed")
        }
    }
}

private struct RunReactNativeNativeBuildAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let artifactRoots: [FilePath]
        let pipeline: OCIExecutionPipelineIdentity

        func encode(into encoder: inout IdentityEncoder) {
            encoder.appendSequence(artifactRoots) { $0.append(path: $1) }
            encoder.append(nested: pipeline)
        }
    }

    static let kind: ActionKind = "rn.run-native-build"

    let artifactRoots: [FilePath]
    let pipeline: OCIExecutionPipeline

    init(artifactRoots: [FilePath], executions: [OCIExecution]) throws {
        self.artifactRoots = artifactRoots
        pipeline = try OCIExecutionPipeline(executions)
    }

    var identity: Identity {
        Identity(
            artifactRoots: artifactRoots,
            pipeline: pipeline.identity)
    }

    var requirements: ActionRequirements {
        pipeline.requirements
    }

    var environment: [String: String] { pipeline.environment }

    func execute(in context: ActionContext) async throws {
        for artifactRoot in artifactRoots {
            try context.files.remove(artifactRoot)
            try context.files.createDirectory(artifactRoot)
        }
        try await pipeline.execute(in: context)
    }
}
