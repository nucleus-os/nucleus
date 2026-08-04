import ColliderCore
import CoreColliderRecipe
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

package struct GeneratedReactNativeSources: Sendable {
    package let task: TaskDeclaration
    package let spec: ArtifactReference<DirectoryArtifact>
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

public enum ReactNativeColliderRecipe: ColliderComponent {
    public static let descriptor = ComponentDescriptor(
        id: ComponentID(rawValue: "rn"),
        canonicalName: "react-native",
        directoryName: "react-native",
        aliases: ["rn"])

    public static func makeComponent(
        in context: RecipeContext
    ) throws -> ComponentDefinition {
        let root = context.componentRoot(descriptor)
        let javascript = installJavaScriptDependencies(
            root: root,
            environment: context.environment,
            builder: context.nativeBuilder)
        let generation = try generate(
            root: root,
            environment: context.environment,
            builder: context.nativeBuilder)
        let boost = try provisionBoost(
            root: root,
            environment: context.environment)
        var tasks = [javascript, generation.task] + boost.tasks
        var bootstrapRoots: Set<TaskID> = []
        for architecture in PlatformArchitecture.allCases {
            let target = NativeLinuxTarget(architecture: architecture)
            let hermes = try buildHermes(
                root: root,
                environment: context.environment,
                target: target,
                builder: context.nativeBuilder)
            let support = try buildSupportLibraries(
                root: root,
                environment: context.environment,
                target: target,
                builder: context.nativeBuilder)
            let cxx = try buildCxxRuntime(
                root: root,
                environment: context.environment,
                target: target,
                boost: boost.active,
                generated: generation.spec,
                hermes: hermes,
                support: support,
                builder: context.nativeBuilder)
            let sdk = try publishNativeSDK(
                root: root,
                sdkRoot: context.nativeSDK(for: target),
                target: target,
                runtime: cxx)
            tasks += [hermes.task, support.task, cxx.task, sdk]
            bootstrapRoots.insert(sdk.id)
        }
        return try ComponentDefinition(
            descriptor: descriptor,
            tasks: tasks,
            entrypoints: [
                ComponentEntrypoint(id: .bootstrap, roots: bootstrapRoots),
                ComponentEntrypoint(id: .generate, roots: [generation.task.id]),
            ])
    }

    public static func installJavaScriptDependencies(
        root: FilePath,
        environment: [String: String],
        builder: NativeOCIConfiguration
    ) -> TaskDeclaration {
        TaskDeclaration(
            id: TaskID(rawValue: "rn.javascript-dependencies"),
            component: ComponentID(rawValue: "rn"),
            dependencies: [NativeBuilderTaskIDs.prepare],
            inputs: [
                .file(
                    root.appending(
                        "third-party/react-native/yarn.lock")),
                .file(
                    root.appending(
                        "third-party/react-native/package.json")),
                .file(
                    root.appending(
                        "third-party/react-native/packages/react-native/package.json")),
                .dependencyOutput(builder.imageID),
            ],
            outputs: [
                OutputDeclaration(
                    path: root.appending(
                        "third-party/react-native/node_modules"),
                    validation: .nonEmptyDirectory)
            ],
            locks: [.checkout("rn-javascript")],
            operation: javascriptOperation(
                root: root,
                builder: builder,
                networkPolicy: .externalEnabled,
                command: [
                    // The upstream 0.87 RC pins an exact Hermes compiler newer
                    // than its committed lock entry. Preserve the source lock
                    // while resolving that dependency; the package has no
                    // transitive dependencies and the exact version remains
                    // part of this task's identity above.
                    "/opt/node/bin/corepack", "yarn", "install", "--pure-lockfile",
                ],
                environment: environment))
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
            operation: .download(download, candidate: archive))

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
                .value(
                    name: "boost-version",
                    bytes: Array(boostVersion.utf8)),
                .tool(.named("tar")),
            ],
            locks: [.checkout("rn-boost")],
            operation: .action(
                try AnyColliderAction(
                    ProvisionBoostAction(
                        archive: archive,
                        candidate: candidate,
                        generation: generation,
                        active: active,
                        workingDirectory: root,
                        environment: environment))))
        return BoostArtifacts(
            tasks: [downloadTask, boostTask],
            active: activeArtifact)
    }

    package static func generate(
        root: FilePath,
        environment: [String: String],
        builder: NativeOCIConfiguration
    ) throws -> GeneratedReactNativeSources {
        var taskBuilder = TaskBuilder(
            id: TaskID(rawValue: "rn.generate"),
            component: ComponentID(rawValue: "rn"))
        let spec: ArtifactReference<DirectoryArtifact> = try taskBuilder.output(
            "fb-react-native-spec",
            path: root.appending(".rn-build/generated/FBReactNativeSpec"),
            validation: .nonEmptyDirectory)
        let task = taskBuilder.build(
            inputs: [
                .file(root.appending("tools/generate-rn-spec.js")),
                .tree(root.appending("third-party/react-native/packages/react-native-codegen")),
                .dependencyOutput(builder.imageID),
            ],
            locks: [.checkout("rn")],
            operation: javascriptOperation(
                root: root,
                builder: builder,
                networkPolicy: .externalDisabled,
                command: [
                    "/opt/node/bin/node",
                    root.appending("tools/generate-rn-spec.js").string,
                ],
                environment: environment)
        )
        .addingDependencies([TaskID(rawValue: "rn.javascript-dependencies")])
        return GeneratedReactNativeSources(task: task, spec: spec)
    }

    package static func buildHermes(
        root: FilePath,
        environment: [String: String],
        target: NativeLinuxTarget,
        builder: NativeOCIConfiguration
    ) throws -> HermesArtifacts {
        let source = root.appending("third-party/hermes")
        let build = root.appending(".rn-build/\(target.identifier)/hermes")
        let combined = build.appending("libhermes_lean_combined.a")
        let hermesc = build.appending("bin/hermesc")
        let icuSource = root.appending(
            "../core/third-party/skia/third_party/externals/icu/source")
        let icuLibraryDirectory = root.appending(
            "../core/.skia-build/\(target.identifier)")
        let icuLibrary = icuLibraryDirectory.appending("libicu.a")
        let dependencies = [
            NativeBuilderTaskIDs.prepare,
            CoreTaskIDs.skia(target),
        ]
        let nativeInputs: [ArtifactInput] = [
            .dependencyOutput(builder.imageID),
            .dependencyOutput(icuLibrary),
            .tree(icuSource.appending("common")),
            .tree(icuSource.appending("i18n")),
        ]
        let cmakeArguments: [String] = []
        let ninjaEnvironment = environment
        var taskBuilder = TaskBuilder(
            id: TaskID(rawValue: "rn.hermes.\(target.identifier)"),
            component: ComponentID(rawValue: "rn"))
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
                .tree(source),
                .file(root.appending("../tools/merge-static-archives.sh")),
            ] + nativeInputs,
            locks: [.checkout("rn-native-\(target.identifier)")],
            operation: .sequence([
                nativeCMake(
                    source: source,
                    containerSource: "/src/third-party/hermes",
                    build: build,
                    containerBuild: "/build/\(target.identifier)/hermes",
                    arguments: [
                        "-DBUILD_SHARED_LIBS=OFF",
                        "-DHERMES_BUILD_SHARED_JSI=OFF",
                        "-DHERMES_BUILD_APPLE_FRAMEWORK=OFF",
                        "-DHERMES_ENABLE_DEBUGGER=OFF",
                        "-DHERMES_ENABLE_INTL=ON",
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
                nativeNinja(
                    build: build,
                    containerBuild: "/build/\(target.identifier)/hermes",
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
                nativeContainerOperation(
                    root: root,
                    builder: builder,
                    command: [
                        "/tools/merge-static-archives.sh",
                        "/build/\(target.identifier)/hermes",
                        "/build/\(target.identifier)/hermes/libhermes_lean_combined.a",
                        "libgtest",
                    ],
                    environment: environment,
                    target: target),
            ])
        ).addingDependencies(dependencies)
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
                .tree(root.appending("third-party/fmt")),
                .tree(
                    root.appending(
                        "third-party/double-conversion")),
            ] + nativeBuilderInputs(builder),
            locks: [.checkout("rn-native-\(target.identifier)")],
            operation: .sequence([
                nativeCMake(
                    source: root.appending("third-party/fmt"),
                    containerSource: "/src/third-party/fmt",
                    build: fmtBuild,
                    containerBuild: "/build/\(target.identifier)/fmt",
                    arguments: [
                        "-DFMT_TEST=OFF", "-DFMT_DOC=OFF", "-DFMT_INSTALL=OFF",
                    ],
                    root: root,
                    environment: environment,
                    target: target,
                    builder: builder),
                nativeNinja(
                    build: fmtBuild,
                    containerBuild: "/build/\(target.identifier)/fmt",
                    targets: ["fmt"],
                    root: root, environment: environment,
                    target: target,
                    builder: builder),
                nativeCMake(
                    source: root.appending("third-party/double-conversion"),
                    containerSource: "/src/third-party/double-conversion",
                    build: conversionBuild,
                    containerBuild: "/build/\(target.identifier)/double-conversion",
                    arguments: [
                        "-DCMAKE_POLICY_VERSION_MINIMUM=3.5",
                        "-DCMAKE_EXPORT_NO_PACKAGE_REGISTRY=ON",
                    ],
                    root: root,
                    environment: environment,
                    target: target,
                    builder: builder),
                nativeNinja(
                    build: conversionBuild,
                    containerBuild: "/build/\(target.identifier)/double-conversion",
                    targets: ["double-conversion"],
                    root: root, environment: environment,
                    target: target,
                    builder: builder),
            ])
        ).addingDependencies(nativeBuilderDependencies)
        return SupportLibraryArtifacts(
            task: task,
            libraries: [fmt, conversion])
    }

    package static func buildCxxRuntime(
        root: FilePath,
        environment: [String: String],
        target: NativeLinuxTarget,
        boost: ArtifactReference<PathArtifact>,
        generated: ArtifactReference<DirectoryArtifact>,
        hermes: HermesArtifacts,
        support: SupportLibraryArtifacts,
        builder: NativeOCIConfiguration
    ) throws -> CxxRuntimeArtifacts {
        let buildRoot = root.appending(".rn-build/\(target.identifier)")
        let glogBuild = buildRoot.appending("glog")
        let nativeBuild = buildRoot.appending("reactnative")
        let reactNative = root.appending(
            "third-party/react-native/packages/react-native")
        var taskBuilder = TaskBuilder(
            id: TaskID(rawValue: "rn.cxx.\(target.identifier)"),
            component: ComponentID(rawValue: "rn"))
        taskBuilder.consume(boost)
        taskBuilder.consume(generated)
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
                .tree(root.appending("third-party/glog")),
                .tree(root.appending("third-party/folly")),
                .tree(root.appending("third-party/fast_float")),
                .tree(root.appending("third-party/hermes")),
                .tree(reactNative.appending("ReactCommon")),
                .tree(root.appending("../core/swiftpm/cmake/reactnative")),
            ] + nativeBuilderInputs(builder),
            locks: [.checkout("rn-native-\(target.identifier)")],
            operation: .sequence([
                nativeCMake(
                    source: root.appending("third-party/glog"),
                    containerSource: "/src/third-party/glog",
                    build: glogBuild,
                    containerBuild: "/build/\(target.identifier)/glog",
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
                nativeNinja(
                    build: glogBuild,
                    containerBuild: "/build/\(target.identifier)/glog",
                    targets: ["glog"],
                    root: root, environment: environment,
                    target: target,
                    builder: builder),
                nativeCMake(
                    source: root.appending("../core/swiftpm/cmake/reactnative"),
                    containerSource: "/core-cmake",
                    build: nativeBuild,
                    containerBuild: "/build/\(target.identifier)/reactnative",
                    arguments: [
                        "-DFOLLY_DIR=\(nativePath(root.appending("third-party/folly"), "/src/third-party/folly"))",
                        "-DBOOST_INC=\(nativePath(root.appending(".rn-build/dependencies/boost/current"), "/build/dependencies/boost/current"))",
                        "-DGLOG_INC=\(nativePath(glogBuild, "/build/\(target.identifier)/glog"))",
                        "-DGLOG_SRC_INC=\(nativePath(root.appending("third-party/glog/src"), "/src/third-party/glog/src"))",
                        "-DDOUBLE_CONVERSION_INC=/dependencies/include",
                        "-DFMT_INC=\(nativePath(root.appending("third-party/fmt/include"), "/src/third-party/fmt/include"))",
                        "-DFAST_FLOAT_INC=\(nativePath(root.appending("third-party/fast_float/include"), "/src/third-party/fast_float/include"))",
                        "-DJSI_DIR=\(nativePath(reactNative.appending("ReactCommon/jsi"), "/src/third-party/react-native/packages/react-native/ReactCommon/jsi"))",
                        "-DRN_ROOT=\(nativePath(reactNative, "/src/third-party/react-native/packages/react-native"))",
                        "-DRN_CODEGEN_ROOT=\(nativePath(generated.path.removingLastComponent(), "/build/generated"))",
                        "-DHERMES_DIR=\(nativePath(root.appending("third-party/hermes"), "/src/third-party/hermes"))",
                    ],
                    root: root,
                    environment: environment,
                    target: target,
                    builder: builder),
                nativeNinja(
                    build: nativeBuild,
                    containerBuild: "/build/\(target.identifier)/reactnative",
                    targets: [
                        "folly_runtime", "jsi", "react_native",
                        "react_cxx_platform", "yogacore",
                    ],
                    root: root,
                    environment: environment,
                    target: target,
                    builder: builder),
            ])
        )
        return CxxRuntimeArtifacts(task: task, outputs: outputArtifacts)
    }

    package static func publishNativeSDK(
        root: FilePath,
        sdkRoot: FilePath,
        target: NativeLinuxTarget,
        runtime: CxxRuntimeArtifacts
    ) throws -> TaskDeclaration {
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
            ("include/rn-codegen", root.appending(".rn-build/generated")),
            ("include/fmt", root.appending("third-party/fmt")),
            ("include/fast_float", root.appending("third-party/fast_float")),
            (
                "include/double-conversion",
                root.appending("third-party/double-conversion/src")
            ),
            (
                "include/react-native",
                root.appending("third-party/react-native")
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
        for (name, _) in links {
            let _: ArtifactReference<PathArtifact> = try builder.output(
                OutputSlotID(rawValue: name),
                path: sdk.appending(name),
                validation: .symlinkTarget)
        }
        return builder.build(
            inputs: links.map {
                .value(
                    name: $0.0,
                    bytes: Array($0.1.string.utf8))
            },
            locks: [
                .shared(sdkRoot.appending(".rn.lock"))
            ],
            operation: .sequence(
                links.map {
                    .replaceSymlink(
                        path: sdk.appending($0.0),
                        target: $0.1.string)
                })
        ).addingDependencies([CoreTaskIDs.nativeSDK(target)])
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
            ])
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

