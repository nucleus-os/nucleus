import ColliderCore
import Foundation
import SystemPackage

public enum ReactNativeColliderRecipe {
    public static func build(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> TaskDeclaration {
        task(
            "rn.build", root, environment, ["build"],
            [TaskID(rawValue: "linux.build")], swiftPM,
            prebuildTargets: ["NucleusReactRuntimeCxx"])
    }

    public static func test(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> TaskDeclaration {
        let requirement = swiftPM.testProduct(
            package: "react-native",
            testProduct: "NucleusReactNativePackageTests",
            packageRoot: root,
            environment: environment,
            expectedBuildOutputs: [
                PathPostcondition(
                    path: swiftPM.generatedSwiftHeader("NucleusReactRuntimeCxx"),
                    validation: .regularFile)
            ])
        return TaskDeclaration(
            id: TaskID(rawValue: "rn.test"),
            component: ComponentID(rawValue: "rn"),
            dependencies: [TaskID(rawValue: "rn.build")],
            subsumedDependencies: [TaskID(rawValue: "rn.build")],
            swiftTests: [requirement],
            postconditions: [
                PathPostcondition(
                    path: swiftPM.generatedSwiftHeader(
                        "NucleusReactRuntimeCxx"),
                    validation: .regularFile)
            ],
            locks: [.checkout("rn")],
            cachePolicy: .always,
            operation: .sequence([]))
    }

    public static func installJavaScriptDependencies(
        root: FilePath,
        environment: [String: String],
        builder: NativeOCIConfiguration
    ) -> TaskDeclaration {
        TaskDeclaration(
            id: TaskID(rawValue: "rn.javascript-dependencies"),
            component: ComponentID(rawValue: "rn"),
            dependencies: [TaskID(rawValue: "native.builder")],
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

    public static func provisionBoost(
        root: FilePath,
        environment: [String: String]
    ) throws -> TaskDeclaration {
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
        return TaskDeclaration(
            id: TaskID(rawValue: "rn.boost"),
            component: ComponentID(rawValue: "rn"),
            inputs: [
                .value(
                    name: "boost-version",
                    bytes: Array(boostVersion.utf8)),
                .tool(.named("tar")),
            ],
            outputs: [
                OutputDeclaration(
                    path: generation.appending("version.hpp"),
                    validation: .regularFile),
                OutputDeclaration(path: active, validation: .symlinkTarget),
            ],
            locks: [.checkout("rn-boost")],
            operation: .sequence([
                .download(download, candidate: archive),
                .removePath(candidate),
                .createDirectory(candidate),
                .command(
                    CommandSpec(
                        executable: .named("tar"),
                        arguments: [
                            "xzf", archive.string,
                            "--strip-components=2",
                            "-C", candidate.string,
                            "boost_1_84_0/boost",
                        ],
                        workingDirectory: root,
                        environment: environment)),
                .replaceSymlink(
                    path: candidate.appending("boost"),
                    target: "."),
                .activateGeneration(
                    candidate: candidate,
                    generation: generation,
                    active: active),
            ]))
    }

    public static func generate(
        root: FilePath,
        environment: [String: String],
        builder: NativeOCIConfiguration
    ) -> TaskDeclaration {
        TaskDeclaration(
            id: TaskID(rawValue: "rn.generate"),
            component: ComponentID(rawValue: "rn"),
            dependencies: [TaskID(rawValue: "rn.javascript-dependencies")],
            inputs: [
                .file(root.appending("tools/generate-rn-spec.js")),
                .tree(root.appending("third-party/react-native/packages/react-native-codegen")),
                .dependencyOutput(builder.imageID),
            ],
            outputs: [
                OutputDeclaration(
                    path: root.appending(".rn-build/generated/FBReactNativeSpec"),
                    validation: .nonEmptyDirectory)
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
                environment: environment))
    }

    public static func buildHermes(
        root: FilePath,
        environment: [String: String],
        target: NativeLinuxTarget,
        builder: NativeOCIConfiguration
    ) -> TaskDeclaration {
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
            TaskID(rawValue: "native.builder"),
            TaskID(rawValue: "core.skia.\(target.identifier)"),
        ]
        let nativeInputs: [ArtifactInput] = [
            .dependencyOutput(builder.imageID),
            .dependencyOutput(icuLibrary),
            .tree(icuSource.appending("common")),
            .tree(icuSource.appending("i18n")),
        ]
        let cmakeArguments: [String] = []
        let ninjaEnvironment = environment
        return TaskDeclaration(
            id: TaskID(rawValue: "rn.hermes.\(target.identifier)"),
            component: ComponentID(rawValue: "rn"),
            dependencies: dependencies,
            inputs: [
                .tree(source),
                .file(root.appending("../tools/merge-static-archives.sh")),
            ] + nativeInputs,
            outputs: [
                OutputDeclaration(path: combined, validation: .regularFile),
                OutputDeclaration(path: hermesc, validation: .executableFile),
            ],
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
            ]))
    }

    public static func buildSupportLibraries(
        root: FilePath,
        environment: [String: String],
        target: NativeLinuxTarget,
        builder: NativeOCIConfiguration
    ) -> TaskDeclaration {
        let buildRoot = root.appending(".rn-build/\(target.identifier)")
        let fmtBuild = buildRoot.appending("fmt")
        let conversionBuild = buildRoot.appending("double-conversion")
        return TaskDeclaration(
            id: TaskID(rawValue: "rn.support.\(target.identifier)"),
            component: ComponentID(rawValue: "rn"),
            dependencies: nativeBuilderDependencies,
            inputs: [
                .tree(root.appending("third-party/fmt")),
                .tree(
                    root.appending(
                        "third-party/double-conversion")),
            ] + nativeBuilderInputs(builder),
            outputs: [
                OutputDeclaration(
                    path: fmtBuild.appending("libfmt.a"),
                    validation: .regularFile),
                OutputDeclaration(
                    path: conversionBuild.appending(
                        "src/libdouble-conversion.a"),
                    validation: .regularFile),
            ],
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
            ]))
    }

    public static func buildCxxRuntime(
        root: FilePath,
        environment: [String: String],
        target: NativeLinuxTarget,
        builder: NativeOCIConfiguration
    ) -> TaskDeclaration {
        let buildRoot = root.appending(".rn-build/\(target.identifier)")
        let glogBuild = buildRoot.appending("glog")
        let nativeBuild = buildRoot.appending("reactnative")
        let reactNative = root.appending(
            "third-party/react-native/packages/react-native")
        return TaskDeclaration(
            id: TaskID(rawValue: "rn.cxx.\(target.identifier)"),
            component: ComponentID(rawValue: "rn"),
            dependencies: [
                TaskID(rawValue: "rn.support.\(target.identifier)"),
                TaskID(rawValue: "rn.generate"),
                TaskID(rawValue: "rn.boost"),
                TaskID(rawValue: "rn.hermes.\(target.identifier)"),
            ],
            inputs: [
                .tree(root.appending("third-party/glog")),
                .tree(root.appending("third-party/folly")),
                .tree(root.appending("third-party/fast_float")),
                .dependencyOutput(
                    root.appending(".rn-build/dependencies/boost/current")),
                .tree(root.appending("third-party/hermes")),
                .tree(reactNative.appending("ReactCommon")),
                .dependencyOutput(root.appending(".rn-build/generated")),
                .tree(root.appending("../core/swiftpm/cmake/reactnative")),
            ] + nativeBuilderInputs(builder),
            outputs: [
                OutputDeclaration(
                    path: glogBuild.appending("libglog.a"),
                    validation: .regularFile),
                OutputDeclaration(
                    path: glogBuild.appending("glog/logging.h"),
                    validation: .regularFile),
            ]
                + [
                    "libfolly_runtime.a", "libjsi.a", "libreact_native.a",
                    "libreact_cxx_platform.a", "libyogacore.a",
                ].map {
                    OutputDeclaration(
                        path: nativeBuild.appending($0),
                        validation: .regularFile)
                },
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
                        "-DRN_CODEGEN_ROOT=\(nativePath(root.appending(".rn-build/generated"), "/build/generated"))",
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
            ]))
    }

    public static func publishNativeSDK(
        root: FilePath,
        sdkRoot: FilePath,
        target: NativeLinuxTarget
    ) -> TaskDeclaration {
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
        return TaskDeclaration(
            id: TaskID(rawValue: "rn.native-sdk.\(target.identifier)"),
            component: ComponentID(rawValue: "rn"),
            dependencies: [
                TaskID(rawValue: "core.native-sdk.\(target.identifier)"),
                TaskID(rawValue: "rn.cxx.\(target.identifier)"),
            ],
            inputs: links.map {
                .value(
                    name: $0.0,
                    bytes: Array($0.1.string.utf8))
            },
            outputs: links.map {
                OutputDeclaration(
                    path: sdk.appending($0.0),
                    validation: .symlinkTarget)
            },
            locks: [
                .shared(sdkRoot.appending(".rn.lock"))
            ],
            operation: .sequence(
                links.map {
                    .replaceSymlink(
                        path: sdk.appending($0.0),
                        target: $0.1.string)
                }))
    }

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

