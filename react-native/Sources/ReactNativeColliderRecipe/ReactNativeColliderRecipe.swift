import ColliderCore
import Foundation
import SystemPackage

public enum ReactNativeColliderRecipe {
    public static func build(root: FilePath, environment: [String: String]) -> TaskDeclaration { task("rn.build", root, environment, ["build"], [TaskID(rawValue: "linux.build")]) }
    public static func test(root: FilePath, environment: [String: String]) -> TaskDeclaration { task("rn.test", root, environment, ["test"], [TaskID(rawValue: "rn.build")]) }
    public static func synchronizeSources(
        root: FilePath,
        repositoryRoot: FilePath,
        sourceIdentity: [UInt8],
        environment: [String: String]
    ) -> TaskDeclaration {
        let sourceDirectories = [
            "double-conversion", "fast_float", "fmt", "folly", "glog",
            "hermes", "react-native",
        ].map { root.appending("third-party/\($0)") }
        return TaskDeclaration(
            id: TaskID(rawValue: "rn.sources"),
            component: ComponentID(rawValue: "rn"),
            inputs: [
                .file(repositoryRoot.appending(".gitmodules")),
                .tool(.named("git")),
            ] + sourceDirectories.map {
                .optionalTree($0, fallback: sourceIdentity)
            },
            outputs: [
                OutputDeclaration(
                    path: root.appending("third-party/hermes/CMakeLists.txt"),
                    validation: .regularFile),
                OutputDeclaration(
                    path: root.appending(
                        "third-party/react-native/package.json"),
                    validation: .regularFile),
            ],
            locks: [.checkout("rn-sources")],
            operation: .command(CommandSpec(
                executable: .named("git"),
                arguments: [
                    "submodule", "update", "--init", "--recursive",
                    "react-native/third-party",
                ],
                workingDirectory: repositoryRoot,
                environment: environment)))
    }

    public static func installJavaScriptDependencies(
        root: FilePath,
        environment: [String: String]
    ) -> TaskDeclaration {
        TaskDeclaration(
            id: TaskID(rawValue: "rn.javascript-dependencies"),
            component: ComponentID(rawValue: "rn"),
            dependencies: [TaskID(rawValue: "rn.sources")],
            inputs: [
                .file(root.appending(
                    "third-party/react-native/yarn.lock")),
                .file(root.appending(
                    "third-party/react-native/package.json")),
                .tool(.named("corepack")),
            ],
            outputs: [
                OutputDeclaration(
                    path: root.appending(
                        "third-party/react-native/node_modules"),
                    validation: .nonEmptyDirectory),
            ],
            locks: [.checkout("rn-javascript")],
            operation: .command(CommandSpec(
                executable: .named("corepack"),
                arguments: [
                    "yarn", "--cwd", "third-party/react-native",
                    "install", "--frozen-lockfile",
                ],
                workingDirectory: root,
                environment: environment)))
    }

    public static func generateStrictTypes(
        root: FilePath,
        environment: [String: String]
    ) -> TaskDeclaration {
        TaskDeclaration(
            id: TaskID(rawValue: "rn.types"),
            component: ComponentID(rawValue: "rn"),
            dependencies: [
                TaskID(rawValue: "rn.javascript-dependencies"),
            ],
            inputs: [
                .tree(root.appending(
                    "third-party/react-native/packages/react-native")),
                .tool(.named("corepack")),
            ],
            outputs: [
                OutputDeclaration(
                    path: root.appending(
                        "third-party/react-native/packages/react-native/types_generated/index.d.ts"),
                    validation: .regularFile),
            ],
            locks: [.checkout("rn-types")],
            operation: .command(CommandSpec(
                executable: .named("corepack"),
                arguments: [
                    "yarn", "--cwd", "third-party/react-native",
                    "build-types",
                ],
                workingDirectory: root,
                environment: environment)))
    }