private func javascriptOperation(
    root: FilePath,
    builder: NativeOCIConfiguration,
    networkPolicy: OCINetworkPolicy,
    command: [String],
    environment: [String: String]
) -> TaskOperation {
    .runOCI(
        OCIExecution(
            executionPlatform: .linuxARM64OCI,
            artifactTarget: .linuxARM64,
            imageID: builder.imageID,
            hostname: "react-native-javascript",
            workingDirectory: root.appending("third-party/react-native").string,
            hostWorkingDirectory: root,
            mounts: [
                OCIMount(source: root, target: root.string, access: .readWrite)
            ],
            networkPolicy: networkPolicy,
            userPolicy: .builder,
            capabilityPolicy: .dropAll,
            privilegePolicy: .prohibitAcquisition,
            processFilesystemPolicy: .standard,
            resourceLimits: .parallelBuild,
            containerEnvironment: [
                "HOME": "/home/nucleus-build",
                "PATH":
                    "/opt/node/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            ],
            command: ["javascript"] + command,
            environment: environment,
            output: .logged))
}

private let boostVersion = "1.84.0"
private let boostArchiveName = "boost_1_84_0.tar.gz"
private let boostArchiveSHA256 =
    "a5800f405508f5df8114558ca9855d2640a2de8f0445f051fa1c7c3383045724"

public enum ReactNativeRecipeFailure: Error, CustomStringConvertible {
    case invalidBoostSpecification

    public var description: String {
        switch self {
        case .invalidBoostSpecification:
            "the pinned Boost download specification is invalid"
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

private let nativeBuilderDependencies = [NativeBuilderTaskIDs.prepare]

private func nativeBuilderInputs(
    _ builder: NativeOCIConfiguration
) -> [ArtifactInput] {
    [
        .dependencyOutput(builder.imageID),
        .tree(builder.swiftSDKRoot),
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
) -> TaskOperation {
    _ = source
    _ = build
    return nativeContainerOperation(
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
) -> TaskOperation {
    _ = build
    return nativeContainerOperation(
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
) -> TaskOperation {
    .runOCI(
        OCIExecution(
            executionPlatform: .linuxARM64OCI,
            artifactTarget: target.artifactTarget,
            imageID: builder.imageID,
            hostname: "native-react-build",
            workingDirectory: "/src",
            hostWorkingDirectory: root,
            mounts: [
                OCIMount(
                    source: root,
                    target: "/src",
                    access: .readOnly),
                OCIMount(
                    source: root.appending(".rn-build"),
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
                    source: root.appending("third-party/double-conversion/src"),
                    target: "/dependencies/include/double-conversion",
                    access: .readOnly),
                OCIMount(
                    source: builder.ccache,
                    target: "/ccache",
                    access: .readWrite),
                OCIMount(
                    source: builder.swiftSDKRoot,
                    target: "/swift-sdk",
                    access: .readOnly),
            ] + additionalMounts,
            networkPolicy: .externalDisabled,
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
            output: .logged))
}