private let nativeBuilderDependencies = [TaskID(rawValue: "native.builder")]

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

private func task(
    _ id: String,
    _ root: FilePath,
    _ environment: [String: String],
    _ arguments: [String],
    _ dependencies: [TaskID],
    _ swiftPM: SwiftPMInvocation,
    subsumedDependencies: [TaskID] = [],
    prebuildTargets: [String] = []
) -> TaskDeclaration {
    let isBuild = arguments == ["build"]
    return TaskDeclaration(
        id: TaskID(rawValue: id),
        component: ComponentID(rawValue: "rn"),
        dependencies: dependencies,
        subsumedDependencies: subsumedDependencies,
        swiftProducts: isBuild
            ? [
                swiftPM.product(
                    package: "react-native",
                    product: "NucleusReactRuntime",
                    packageRoot: root,
                    environment: environment,
                    prebuildTargets: prebuildTargets,
                    expectedOutputs: prebuildTargets.map {
                        PathPostcondition(
                            path: swiftPM.generatedSwiftHeader($0),
                            validation: .regularFile)
                    })
            ] : [],
        inputs: [
            .tree(root.appending("Sources")),
            .tree(root.appending("swift")),
            swiftPM.identityInput,
            .tool(.named("swift")),
        ],
        postconditions: [swiftPM.postcondition]
            + prebuildTargets.map {
                PathPostcondition(
                    path: swiftPM.generatedSwiftHeader($0),
                    validation: .regularFile)
            },
        locks: [.checkout("rn")] + (isBuild ? [] : [swiftPM.lock]),
        operation: isBuild
            ? .sequence([])
            : .command(
                swiftPM.command(
                    arguments: arguments,
                    workingDirectory: root,
                    environment: environment)))
}