    public static func provisionBoost(
        root: FilePath,
        environment: [String: String]
    ) throws -> TaskDeclaration {
        guard let digest = ArtifactDigest(sha256Hex: boostArchiveSHA256),
              let url = URL(string:
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
        let generations = root.appending("third-party/.boost-generations")
        let candidate = generations.appending(
            ".candidate-\(boostArchiveSHA256)")
        let generation = generations.appending(boostArchiveSHA256)
        let active = root.appending("third-party/boost")
        return TaskDeclaration(
            id: TaskID(rawValue: "rn.boost"),
            component: ComponentID(rawValue: "rn"),
            dependencies: [TaskID(rawValue: "rn.sources")],
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
                .command(CommandSpec(
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
            dependencies: [TaskID(rawValue: "rn.types")],
            inputs: [
                .file(root.appending("Package.swift")),
                .file(root.appending("tools/generate-rn-spec.js")),
                .tree(root.appending("third-party/react-native/packages/react-native-codegen")),
                .tool(.named("node")),
            ],
            outputs: [OutputDeclaration(
                path: root.appending(".rn-build/generated/FBReactNativeSpec"),
                validation: .nonEmptyDirectory)],
            locks: [.checkout("rn")],
            operation: .command(CommandSpec(
                executable: .named("node"),
                arguments: [root.appending("tools/generate-rn-spec.js").string],
                workingDirectory: root,
                environment: environment)))
    }

    public static func buildHermes(
        root: FilePath,
        environment: [String: String],
        host: HermesHostDependencies
    ) -> TaskDeclaration {
        let source = root.appending("third-party/hermes")
        let build = root.appending(".rn-build/hermes")
        let combined = build.appending("libhermes_lean_combined.a")
        let hermesc = build.appending("bin/hermesc")
        let ninjaEnvironment = environment.merging([
            "LD_LIBRARY_PATH": host.cxxRuntimeLibrary
                .removingLastComponent().string,
        ]) { _, required in required }
        return TaskDeclaration(
            id: TaskID(rawValue: "rn.hermes"),
            component: ComponentID(rawValue: "rn"),
            dependencies: [TaskID(rawValue: "rn.sources")],
            inputs: [
                .dependencyOutput(source),
                .tree(host.icuIncludeDirectory),
                .file(host.icuUCLibrary),
                .file(host.icuI18NLibrary),
                .file(host.icuDataLibrary),
                .file(host.cxxRuntimeLibrary),
                .tool(.named("cmake")),
                .tool(.named("ninja")),
                .tool(.named("ar")),
                .tool(.named("ranlib")),
            ],
            outputs: [
                OutputDeclaration(path: combined, validation: .regularFile),
                OutputDeclaration(path: hermesc, validation: .executableFile),
            ],
            locks: [.checkout("rn-native")],
            operation: .sequence([
                cmake(
                    source: source,
                    build: build,
                    arguments: [
                        "-DBUILD_SHARED_LIBS=OFF",
                        "-DHERMES_BUILD_SHARED_JSI=OFF",
                        "-DHERMES_BUILD_APPLE_FRAMEWORK=OFF",
                        "-DHERMES_ENABLE_DEBUGGER=OFF",
                        "-DHERMES_ENABLE_INTL=ON",
                        "-DICU_INCLUDE_DIR=\(host.icuIncludeDirectory)",
                        "-DICU_UC_LIBRARY_RELEASE=\(host.icuUCLibrary)",
                        "-DICU_I18N_LIBRARY_RELEASE=\(host.icuI18NLibrary)",
                        "-DICU_DATA_LIBRARY_RELEASE=\(host.icuDataLibrary)",
                        "-DICU_ROOT=\(host.icuIncludeDirectory.removingLastComponent())",
                    ],
                    root: root,
                    environment: environment),
                ninja(
                    build: build,
                    targets: ["hermesvmlean", "jsi", "hermesc"],
                    root: root,
                    environment: ninjaEnvironment),
                .mergeStaticArchives(StaticArchiveMerge(
                    sourceRoot: build,
                    output: combined,
                    excludedFilePrefixes: ["libgtest"],
                    environment: environment)),
            ]))
    }

    public static func buildSupportLibraries(
        root: FilePath,
        environment: [String: String]
    ) -> TaskDeclaration {
        let fmtBuild = root.appending(".rn-build/fmt")
        let conversionBuild = root.appending(".rn-build/double-conversion")
        return TaskDeclaration(
            id: TaskID(rawValue: "rn.support"),
            component: ComponentID(rawValue: "rn"),
            dependencies: [TaskID(rawValue: "rn.sources")],
            inputs: [
                .dependencyOutput(root.appending("third-party/fmt")),
                .dependencyOutput(root.appending(
                    "third-party/double-conversion")),
                .tool(.named("cmake")),
                .tool(.named("ninja")),
            ],
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
                cmake(
                    source: root.appending("third-party/fmt"),
                    build: fmtBuild,
                    arguments: [
                        "-DFMT_TEST=OFF", "-DFMT_DOC=OFF", "-DFMT_INSTALL=OFF",
                    ],
                    root: root,
                    environment: environment),
                ninja(
                    build: fmtBuild, targets: ["fmt"],
                    root: root, environment: environment),
                cmake(
                    source: root.appending("third-party/double-conversion"),
                    build: conversionBuild,
                    arguments: ["-DCMAKE_POLICY_VERSION_MINIMUM=3.5"],
                    root: root,
                    environment: environment),
                ninja(
                    build: conversionBuild, targets: ["double-conversion"],
                    root: root, environment: environment),
            ]))
    }

    public static func buildCxxRuntime(
        root: FilePath,
        environment: [String: String]
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
                .dependencyOutput(root.appending("third-party/glog")),
                .dependencyOutput(root.appending("third-party/folly")),
                .dependencyOutput(root.appending("third-party/fast_float")),
                .dependencyOutput(root.appending("third-party/boost")),
                .dependencyOutput(root.appending("third-party/hermes")),
                .dependencyOutput(reactNative.appending("ReactCommon")),
                .dependencyOutput(root.appending(".rn-build/generated")),
                .tree(root.appending("../core/swiftpm/cmake/reactnative")),
                .tool(.named("cmake")),
                .tool(.named("ninja")),
            ],
            outputs: [
                OutputDeclaration(
                    path: glogBuild.appending("libglog.a"),
                    validation: .regularFile),
                OutputDeclaration(
                    path: glogBuild.appending("glog/logging.h"),
                    validation: .regularFile),
            ] + [
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
                    target: root.appending(
                        "third-party/double-conversion/src").string),
                cmake(
                    source: root.appending("third-party/glog"),
                    build: glogBuild,
                    arguments: [
                        "-DCMAKE_POLICY_VERSION_MINIMUM=3.5",
                        "-DWITH_GFLAGS=OFF", "-DBUILD_TESTING=OFF",
                        "-DHAVE_EXECINFO_H=0", "-DHAVE_UNWIND_H=0",
                    ],
                    root: root,
                    environment: environment),
                ninja(
                    build: glogBuild, targets: ["glog"],
                    root: root, environment: environment),
                cmake(
                    source: root.appending("../core/swiftpm/cmake/reactnative"),
                    build: nativeBuild,
                    arguments: [
                        "-DFOLLY_DIR=\(root.appending("third-party/folly"))",
                        "-DBOOST_INC=\(root.appending("third-party/boost"))",
                        "-DGLOG_INC=\(glogBuild)",
                        "-DGLOG_SRC_INC=\(root.appending("third-party/glog/src"))",
                        "-DDOUBLE_CONVERSION_INC=\(includeRoot)",
                        "-DFMT_INC=\(root.appending("third-party/fmt/include"))",
                        "-DFAST_FLOAT_INC=\(root.appending("third-party/fast_float/include"))",
                        "-DJSI_DIR=\(reactNative.appending("ReactCommon/jsi"))",
                        "-DRN_ROOT=\(reactNative)",
                        "-DRN_CODEGEN_ROOT=\(root.appending(".rn-build/generated"))",
                        "-DHERMES_DIR=\(root.appending("third-party/hermes"))",
                    ],
                    root: root,
                    environment: environment),
                ninja(
                    build: nativeBuild,
                    targets: [
                        "folly_runtime", "jsi", "react_native",
                        "react_cxx_platform", "yogacore",
                    ],
                    root: root,
                    environment: environment),
            ]))
    }

    public static func stageHostArchive(
        root: FilePath,
        configuration: String
    ) throws -> TaskDeclaration {
        guard configuration == "debug" || configuration == "release" else {
            throw ReactNativeRecipeFailure.invalidConfiguration(configuration)
        }
        let archive = "libNucleusReactRuntimeHostCxx.a"
        let products = root.appending(".build/out/Products")
        let prefix = configuration.prefix(1).uppercased()
            + String(configuration.dropFirst())
        let destination = root.appending(
            ".cxx-build/\(configuration)/\(archive)")
        return TaskDeclaration(
            id: TaskID(rawValue: "rn.host-archive.\(configuration)"),
            component: ComponentID(rawValue: "rn"),
            outputs: [
                OutputDeclaration(
                    path: destination,
                    validation: .regularFile),
            ],
            locks: [.checkout("rn-host-archive")],
            operation: .copyMatchingFile(MatchingFileCopy(
                searchDirectory: products,
                childDirectoryPrefix: prefix + "-",
                fileName: archive,
                destination: destination)))
    }

    public static func buildSwiftCxxFacade(
        root: FilePath,
        environment: [String: String]
    ) -> TaskDeclaration {
        TaskDeclaration(
            id: TaskID(rawValue: "rn.swift-cxx"),
            component: ComponentID(rawValue: "rn"),
            dependencies: [TaskID(rawValue: "rn.cxx")],
            inputs: [
                .file(root.appending("Package.swift")),
                .tree(root.appending("swift")),
                .tool(.named("swift")),
            ],
            outputs: [
                OutputDeclaration(
                    path: root.appending(".build/out/Products"),
                    validation: .nonEmptyDirectory),
            ],
            locks: [.checkout("rn-swift")],
            operation: .command(CommandSpec(
                executable: .named("swift"),
                arguments: [
                    "build", "--target", "NucleusReactRuntimeCxx",
                ],
                workingDirectory: root,
                environment: environment)))
    }

    public static func buildSwiftHostCxx(
        root: FilePath,
        environment: [String: String]
    ) -> TaskDeclaration {
        TaskDeclaration(
            id: TaskID(rawValue: "rn.swift-host-cxx"),
            component: ComponentID(rawValue: "rn"),
            dependencies: [TaskID(rawValue: "rn.swift-cxx")],
            inputs: [
                .file(root.appending("Package.swift")),
                .tree(root.appending("swift")),
                .tool(.named("swift")),
            ],
            outputs: [
                OutputDeclaration(
                    path: root.appending(".build/out/Products"),
                    validation: .nonEmptyDirectory),
            ],
            locks: [.checkout("rn-swift")],
            operation: .command(CommandSpec(
                executable: .named("swift"),
                arguments: [
                    "build", "--product",
                    "NucleusReactRuntimeHostCxx",
                ],
                workingDirectory: root,
                environment: environment)))
    }

    public static func publishNativeSDK(
        root: FilePath,
        sdkRoot: FilePath
    ) -> TaskDeclaration {
        let sdk = sdkRoot.appending("rn")
        let links: [(String, FilePath)] = [
            ("include/hermes", root.appending("third-party/hermes")),
            ("include/folly", root.appending("third-party/folly")),
            ("include/boost", root.appending("third-party/boost")),
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
            ("lib/nucleus-cxx-libs", root.appending(".cxx-build")),
        ]
        return TaskDeclaration(
            id: TaskID(rawValue: "rn.native-sdk"),
            component: ComponentID(rawValue: "rn"),
            dependencies: [
                TaskID(rawValue: "core.native-sdk"),
                TaskID(rawValue: "rn.cxx"),
                TaskID(rawValue: "rn.host-archive.debug"),
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
                .shared(sdkRoot.appending(".rn.lock")),
            ],
            operation: .sequence(links.map {
                .replaceSymlink(
                    path: sdk.appending($0.0),
                    target: $0.1.string)
            }))
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
    case invalidConfiguration(String)

    public var description: String {
        switch self {
        case .invalidBoostSpecification:
            "the pinned Boost download specification is invalid"
        case .invalidConfiguration(let value):
            "invalid RN host archive configuration '\(value)'"
        }
    }
}

