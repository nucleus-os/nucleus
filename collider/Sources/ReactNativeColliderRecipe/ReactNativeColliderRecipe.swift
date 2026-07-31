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
            environment: environment)
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
            operation: .runSwiftTest(
                SwiftTestExecution(
                    requirement: requirement)))
    }

    public static func installJavaScriptDependencies(
        root: FilePath,
        environment: [String: String]
    ) -> TaskDeclaration {
        TaskDeclaration(
            id: TaskID(rawValue: "rn.javascript-dependencies"),
            component: ComponentID(rawValue: "rn"),
            inputs: [
                .file(
                    root.appending(
                        "third-party/react-native/yarn.lock")),
                .file(
                    root.appending(
                        "third-party/react-native/package.json")),
                .tool(.named("corepack")),
            ],
            outputs: [
                OutputDeclaration(
                    path: root.appending(
                        "third-party/react-native/node_modules"),
                    validation: .nonEmptyDirectory)
            ],
            locks: [.checkout("rn-javascript")],
            operation: .command(
                CommandSpec(
                    executable: .named("corepack"),
                    arguments: [
                        "yarn", "--cwd", "third-party/react-native",
                        "install", "--frozen-lockfile",
                    ],
                    workingDirectory: root,
                    environment: environment)))
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
                OutputDeclaration(path: active, validation: .exists),
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

    public static func generate(root: FilePath, environment: [String: String]) -> TaskDeclaration {
        TaskDeclaration(
            id: TaskID(rawValue: "rn.generate"),
            component: ComponentID(rawValue: "rn"),
            dependencies: [TaskID(rawValue: "rn.javascript-dependencies")],
            inputs: [
                .file(root.appending("tools/generate-rn-spec.js")),
                .tree(root.appending("third-party/react-native/packages/react-native-codegen")),
                .tool(.named("node")),
            ],
            outputs: [
                OutputDeclaration(
                    path: root.appending(".rn-build/generated/FBReactNativeSpec"),
                    validation: .nonEmptyDirectory)
            ],
            locks: [.checkout("rn")],
            operation: .command(
                CommandSpec(
                    executable: .named("node"),
                    arguments: [root.appending("tools/generate-rn-spec.js").string],
                    workingDirectory: root,
                    environment: environment)))
    }

    public static func buildHermes(
        root: FilePath,
        environment: [String: String],
        builder: NativeBuildContainerConfiguration,
        host: HermesHostDependencies?
    ) -> TaskDeclaration {
        let source = root.appending("third-party/hermes")
        let build = root.appending(".rn-build/hermes")
        let combined = build.appending("libhermes_lean_combined.a")
        let hermesc = build.appending("bin/hermesc")
        #if os(macOS)
        let host = host!
        let dependencies = [TaskID]()
        let nativeInputs: [ArtifactInput] = [
            .tree(host.icuIncludeDirectory),
            .file(host.icuUCLibrary),
            .file(host.icuI18NLibrary),
            .file(host.icuDataLibrary),
            .file(host.cxxRuntimeLibrary),
            .tool(.named("cmake")),
            .tool(.named("ninja")),
            .tool(.named("ccache")),
        ]
        let cmakeArguments = [
            "-DICU_INCLUDE_DIR=\(host.icuIncludeDirectory)",
            "-DICU_UC_LIBRARY_RELEASE=\(host.icuUCLibrary)",
            "-DICU_I18N_LIBRARY_RELEASE=\(host.icuI18NLibrary)",
            "-DICU_DATA_LIBRARY_RELEASE=\(host.icuDataLibrary)",
            "-DICU_ROOT=\(host.icuIncludeDirectory.removingLastComponent())",
        ]
        let ninjaEnvironment = environment.merging([
            "LD_LIBRARY_PATH": host.cxxRuntimeLibrary
                .removingLastComponent().string
        ]) { _, required in required }
        #else
        let dependencies = [TaskID(rawValue: "native.builder")]
        let nativeInputs: [ArtifactInput] = [
            .dependencyOutput(builder.imageID),
            .tool(.named("podman")),
        ]
        let cmakeArguments: [String] = []
        let ninjaEnvironment = environment
        #endif
        return TaskDeclaration(
            id: TaskID(rawValue: "rn.hermes"),
            component: ComponentID(rawValue: "rn"),
            dependencies: dependencies,
            inputs: [
                .tree(source),
                .tool(.named("ar")),
                .tool(.named("ranlib")),
            ] + nativeInputs,
            outputs: [
                OutputDeclaration(path: combined, validation: .regularFile),
                OutputDeclaration(path: hermesc, validation: .executableFile),
            ],
            locks: [.checkout("rn-native")],
            operation: .sequence([
                nativeCMake(
                    source: source,
                    containerSource: "/src/third-party/hermes",
                    build: build,
                    containerBuild: "/build/hermes",
                    arguments: [
                        "-DBUILD_SHARED_LIBS=OFF",
                        "-DHERMES_BUILD_SHARED_JSI=OFF",
                        "-DHERMES_BUILD_APPLE_FRAMEWORK=OFF",
                        "-DHERMES_ENABLE_DEBUGGER=OFF",
                        "-DHERMES_ENABLE_INTL=ON",
                    ] + cmakeArguments,
                    root: root,
                    environment: environment,
                    builder: builder),
                nativeNinja(
                    build: build,
                    containerBuild: "/build/hermes",
                    targets: ["hermesvmlean", "jsi", "hermesc"],
                    root: root,
                    environment: ninjaEnvironment,
                    builder: builder),
                .mergeStaticArchives(
                    StaticArchiveMerge(
                        sourceRoot: build,
                        output: combined,
                        excludedFilePrefixes: ["libgtest"],
                        environment: environment)),
            ]))
    }

    public static func buildSupportLibraries(
        root: FilePath,
        environment: [String: String],
        builder: NativeBuildContainerConfiguration
    ) -> TaskDeclaration {
        let fmtBuild = root.appending(".rn-build/fmt")
        let conversionBuild = root.appending(".rn-build/double-conversion")
        return TaskDeclaration(
            id: TaskID(rawValue: "rn.support"),
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
            locks: [.checkout("rn-native")],
            operation: .sequence([
                nativeCMake(
                    source: root.appending("third-party/fmt"),
                    containerSource: "/src/third-party/fmt",
                    build: fmtBuild,
                    containerBuild: "/build/fmt",
                    arguments: [
                        "-DFMT_TEST=OFF", "-DFMT_DOC=OFF", "-DFMT_INSTALL=OFF",
                    ],
                    root: root,
                    environment: environment,
                    builder: builder),
                nativeNinja(
                    build: fmtBuild,
                    containerBuild: "/build/fmt",
                    targets: ["fmt"],
                    root: root, environment: environment,
                    builder: builder),
                nativeCMake(
                    source: root.appending("third-party/double-conversion"),
                    containerSource: "/src/third-party/double-conversion",
                    build: conversionBuild,
                    containerBuild: "/build/double-conversion",
                    arguments: [
                        "-DCMAKE_POLICY_VERSION_MINIMUM=3.5",
                        "-DCMAKE_EXPORT_NO_PACKAGE_REGISTRY=ON",
                    ],
                    root: root,
                    environment: environment,
                    builder: builder),
                nativeNinja(
                    build: conversionBuild,
                    containerBuild: "/build/double-conversion",
                    targets: ["double-conversion"],
                    root: root, environment: environment,
                    builder: builder),
            ]))
    }

    public static func buildCxxRuntime(
        root: FilePath,
        environment: [String: String],
        builder: NativeBuildContainerConfiguration
    ) -> TaskDeclaration {
        let glogBuild = root.appending(".rn-build/glog")
        let nativeBuild = root.appending(".rn-build/reactnative")
        let includeRoot = root.appending(".rn-build/include")
        let reactNative = root.appending(
            "third-party/react-native/packages/react-native")
        return TaskDeclaration(
            id: TaskID(rawValue: "rn.cxx"),
            component: ComponentID(rawValue: "rn"),
            dependencies: [
                TaskID(rawValue: "rn.support"),
                TaskID(rawValue: "rn.generate"),
                TaskID(rawValue: "rn.boost"),
                TaskID(rawValue: "rn.hermes"),
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
            locks: [.checkout("rn-native")],
            operation: .sequence([
                .replaceSymlink(
                    path: includeRoot.appending("double-conversion"),
                    target: "../../third-party/double-conversion/src"),
                nativeCMake(
                    source: root.appending("third-party/glog"),
                    containerSource: "/src/third-party/glog",
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
                    builder: builder),
                nativeNinja(
                    build: glogBuild,
                    containerBuild: "/build/glog",
                    targets: ["glog"],
                    root: root, environment: environment,
                    builder: builder),
                nativeCMake(
                    source: root.appending("../core/swiftpm/cmake/reactnative"),
                    containerSource: "/core-cmake",
                    build: nativeBuild,
                    containerBuild: "/build/reactnative",
                    arguments: [
                        "-DFOLLY_DIR=\(nativePath(root.appending("third-party/folly"), "/src/third-party/folly"))",
                        "-DBOOST_INC=\(nativePath(root.appending(".rn-build/dependencies/boost/current"), "/build/dependencies/boost/current"))",
                        "-DGLOG_INC=\(nativePath(glogBuild, "/build/glog"))",
                        "-DGLOG_SRC_INC=\(nativePath(root.appending("third-party/glog/src"), "/src/third-party/glog/src"))",
                        "-DDOUBLE_CONVERSION_INC=\(nativePath(includeRoot, "/include"))",
                        "-DFMT_INC=\(nativePath(root.appending("third-party/fmt/include"), "/src/third-party/fmt/include"))",
                        "-DFAST_FLOAT_INC=\(nativePath(root.appending("third-party/fast_float/include"), "/src/third-party/fast_float/include"))",
                        "-DJSI_DIR=\(nativePath(reactNative.appending("ReactCommon/jsi"), "/src/third-party/react-native/packages/react-native/ReactCommon/jsi"))",
                        "-DRN_ROOT=\(nativePath(reactNative, "/src/third-party/react-native/packages/react-native"))",
                        "-DRN_CODEGEN_ROOT=\(nativePath(root.appending(".rn-build/generated"), "/build/generated"))",
                        "-DHERMES_DIR=\(nativePath(root.appending("third-party/hermes"), "/src/third-party/hermes"))",
                    ],
                    root: root,
                    environment: environment,
                    builder: builder),
                nativeNinja(
                    build: nativeBuild,
                    containerBuild: "/build/reactnative",
                    targets: [
                        "folly_runtime", "jsi", "react_native",
                        "react_cxx_platform", "yogacore",
                    ],
                    root: root,
                    environment: environment,
                    builder: builder),
            ]))
    }

    public static func stageHostArchive(
        root: FilePath,
        swiftPM: SwiftPMInvocation
    ) throws -> TaskDeclaration {
        let configuration = swiftPM.context.configuration.rawValue
        let archive = "libNucleusReactRuntimeHostCxx.a"
        let products = swiftPM.productsRoot
        let prefix =
            configuration.prefix(1).uppercased()
            + String(configuration.dropFirst())
        let destination = root.appending(
            ".cxx-build/\(configuration)/\(archive)")
        return TaskDeclaration(
            id: TaskID(rawValue: "rn.host-archive.\(configuration)"),
            component: ComponentID(rawValue: "rn"),
            inputs: [
                swiftPM.identityInput,
                .dependencyOutput(products),
            ],
            outputs: [
                OutputDeclaration(
                    path: destination,
                    validation: .regularFile)
            ],
            locks: [.checkout("rn-host-archive")],
            operation: .copyMatchingFile(
                MatchingFileCopy(
                    searchDirectory: products,
                    childDirectoryPrefix: prefix + "-",
                    fileName: archive,
                    destination: destination)))
    }

    public static func buildSwiftCxxFacade(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> TaskDeclaration {
        TaskDeclaration(
            id: TaskID(rawValue: "rn.swift-cxx"),
            component: ComponentID(rawValue: "rn"),
            dependencies: [TaskID(rawValue: "rn.cxx")],
            swiftProducts: [
                swiftPM.product(
                    package: "react-native",
                    product: "NucleusReactRuntimeCxx",
                    packageRoot: root,
                    environment: environment)
            ],
            inputs: [
                .tree(root.appending("swift")),
                swiftPM.identityInput,
                .tool(.named("swift")),
            ],
            postconditions: [
                swiftPM.postcondition,
                PathPostcondition(
                    path: swiftPM.generatedSwiftHeader(
                        "NucleusReactRuntimeCxx"),
                    validation: .regularFile),
            ],
            locks: [.checkout("rn-swift")],
            operation: .sequence([]))
    }

    public static func buildSwiftHostCxx(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> TaskDeclaration {
        TaskDeclaration(
            id: TaskID(rawValue: "rn.swift-host-cxx"),
            component: ComponentID(rawValue: "rn"),
            dependencies: [TaskID(rawValue: "rn.swift-cxx")],
            swiftProducts: [
                swiftPM.product(
                    package: "react-native",
                    product: "NucleusReactRuntimeHostCxx",
                    packageRoot: root,
                    environment: environment)
            ],
            inputs: [
                .tree(root.appending("swift")),
                swiftPM.identityInput,
                .tool(.named("swift")),
            ],
            postconditions: [swiftPM.postcondition],
            locks: [.checkout("rn-swift")],
            operation: .sequence([]))
    }

    public static func publishNativeSDK(
        root: FilePath,
        sdkRoot: FilePath
    ) -> TaskDeclaration {
        let sdk = sdkRoot.appending("rn")
        let links: [(String, FilePath)] = [
            ("include/hermes", root.appending("third-party/hermes")),
            ("include/folly", root.appending("third-party/folly")),
            (
                "include/boost",
                root.appending(".rn-build/dependencies/boost/current")
            ),
            ("include/glog", root.appending("third-party/glog")),
            ("include/glog-gen", root.appending(".rn-build/glog")),
            ("include/rn-gen", root.appending(".rn-build/include")),
            ("include/rn-codegen", root.appending(".rn-build/generated")),
            ("include/fmt", root.appending("third-party/fmt")),
            ("include/fast_float", root.appending("third-party/fast_float")),
            (
                "include/react-native",
                root.appending("third-party/react-native")
            ),
            ("lib/rn", root.appending(".rn-build")),
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
            id: TaskID(rawValue: "rn.native-sdk"),
            component: ComponentID(rawValue: "rn"),
            dependencies: [
                TaskID(rawValue: "core.native-sdk"),
                TaskID(rawValue: "rn.cxx"),
            ],
            inputs: links.map {
                .value(
                    name: $0.0,
                    bytes: Array($0.1.string.utf8))
            },
            outputs: links.map {
                OutputDeclaration(
                    path: sdk.appending($0.0),
                    validation: .exists)
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

    public static func publishHostArchiveSDK(
        root: FilePath,
        sdkRoot: FilePath,
        hostArchive: TaskID
    ) -> TaskDeclaration {
        let path = sdkRoot.appending("rn/lib/nucleus-cxx-libs")
        return TaskDeclaration(
            id: TaskID(rawValue: "rn.host-archive-sdk"),
            component: ComponentID(rawValue: "rn"),
            dependencies: [
                TaskID(rawValue: "rn.native-sdk"),
                hostArchive,
            ],
            inputs: [
                .value(
                    name: "host-archive-root",
                    bytes: Array(root.appending(".cxx-build").string.utf8))
            ],
            outputs: [
                OutputDeclaration(path: path, validation: .exists)
            ],
            locks: [.shared(sdkRoot.appending(".rn.lock"))],
            operation: .replaceSymlink(
                path: path,
                target: root.appending(".cxx-build").string))
    }
}

private let boostVersion = "1.84.0"
private let boostArchiveName = "boost_1_84_0.tar.gz"
private let boostArchiveSHA256 =
    "a5800f405508f5df8114558ca9855d2640a2de8f0445f051fa1c7c3383045724"

public struct HermesHostDependencies: Hashable, Sendable {
    public let icuIncludeDirectory: FilePath
    public let icuUCLibrary: FilePath
    public let icuI18NLibrary: FilePath
    public let icuDataLibrary: FilePath
    public let cxxRuntimeLibrary: FilePath

    public init(
        icuIncludeDirectory: FilePath,
        icuUCLibrary: FilePath,
        icuI18NLibrary: FilePath,
        icuDataLibrary: FilePath,
        cxxRuntimeLibrary: FilePath
    ) {
        self.icuIncludeDirectory = icuIncludeDirectory
        self.icuUCLibrary = icuUCLibrary
        self.icuI18NLibrary = icuI18NLibrary
        self.icuDataLibrary = icuDataLibrary
        self.cxxRuntimeLibrary = cxxRuntimeLibrary
    }
}

public enum ReactNativeRecipeFailure: Error, CustomStringConvertible {
    case invalidBoostSpecification

    public var description: String {
        switch self {
        case .invalidBoostSpecification:
            "the pinned Boost download specification is invalid"
        }
    }
}

private let commonCMakeArguments = [
    "-G", "Ninja",
    "-DCMAKE_BUILD_TYPE=Release",
    "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
    "-DCMAKE_C_COMPILER=clang",
    "-DCMAKE_CXX_COMPILER=clang++",
    "-DCMAKE_CXX_FLAGS=-stdlib=libc++",
    "-DCMAKE_C_COMPILER_LAUNCHER=ccache",
    "-DCMAKE_CXX_COMPILER_LAUNCHER=ccache",
]

#if os(macOS)
private let nativeBuilderDependencies: [TaskID] = []

private func nativeBuilderInputs(
    _ builder: NativeBuildContainerConfiguration
) -> [ArtifactInput] {
    [
        .tool(.named("cmake")),
        .tool(.named("ninja")),
        .tool(.named("ccache")),
    ]
}

private func nativePath(_ host: FilePath, _ container: String) -> String {
    host.string
}
#else
private let nativeBuilderDependencies = [TaskID(rawValue: "native.builder")]

private func nativeBuilderInputs(
    _ builder: NativeBuildContainerConfiguration
) -> [ArtifactInput] {
    [
        .dependencyOutput(builder.imageID),
        .tool(.named("podman")),
    ]
}

private func nativePath(_ host: FilePath, _ container: String) -> String {
    container
}
#endif

private func nativeCMake(
    source: FilePath,
    containerSource: String,
    build: FilePath,
    containerBuild: String,
    arguments: [String],
    root: FilePath,
    environment: [String: String],
    builder: NativeBuildContainerConfiguration
) -> TaskOperation {
    #if os(macOS)
    cmake(
        source: source,
        build: build,
        arguments: arguments,
        root: root,
        environment: environment)
    #else
    nativeContainerOperation(
        root: root,
        builder: builder,
        command: [
            "cmake",
            "-S", containerSource,
            "-B", containerBuild,
        ] + commonCMakeArguments + arguments,
        environment: environment)
    #endif
}

private func nativeNinja(
    build: FilePath,
    containerBuild: String,
    targets: [String],
    root: FilePath,
    environment: [String: String],
    builder: NativeBuildContainerConfiguration
) -> TaskOperation {
    #if os(macOS)
    ninja(
        build: build,
        targets: targets,
        root: root,
        environment: environment)
    #else
    nativeContainerOperation(
        root: root,
        builder: builder,
        command: ["ninja", "-C", containerBuild] + targets,
        environment: environment)
    #endif
}

#if !os(macOS)
private func nativeContainerOperation(
    root: FilePath,
    builder: NativeBuildContainerConfiguration,
    command: [String],
    environment: [String: String]
) -> TaskOperation {
    .runBuildContainer(
        BuildContainerExecution(
            imageID: builder.imageID,
            hostname: "native-react-build",
            workingDirectory: "/src",
            hostWorkingDirectory: root,
            mounts: [
                BuildContainerMount(
                    source: root,
                    target: "/src",
                    access: .readOnly),
                BuildContainerMount(
                    source: root.appending(".rn-build"),
                    target: "/build",
                    access: .readWrite),
                BuildContainerMount(
                    source: root.appending("../core/swiftpm/cmake/reactnative"),
                    target: "/core-cmake",
                    access: .readOnly),
                BuildContainerMount(
                    source: root.appending("third-party/double-conversion/src"),
                    target: "/include/double-conversion",
                    access: .readOnly),
                BuildContainerMount(
                    source: builder.ccache,
                    target: "/ccache",
                    access: .readWrite),
            ],
            containerEnvironment: [:],
            command: ["react-native"] + command,
            environment: environment))
}
#endif

private func cmake(
    source: FilePath,
    build: FilePath,
    arguments: [String],
    root: FilePath,
    environment: [String: String]
) -> TaskOperation {
    .command(
        CommandSpec(
            executable: .named("cmake"),
            arguments: [
                "--fresh",
                "-S", source.string,
                "-B", build.string,
            ] + commonCMakeArguments + arguments,
            workingDirectory: root,
            environment: environment))
}

private func ninja(
    build: FilePath,
    targets: [String],
    root: FilePath,
    environment: [String: String]
) -> TaskOperation {
    .command(
        CommandSpec(
            executable: .named("ninja"),
            arguments: ["-C", build.string] + targets,
            workingDirectory: root,
            environment: environment))
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
                    environment: environment)
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