private let commonCMakeArguments = [
    "-G", "Ninja",
    "-DCMAKE_BUILD_TYPE=Release",
    "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
    "-DCMAKE_C_COMPILER=clang",
    "-DCMAKE_CXX_COMPILER=clang++",
]

private func cmake(
    source: FilePath,
    build: FilePath,
    arguments: [String],
    root: FilePath,
    environment: [String: String]
) -> TaskOperation {
    .command(CommandSpec(
        executable: .named("cmake"),
        arguments: [
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
    .command(CommandSpec(
        executable: .named("ninja"),
        arguments: ["-C", build.string] + targets,
        workingDirectory: root,
        environment: environment))
}

private func task(_ id: String, _ root: FilePath, _ environment: [String: String], _ arguments: [String], _ dependencies: [TaskID]) -> TaskDeclaration {
    TaskDeclaration(id: TaskID(rawValue: id), component: ComponentID(rawValue: "rn"), dependencies: dependencies, inputs: [.file(root.appending("Package.swift")), .tree(root.appending("Sources")), .tool(.named("swift"))], outputs: [OutputDeclaration(path: root.appending(".build"), validation: .nonEmptyDirectory)], locks: [.checkout("rn")], operation: .command(CommandSpec(executable: .named("swift"), arguments: arguments, workingDirectory: root, environment: environment)))
}
