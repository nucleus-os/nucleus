import ColliderCore
import Foundation
import FoundationEssentials
import SystemPackage

public struct SwiftAndroidFoundationConfiguration: Sendable {
    public let downloadCache: FilePath
    public let androidInstallRoot: FilePath
    public let ndkRoot: FilePath
    public let architectures: [String]
    public let apiLevel: UInt32
    public let jobs: UInt32
    public let environment: [String: String]

    public init(
        downloadCache: FilePath,
        androidInstallRoot: FilePath,
        ndkRoot: FilePath,
        architectures: [String],
        apiLevel: UInt32 = 36,
        jobs: UInt32,
        environment: [String: String]
    ) {
        self.downloadCache = downloadCache
        self.androidInstallRoot = androidInstallRoot
        self.ndkRoot = ndkRoot
        self.architectures = architectures
        self.apiLevel = apiLevel
        self.jobs = jobs
        self.environment = environment
    }
}

public struct SwiftPlatformTaskSet: Sendable {
    public let tasks: [TaskDeclaration]
    public let selected: [TaskID]

    public init(tasks: [TaskDeclaration], selected: [TaskID]) {
        self.tasks = tasks
        self.selected = selected
    }
}

public struct SwiftPlatformGenerationConfiguration: Sendable {
    public enum CheckoutMode: String, Sendable {
        case branch
        case tag
    }

    public let foundation: SwiftAndroidFoundationConfiguration
    public let candidate: FilePath
    public let generation: FilePath
    public let active: FilePath
    public let recipeRoot: FilePath
    public let sourceWorkspace: FilePath
    public let sourceID: String
    public let sourceRef: String
    public let sourceScheme: String
    public let checkoutMode: CheckoutMode
    public let hostCC: FilePath
    public let hostCXX: FilePath
    public let bundleName: String
    public let validationWorkRoot: FilePath
    public let sdkDiscoveryLink: FilePath
    public let sdkDiscoveryDisplacedItem: FilePath
    public let reconfigureHost: Bool
    public let environment: [String: String]

    public init(
        foundation: SwiftAndroidFoundationConfiguration,
        candidate: FilePath,
        generation: FilePath,
        active: FilePath,
        recipeRoot: FilePath,
        sourceWorkspace: FilePath,
        sourceID: String,
        sourceRef: String,
        sourceScheme: String,
        checkoutMode: CheckoutMode,
        hostCC: FilePath,
        hostCXX: FilePath,
        bundleName: String,
        validationWorkRoot: FilePath,
        sdkDiscoveryLink: FilePath,
        sdkDiscoveryDisplacedItem: FilePath,
        reconfigureHost: Bool,
        environment: [String: String]
    ) {
        self.foundation = foundation
        self.candidate = candidate
        self.generation = generation
        self.active = active
        self.recipeRoot = recipeRoot
        self.sourceWorkspace = sourceWorkspace
        self.sourceID = sourceID
        self.sourceRef = sourceRef
        self.sourceScheme = sourceScheme
        self.checkoutMode = checkoutMode
        self.hostCC = hostCC
        self.hostCXX = hostCXX
        self.bundleName = bundleName
        self.validationWorkRoot = validationWorkRoot
        self.sdkDiscoveryLink = sdkDiscoveryLink
        self.sdkDiscoveryDisplacedItem = sdkDiscoveryDisplacedItem
        self.reconfigureHost = reconfigureHost
        self.environment = environment
    }
}

public enum SwiftPlatformRecipeFailure: Error, CustomStringConvertible, Sendable {
    case invalidArchitecture(String)
    case invalidArchive(String)

    public var description: String {
        switch self {
        case .invalidArchitecture(let architecture):
            "unsupported Swift Android architecture '\(architecture)'"
        case .invalidArchive(let archive):
            "invalid Swift Android dependency archive '\(archive)'"
        }
    }
}

public enum SwiftPlatformColliderRecipe {
    public static func generation(
        _ configuration: SwiftPlatformGenerationConfiguration
    ) throws -> SwiftPlatformTaskSet {
        let foundation = try androidFoundationDependencies(
            configuration.foundation)
        let toolchain = configuration.candidate.appending("toolchain/usr")
        let android = configuration.candidate.appending("android")
        let androidBuildRoot = android.appending("build")
        let bundle = android.appending(configuration.bundleName)
        let androidSupport = androidBuildSupportTasks(
            configuration,
            buildRoot: androidBuildRoot)
        let hostTaskSet = try hostToolchainTasks(
            configuration,
            toolchain: toolchain)
        let hostID = hostTaskSet.selected[0]
        let preflights = configuration.foundation.architectures.map {
            architecture in
            let directory = androidBuildRoot.appending(
                "preflight-\(architecture)")
            let source = directory.appending("preflight.swift")
            let object = directory.appending("preflight.o")
            return TaskDeclaration(
                id: TaskID(rawValue:
                    "toolchain.android-backend-\(architecture)"),
                component: ComponentID(rawValue: "toolchain"),
                dependencies: [hostID],
                inputs: [
                    .dependencyOutput(toolchain.appending("bin/swiftc")),
                    .value(
                        name: "target",
                        bytes: Array(androidTriple(
                            architecture,
                            apiLevel: configuration.foundation.apiLevel).utf8)),
                ],
                outputs: [
                    OutputDeclaration(path: object, validation: .regularFile),
                ],
                cachePolicy: .always,
                operation: .sequence([
                    .removePath(directory),
                    .createDirectory(directory),
                    .writeFile(
                        source,
                        bytes: Array(
                            "public func _nucleusAndroidPreflight() {}\n".utf8)),
                    .command(CommandSpec(
                        executable: .taskOutput(
                            toolchain.appending("bin/swiftc")),
                        arguments: [
                            "-target", androidTriple(
                                architecture,
                                apiLevel: configuration.foundation.apiLevel),
                            "-parse-stdlib",
                            "-parse-as-library",
                            "-module-name", "_NucleusAndroidPreflight",
                            "-c", source.string,
                            "-o", object.string,
                        ],
                        workingDirectory: directory,
                        environment: androidBuildEnvironment(
                            configuration,
                            toolchain: toolchain))),
                ]))
        }
        let androidBuilds = zip(
            configuration.foundation.architectures,
            preflights
        ).map { architecture, preflight in
            let install = androidBuildRoot.appending(
                "install-\(architecture)")
            let foundationTask = TaskID(rawValue:
                "toolchain.android-foundation-\(architecture)-sanitize")
            return TaskDeclaration(
                id: TaskID(rawValue:
                    "toolchain.android-sdk-build-\(architecture)"),
                component: ComponentID(rawValue: "toolchain"),
                dependencies: [hostID, preflight.id, foundationTask]
                    + androidSupport.map(\.id),
                inputs: [
                    .dependencyOutput(toolchain.appending("bin/swift")),
                    .dependencyOutput(configuration.sourceWorkspace.appending(
                        "swift")),
                    .dependencyOutput(install.appending("usr/lib/libcurl.a")),
                ],
                outputs: [
                    OutputDeclaration(
                        path: install.appending(
                            "usr/lib/swift/android/libswiftCore.so"),
                        validation: .regularFile),
                    OutputDeclaration(
                        path: install.appending(
                            "usr/lib/swift_static/android/"
                                + "static-stdlib-args.lnk"),
                        validation: .regularFile),
                ],
                cachePolicy: .always,
                operation: .command(CommandSpec(
                    executable: .named("python3"),
                    arguments: androidBuildArguments(
                        configuration,
                        architecture: architecture,
                        toolchain: toolchain,
                        install: install),
                    workingDirectory: configuration.sourceWorkspace,
                    environment: androidBuildEnvironment(
                        configuration,
                        toolchain: toolchain))))
        }
        let linkage = TaskDeclaration(
            id: TaskID(rawValue: "toolchain.android-runtime-linkage"),
            component: ComponentID(rawValue: "toolchain"),
            dependencies: androidBuilds.map(\.id),
            inputs: ([
                .file(configuration.foundation.ndkRoot.appending(
                    "source.properties")),
            ] + androidBuilds.flatMap {
                $0.outputs.map { ArtifactInput.dependencyOutput($0.path) }
            }),
            cachePolicy: .always,
            operation: .validateAndroidRuntimeLinkage(
                AndroidRuntimeLinkageValidation(
                    installRoot: androidBuildRoot,
                    ndk: configuration.foundation.ndkRoot,
                    architectures: configuration.foundation.architectures,
                    environment: configuration.environment)))
        let assemble = TaskDeclaration(
            id: TaskID(rawValue: "toolchain.android-sdk-assemble"),
            component: ComponentID(rawValue: "toolchain"),
            dependencies: [linkage.id],
            inputs: ([
                .dependencyOutput(toolchain.appending("include/swift")),
            ] + androidBuilds.flatMap {
                $0.outputs.map { ArtifactInput.dependencyOutput($0.path) }
            }),
            outputs: [
                OutputDeclaration(
                    path: bundle,
                    validation: .nonEmptyDirectory),
            ],
            cachePolicy: .always,
            operation: .assembleAndroidSDK(AndroidSDKAssembly(
                toolchain: toolchain,
                installRoot: androidBuildRoot,
                bundle: bundle,
                sourceID: configuration.sourceID,
                architectures: configuration.foundation.architectures,
                apiLevel: configuration.foundation.apiLevel)))
        let wire = TaskDeclaration(
            id: TaskID(rawValue: "toolchain.android-sdk-wire"),
            component: ComponentID(rawValue: "toolchain"),
            dependencies: [assemble.id],
            inputs: [
                .dependencyOutput(bundle),
                .file(configuration.foundation.ndkRoot.appending(
                    "source.properties")),
            ],
            outputs: [
                OutputDeclaration(
                    path: bundle.appending("swift-android/ndk-sysroot"),
                    validation: .nonEmptyDirectory),
            ],
            cachePolicy: .always,
            operation: .wireAndroidSDK(AndroidSDKWiring(
                bundle: bundle,
                ndk: configuration.foundation.ndkRoot)))
        let validations = configuration.foundation.architectures.map {
            architecture in
            TaskDeclaration(
                id: TaskID(rawValue:
                    "toolchain.android-sdk-test-\(architecture)"),
                component: ComponentID(rawValue: "toolchain"),
                dependencies: [wire.id],
                inputs: [
                    .dependencyOutput(bundle),
                    .dependencyOutput(toolchain.appending("bin/swift")),
                ],
                cachePolicy: .always,
                operation: .validateAndroidSDK(AndroidSDKValidation(
                    toolchain: toolchain,
                    sdkSearchRoot: android,
                    bundleName: configuration.bundleName,
                    ndk: configuration.foundation.ndkRoot,
                    architecture: architecture,
                    apiLevel: configuration.foundation.apiLevel,
                    workDirectory: configuration.validationWorkRoot.appending(
                        architecture),
                    environment: configuration.environment)))
        }
        let activate = TaskDeclaration(
            id: TaskID(rawValue: "toolchain.activate-generation"),
            component: ComponentID(rawValue: "toolchain"),
            dependencies: validations.map(\.id),
            inputs: validations.map {
                .value(name: "validation", bytes: Array($0.id.rawValue.utf8))
            },
            outputs: [
                OutputDeclaration(
                    path: configuration.generation,
                    validation: .nonEmptyDirectory),
                OutputDeclaration(
                    path: configuration.active,
                    validation: .exists),
            ],
            cachePolicy: .always,
            operation: .activateGeneration(
                candidate: configuration.candidate,
                generation: configuration.generation,
                active: configuration.active))
        let discoveryTarget = configuration.active.appending(
            "android/\(configuration.bundleName)").string
        let discovery = TaskDeclaration(
            id: TaskID(rawValue: "toolchain.publish-sdk-discovery"),
            component: ComponentID(rawValue: "toolchain"),
            dependencies: [activate.id],
            inputs: [
                .dependencyOutput(configuration.active),
            ],
            outputs: [
                OutputDeclaration(
                    path: configuration.sdkDiscoveryLink,
                    validation: .exists),
            ],
            cachePolicy: .always,
            operation: .publishSymlink(SymlinkPublication(
                path: configuration.sdkDiscoveryLink,
                target: discoveryTarget,
                displacedItem: configuration.sdkDiscoveryDisplacedItem)))
        return SwiftPlatformTaskSet(
            tasks: foundation.tasks
                + hostTaskSet.tasks
                + androidSupport
                + preflights
                + androidBuilds
                + [linkage, assemble, wire]
                + validations
                + [activate, discovery],
            selected: [discovery.id])
    }

    private static func hostToolchainTasks(
        _ configuration: SwiftPlatformGenerationConfiguration,
        toolchain: FilePath
    ) throws -> SwiftPlatformTaskSet {
        let component = ComponentID(rawValue: "toolchain")
        let swiftRepository = configuration.sourceWorkspace.appending("swift")
        let revision: GitCheckoutSync.Revision = switch
            configuration.checkoutMode
        {
        case .branch: .branch(configuration.sourceRef)
        case .tag: .tag(configuration.sourceRef)
        }
        let synchronization = TaskDeclaration(
            id: TaskID(rawValue: "toolchain.source-sync"),
            component: component,
            inputs: [
                .value(
                    name: "source-ref",
                    bytes: Array(configuration.sourceRef.utf8)),
            ],
            outputs: [
                OutputDeclaration(
                    path: swiftRepository,
                    validation: .nonEmptyDirectory),
            ],
            locks: [.checkout("swift-platform-source")],
            cachePolicy: .always,
            operation: .syncGitCheckout(GitCheckoutSync(
                repository: swiftRepository,
                remote: "https://github.com/swiftlang/swift.git",
                revision: revision,
                environment: configuration.environment)))
        var updateArguments = [
            configuration.sourceWorkspace.appending(
                "swift/utils/update-checkout").string,
            "--clone",
            "--scheme", configuration.sourceScheme,
            "--source-root", configuration.sourceWorkspace.string,
        ]
        switch configuration.checkoutMode {
        case .branch:
            updateArguments.append("--reset-to-remote")
        case .tag:
            updateArguments += ["--tag", configuration.sourceRef]
        }
        let update = TaskDeclaration(
            id: TaskID(rawValue: "toolchain.source-update"),
            component: component,
            dependencies: [synchronization.id],
            inputs: [
                .dependencyOutput(swiftRepository),
                .value(
                    name: "source-scheme",
                    bytes: Array(configuration.sourceScheme.utf8)),
            ],
            outputs: [
                OutputDeclaration(
                    path: configuration.sourceWorkspace.appending(
                        "swift-driver/.git"),
                    validation: .exists),
            ],
            locks: [.checkout("swift-platform-source")],
            cachePolicy: .always,
            operation: .command(CommandSpec(
                executable: .named("python3"),
                arguments: updateArguments,
                workingDirectory: configuration.sourceWorkspace,
                environment: configuration.environment)))
        let patchedRepositories = [
            "swift", "swift-driver", "swift-build", "swiftpm",
            "indexstore-db", "sourcekit-lsp",
        ]
        let clean = TaskDeclaration(
            id: TaskID(rawValue: "toolchain.source-clean"),
            component: component,
            dependencies: [update.id],
            inputs: patchedRepositories.map {
                .dependencyOutput(
                    configuration.sourceWorkspace.appending($0))
            },
            locks: [.checkout("swift-platform-source")],
            cachePolicy: .always,
            operation: .sequence(patchedRepositories.map { repository in
                .command(CommandSpec(
                    executable: .named("git"),
                    arguments: [
                        "-C",
                        configuration.sourceWorkspace.appending(
                            repository).string,
                        "clean", "-fd",
                    ],
                    workingDirectory: configuration.sourceWorkspace,
                    environment: configuration.environment))
            }))
        var tasks = [synchronization, update, clean]
        var patchDependency = clean.id
        let patchRoot = configuration.recipeRoot.appending("patches")
        for repository in patchedRepositories {
            let directory = patchRoot.appending(repository)
            guard FileManager.default.fileExists(atPath: directory.string)
            else { continue }
            let names = try FileManager.default.contentsOfDirectory(
                atPath: directory.string)
                .filter { $0.hasSuffix(".patch") }
                .sorted()
            for name in names {
                let patch = directory.appending(name)
                let idName = name
                    .replacingOccurrences(of: ".patch", with: "")
                    .replacingOccurrences(of: "_", with: "-")
                let task = TaskDeclaration(
                    id: TaskID(rawValue:
                        "toolchain.patch-\(repository)-\(idName)"),
                    component: component,
                    dependencies: [patchDependency],
                    inputs: [
                        .file(patch),
                        .dependencyOutput(
                            configuration.sourceWorkspace.appending(
                                repository)),
                    ],
                    locks: [.checkout("swift-platform-source")],
                    cachePolicy: .always,
                    operation: .applyGitPatch(GitPatchApplication(
                        repository: configuration.sourceWorkspace.appending(
                            repository),
                        patch: patch,
                        environment: configuration.environment)))
                tasks.append(task)
                patchDependency = task.id
            }
        }
        let staging = configuration.sourceWorkspace.appending(
            ".nucleus-candidate-install")
        #if os(macOS)
        let platform = HostToolchainPlatform.macOS
        let preset = configuration.recipeRoot.appending(
            "nucleus-build-presets-macos.ini")
        let presetName = "nucleus_buildbot_macos,no_test"
        let packageSuffix = "macos-arm64"
        #else
        let platform = HostToolchainPlatform.linux
        let preset = configuration.recipeRoot.appending(
            "nucleus-build-presets.ini")
        let presetName = "nucleus_buildbot_linux,no_test"
        let packageSuffix = "linux"
        #endif
        let preparation = TaskDeclaration(
            id: TaskID(rawValue: "toolchain.host-prepare"),
            component: component,
            dependencies: [patchDependency],
            inputs: [
                .file(preset),
                .dependencyOutput(swiftRepository),
            ],
            outputs: [
                OutputDeclaration(
                    path: staging.appending(".nucleus-owned"),
                    validation: .regularFile),
            ],
            cachePolicy: .always,
            operation: .prepareHostToolchainBuild(
                HostToolchainBuildPreparation(
                    workspace: configuration.sourceWorkspace,
                    stagingRoot: staging,
                    platform: platform)))
        tasks.append(preparation)
        let upstreamPackage = configuration.sourceWorkspace.appending(
            ".nucleus-upstream-toolchain.tar.gz")
        let buildArguments = hostBuildArguments(
            configuration,
            preset: preset,
            presetName: presetName,
            staging: staging,
            upstreamPackage: upstreamPackage,
            platform: platform)
        let build = TaskDeclaration(
            id: TaskID(rawValue: "toolchain.host-build"),
            component: component,
            dependencies: [preparation.id],
            inputs: [
                .file(preset),
                .dependencyOutput(swiftRepository),
            ] + (platform == .linux ? [
                .file(configuration.recipeRoot.appending(
                    "nucleus-swift-cmake-overrides.cmake")),
            ] : []),
            outputs: [
                OutputDeclaration(
                    path: staging.appending("usr/bin/swift"),
                    validation: .executableFile),
            ],
            cachePolicy: .always,
            operation: .command(CommandSpec(
                executable: .named("python3"),
                arguments: buildArguments,
                workingDirectory: configuration.sourceWorkspace,
                environment: hostBuildEnvironment(
                    configuration,
                    staging: staging,
                    platform: platform))))
        let assemble = TaskDeclaration(
            id: TaskID(rawValue: "toolchain.host-assemble"),
            component: component,
            dependencies: [build.id],
            inputs: [
                .dependencyOutput(staging.appending("usr/bin/swift")),
            ],
            outputs: [
                OutputDeclaration(
                    path: toolchain.appending("bin/swift"),
                    validation: .executableFile),
            ],
            cachePolicy: .always,
            operation: .assembleHostToolchain(HostToolchainAssembly(
                workspace: configuration.sourceWorkspace,
                stagingRoot: staging,
                toolchain: toolchain,
                platform: platform)))
        let validate = TaskDeclaration(
            id: TaskID(rawValue: "toolchain.host-validate"),
            component: component,
            dependencies: [assemble.id],
            inputs: [
                .dependencyOutput(toolchain.appending("bin/swift")),
            ],
            cachePolicy: .always,
            operation: .validateHostToolchain(HostToolchainValidation(
                toolchain: toolchain,
                platform: platform,
                workDirectory: configuration.validationWorkRoot.appending(
                    "host-toolchain"),
                environment: hostValidationEnvironment(
                    configuration,
                    toolchain: toolchain))))
        let archive = configuration.candidate.appending(
            "toolchain/swift-\(configuration.sourceID)-\(packageSuffix).tar.gz")
        let package = TaskDeclaration(
            id: TaskID(rawValue: "toolchain.host-package"),
            component: component,
            dependencies: [validate.id],
            inputs: [
                .dependencyOutput(toolchain),
                .tool(.named("tar")),
            ],
            outputs: [
                OutputDeclaration(path: archive, validation: .regularFile),
            ],
            cachePolicy: .always,
            operation: .sequence([
                .removePath(archive),
                .command(CommandSpec(
                    executable: .named("tar"),
                    arguments: [
                        "-C", toolchain.removingLastComponent().string,
                        "-czf", archive.string,
                        "usr",
                    ],
                    workingDirectory: toolchain.removingLastComponent(),
                    environment: configuration.environment)),
            ]))
        tasks += [build, assemble, validate, package]
        return SwiftPlatformTaskSet(tasks: tasks, selected: [package.id])
    }

    private static func hostBuildArguments(
        _ configuration: SwiftPlatformGenerationConfiguration,
        preset: FilePath,
        presetName: String,
        staging: FilePath,
        upstreamPackage: FilePath,
        platform: HostToolchainPlatform
    ) -> [String] {
        var arguments = [
            configuration.sourceWorkspace.appending(
                "swift/utils/build-script").string,
            "--preset-file",
            configuration.sourceWorkspace.appending(
                "swift/utils/build-presets.ini").string,
            "--preset-file", preset.string,
            "-j", String(configuration.foundation.jobs),
            "--preset=\(presetName)",
            "host_cc=\(configuration.hostCC)",
            "host_cxx=\(configuration.hostCXX)",
            "install_destdir=\(staging)",
        ]
        if platform == .linux {
            arguments += [
                "linker=lld",
                "cmake_overrides="
                    + configuration.recipeRoot.appending(
                        "nucleus-swift-cmake-overrides.cmake").string,
                "installable_package=\(upstreamPackage)",
            ]
        }
        if configuration.reconfigureHost {
            arguments.append("--reconfigure")
        }
        return arguments
    }

    private static func hostBuildEnvironment(
        _ configuration: SwiftPlatformGenerationConfiguration,
        staging: FilePath,
        platform: HostToolchainPlatform
    ) -> [String: String] {
        var environment = configuration.environment
        for key in [
            "CFLAGS", "CXXFLAGS", "LDFLAGS", "CMAKE_EXE_LINKER_FLAGS",
            "CMAKE_SHARED_LINKER_FLAGS", "CMAKE_MODULE_LINKER_FLAGS",
            "CMAKE_STATIC_LINKER_FLAGS",
        ] {
            environment.removeValue(forKey: key)
        }
        environment["CC"] = configuration.hostCC.string
        environment["CXX"] = configuration.hostCXX.string
        environment["SWIFT_EXEC"] = staging.appending("usr/bin/swiftc").string
        environment["XDG_CACHE_HOME"] = configuration.sourceWorkspace.appending(
            ".xdg-cache").string
        if environment["CCACHE_DIR"] == nil,
           let home = environment["HOME"]
        {
            environment["CCACHE_DIR"] = "\(home)/.cache/ccache"
        }
        if platform == .linux {
            let llvm = configuration.sourceWorkspace.appending(
                "build/buildbot_linux/llvm-linux-x86_64/lib").string
            let hostRoot = configuration.hostCXX
                .removingLastComponent().removingLastComponent()
            environment["LIBRARY_PATH"] = [
                llvm,
                hostRoot.appending("lib").string,
                environment["LIBRARY_PATH"] ?? "",
            ].joined(separator: ":")
            environment["LD_LIBRARY_PATH"] = [
                llvm,
                hostRoot.appending("lib").string,
                hostRoot.appending("lib/swift/linux").string,
                environment["LD_LIBRARY_PATH"] ?? "",
            ].joined(separator: ":")
        }
        return environment
    }

    private static func hostValidationEnvironment(
        _ configuration: SwiftPlatformGenerationConfiguration,
        toolchain: FilePath
    ) -> [String: String] {
        var environment = configuration.environment
        environment["PATH"] = toolchain.appending("bin").string
            + ":/usr/bin:/bin"
        #if os(macOS)
        environment["DYLD_LIBRARY_PATH"] = toolchain.appending("lib").string
        #else
        environment["LD_LIBRARY_PATH"] = [
            toolchain.appending("lib").string,
            toolchain.appending("lib/swift/linux").string,
        ].joined(separator: ":")
        #endif
        return environment
    }

    private static func androidTriple(
        _ architecture: String,
        apiLevel: UInt32
    ) -> String {
        "\(architecture)-unknown-linux-android\(apiLevel)"
    }

    private static func androidBuildEnvironment(
        _ configuration: SwiftPlatformGenerationConfiguration,
        toolchain: FilePath
    ) -> [String: String] {
        var environment = configuration.environment
        for key in [
            "CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS", "LIBRARY_PATH",
            "CPATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH",
            "OBJC_INCLUDE_PATH", "SWIFTLY_BIN_DIR", "SWIFTLY_HOME_DIR",
            "SWIFTLY_TOOLCHAINS_DIR",
        ] {
            environment.removeValue(forKey: key)
        }
        #if os(macOS)
        let ccache = "/opt/homebrew/opt/ccache/libexec"
        let runtimeLibraryVariable = "DYLD_LIBRARY_PATH"
        let runtimeLibraryDirectory = "macosx"
        #else
        let ccache = "/usr/lib/ccache"
        let runtimeLibraryVariable = "LD_LIBRARY_PATH"
        let runtimeLibraryDirectory = "linux"
        #endif
        environment["PATH"] = [
            ccache,
            toolchain.appending("bin").string,
            environment["PATH"] ?? "/usr/bin:/bin",
        ].joined(separator: ":")
        environment["CCACHE_PATH"] = toolchain.appending("bin").string
        environment[runtimeLibraryVariable] = [
            toolchain.appending("lib").string,
            toolchain.appending("lib/swift/\(runtimeLibraryDirectory)").string,
            environment[runtimeLibraryVariable] ?? "",
        ].joined(separator: ":")
        return environment
    }

    private static func androidBuildArguments(
        _ configuration: SwiftPlatformGenerationConfiguration,
        architecture: String,
        toolchain: FilePath,
        install: FilePath
    ) -> [String] {
        #if os(macOS)
        let hostTag = "darwin-x86_64"
        let buildSubdirectory = "android-\(architecture)-macos"
        #else
        let hostTag = "linux-x86_64"
        let buildSubdirectory = "android-\(architecture)"
        #endif
        let ndkPrebuilt = configuration.foundation.ndkRoot.appending(
            "toolchains/llvm/prebuilt/\(hostTag)")
        var arguments = [
            configuration.sourceWorkspace.appending(
                "swift/utils/build-script").string,
            "--release",
            "--assertions",
            "--android",
            "--android-ndk", configuration.foundation.ndkRoot.string,
            "--android-arch", architecture,
            "--android-api-level", String(configuration.foundation.apiLevel),
            "--native-swift-tools-path", toolchain.appending("bin").string,
            "--native-clang-tools-path", ndkPrebuilt.appending("bin").string,
            "--host-cc", ndkPrebuilt.appending("bin/clang").string,
            "--host-cxx", ndkPrebuilt.appending("bin/clang++").string,
            "--skip-build-cmark",
            "--build-llvm=0",
            "--skip-local-build",
            "--cross-compile-build-swift-tools=False",
            "--cross-compile-hosts=android-\(architecture)",
            "--cross-compile-deps-path=\(install)",
            "--cross-compile-append-host-target-to-destdir=False",
            "--build-swift-static-stdlib",
            "--xctest",
            "--swift-testing",
            "--install-swift",
            "--install-libdispatch",
            "--install-foundation",
            "--install-xctest",
            "--install-swift-testing",
            "--swift-install-components="
                + "compiler;clang-resource-dir-symlink;license;stdlib;sdk-overlay",
            "--install-destdir=\(install)",
            "--libdispatch-cmake-options=-DCMAKE_SHARED_LINKER_FLAGS=",
            "--build-subdir=\(buildSubdirectory)",
            "--jobs=\(configuration.foundation.jobs)",
            "--skip-test-swift",
            "--skip-test-foundation",
            "--skip-test-libdispatch",
            "--reconfigure",
        ]
        #if os(macOS)
        let dispatchHeaders = configuration.foundation.androidInstallRoot
            .appending("build/libdispatch-headers")
        let foundationOptions = [
            "-DCMAKE_SHARED_LINKER_FLAGS=",
            "-DLIBXML2_LIBRARY=\(install.appending("usr/lib/libxml2.a"))",
            "-DLIBXML2_INCLUDE_DIR=\(install.appending("usr/include/libxml2"))",
            "-DOPENSSL_CRYPTO_LIBRARY="
                + install.appending("usr/lib/libcrypto.a").string,
            "-DOPENSSL_SSL_LIBRARY="
                + install.appending("usr/lib/libssl.a").string,
            "-DOPENSSL_INCLUDE_DIR=\(install.appending("usr/include"))",
            "-DDISPATCH_INCLUDE_PATH=\(dispatchHeaders)",
        ].joined(separator: " ")
        arguments += [
            "--stdlib-deployment-targets=android-\(architecture)",
            "--libdispatch",
            "--foundation",
            "--install-prefix=/usr",
            "--foundation-cmake-options=\(foundationOptions)",
            "--extra-swift-cmake-options="
                + "-DCMAKE_Swift_COMPILER_WORKS:BOOL=TRUE",
            "--extra-swift-cmake-options="
                + "-DCMAKE_SHARED_LIBRARY_SUFFIX_Swift:STRING=.so",
            "--extra-swift-cmake-options="
                + "-DCMAKE_OSX_ARCHITECTURES:STRING=",
            "--extra-swift-cmake-options=-DCMAKE_OSX_SYSROOT:PATH=",
            "--extra-swift-cmake-options="
                + "-DCMAKE_OSX_DEPLOYMENT_TARGET:STRING=",
            "--build-swift-dynamic-sdk-overlay",
            "--build-swift-static-sdk-overlay",
        ]
        #else
        arguments.append(
            "--foundation-cmake-options=-DCMAKE_SHARED_LINKER_FLAGS=")
        #endif
        return arguments
    }

    private static func androidBuildSupportTasks(
        _ configuration: SwiftPlatformGenerationConfiguration,
        buildRoot: FilePath
    ) -> [TaskDeclaration] {
        #if os(macOS)
        let source = configuration.sourceWorkspace.appending(
            "swift-corelibs-libdispatch")
        let destination = buildRoot.appending("libdispatch-headers")
        let dispatchHeaders = [
            "base", "block", "data", "dispatch", "group", "introspection",
            "io", "object", "once", "queue", "semaphore", "source", "time",
        ]
        var operations: [TaskOperation] = [
            .removePath(destination),
            .createDirectory(destination.appending("dispatch")),
            .createDirectory(destination.appending("Block")),
            .createDirectory(destination.appending("os")),
        ]
        operations += dispatchHeaders.map {
            .copyFile(
                source: source.appending("dispatch/\($0).h"),
                destination: destination.appending("dispatch/\($0).h"))
        }
        operations += [
            .copyFile(
                source: source.appending("src/BlocksRuntime/Block.h"),
                destination: destination.appending("Block/Block.h")),
        ]
        operations += [
            "generic_base", "generic_unix_base", "generic_win_base", "object",
        ].map {
            .copyFile(
                source: source.appending("os/\($0).h"),
                destination: destination.appending("os/\($0).h"))
        }
        let marker = destination.appending(".complete")
        operations.append(.writeFile(marker, bytes: Array("complete\n".utf8)))
        return [
            TaskDeclaration(
                id: TaskID(rawValue: "toolchain.android-build-support"),
                component: ComponentID(rawValue: "toolchain"),
                inputs: [.dependencyOutput(source)],
                outputs: [
                    OutputDeclaration(path: marker, validation: .regularFile),
                ],
                cachePolicy: .always,
                operation: .sequence(operations)),
        ]
        #else
        return []
        #endif
    }

    public static func androidFoundationDependencies(
        _ configuration: SwiftAndroidFoundationConfiguration
    ) throws -> SwiftPlatformTaskSet {
        var tasks: [TaskDeclaration] = []
        let archives = try archiveTasks(configuration)
        tasks += archives.downloads
        var selected: [TaskID] = []
        for architecture in configuration.architectures {
            let context = try ArchitectureContext(
                configuration: configuration,
                architecture: architecture)
            let extractions = archiveExtractions(
                archives: archives,
                context: context)
            tasks += extractions.values.sorted {
                $0.id.rawValue < $1.id.rawValue
            }
            let builds = dependencyBuilds(
                extractions: extractions,
                context: context)
            tasks += builds
            selected.append(TaskID(rawValue:
                "toolchain.android-foundation-\(architecture)-sanitize"))
        }
        return SwiftPlatformTaskSet(tasks: tasks, selected: selected)
    }

    private struct Archive: Sendable {
        let key: String
        let directory: String
        let file: String
        let url: String
        let sha256: String
    }

    private struct ArchiveTasks {
        let archives: [Archive]
        let downloads: [TaskDeclaration]
        let paths: [String: FilePath]
    }

    private static let archives = [
        Archive(
            key: "zlib", directory: "zlib-1.3.1",
            file: "zlib-1.3.1.tar.gz",
            url: "https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz",
            sha256: "9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23"),
        Archive(
            key: "xz", directory: "xz-5.6.3",
            file: "xz-5.6.3.tar.gz",
            url: "https://github.com/tukaani-project/xz/releases/download/v5.6.3/xz-5.6.3.tar.gz",
            sha256: "b1d45295d3f71f25a4c9101bd7c8d16cb56348bbef3bbc738da0351e17c73317"),
        Archive(
            key: "libiconv", directory: "libiconv-1.17",
            file: "libiconv-1.17.tar.gz",
            url: "https://ftp.gnu.org/pub/gnu/libiconv/libiconv-1.17.tar.gz",
            sha256: "8f74213b56238c85a50a5329f77e06198771e70dd9a739779f4c02f65d971313"),
        Archive(
            key: "openssl", directory: "openssl-3.4.0",
            file: "openssl-3.4.0.tar.gz",
            url: "https://github.com/openssl/openssl/releases/download/openssl-3.4.0/openssl-3.4.0.tar.gz",
            sha256: "e15dda82fe2fe8139dc2ac21a36d4ca01d5313c75f99f46c4e8a27709b7294bf"),
        Archive(
            key: "nghttp2", directory: "nghttp2-1.64.0",
            file: "nghttp2-1.64.0.tar.xz",
            url: "https://github.com/nghttp2/nghttp2/releases/download/v1.64.0/nghttp2-1.64.0.tar.xz",
            sha256: "88bb94c9e4fd1c499967f83dece36a78122af7d5fb40da2019c56b9ccc6eb9dd"),
        Archive(
            key: "libcurl", directory: "curl-8.11.0",
            file: "curl-8.11.0.tar.gz",
            url: "https://curl.se/download/curl-8.11.0.tar.gz",
            sha256: "264537d90e58d2b09dddc50944baf3c38e7089151c8986715e2aaeaaf2b8118f"),
        Archive(
            key: "libxml2", directory: "libxml2-2.13.5",
            file: "libxml2-2.13.5.tar.xz",
            url: "https://download.gnome.org/sources/libxml2/2.13/libxml2-2.13.5.tar.xz",
            sha256: "74fc163217a3964257d3be39af943e08861263c4231f9ef5b496b6f6d4c7b2b6"),
    ]

    private static func archiveTasks(
        _ configuration: SwiftAndroidFoundationConfiguration
    ) throws -> ArchiveTasks {
        let cache = configuration.downloadCache
        var paths: [String: FilePath] = [:]
        let downloads = try archives.map { archive -> TaskDeclaration in
            guard let url = URL(string: archive.url),
                  let scheme = url.scheme,
                  let host = url.host,
                  let digest = ArtifactDigest(sha256Hex: archive.sha256)
            else {
                throw SwiftPlatformRecipeFailure.invalidArchive(archive.file)
            }
            let specification = try DownloadSpec(
                url: url,
                permittedRedirectOrigins: Set([
                    "\(scheme)://\(host)",
                    "https://release-assets.githubusercontent.com",
                    "https://objects.githubusercontent.com",
                ]),
                expectedDigest: digest,
                maximumResponseSize: 128 * 1_024 * 1_024,
                acceptedMediaTypes: [
                    "application/gzip",
                    "application/octet-stream",
                    "application/x-gzip",
                    "application/x-xz",
                ],
                requestTimeoutSeconds: 120,
                inactivityTimeoutSeconds: 30,
                maximumRedirects: 5,
                maximumRetries: 2,
                resumption: .validatorRequired)
            let path = cache.appending(archive.file)
            paths[archive.key] = path
            return TaskDeclaration(
                id: downloadID(archive),
                component: ComponentID(rawValue: "toolchain"),
                outputs: [
                    OutputDeclaration(path: path, validation: .regularFile),
                ],
                locks: [.checkout("android-foundation-downloads")],
                operation: .download(specification, candidate: path))
        }
        return ArchiveTasks(
            archives: archives,
            downloads: downloads,
            paths: paths)
    }

    private struct ArchitectureContext {
        let architecture: String
        let hostTriple: String
        let cmakeABI: String
        let opensslTarget: String
        let sourceRoot: FilePath
        let staging: FilePath
        let ndkRoot: FilePath
        let ndkPrebuilt: FilePath
        let cmakeToolchain: FilePath
        let apiLevel: UInt32
        let jobs: String
        let environment: [String: String]

        init(
            configuration: SwiftAndroidFoundationConfiguration,
            architecture: String
        ) throws {
            switch architecture {
            case "aarch64":
                hostTriple = "aarch64-linux-android"
                cmakeABI = "arm64-v8a"
                opensslTarget = "android-arm64"
            case "x86_64":
                hostTriple = "x86_64-linux-android"
                cmakeABI = "x86_64"
                opensslTarget = "android-x86_64"
            default:
                throw SwiftPlatformRecipeFailure.invalidArchitecture(
                    architecture)
            }
            self.architecture = architecture
            apiLevel = configuration.apiLevel
            sourceRoot = configuration.androidInstallRoot.appending(
                "build/foundation-sources/\(architecture)")
            staging = configuration.androidInstallRoot.appending(
                "build/install-\(architecture)")
            #if os(macOS)
            let hostTag = "darwin-x86_64"
            #else
            let hostTag = "linux-x86_64"
            #endif
            ndkPrebuilt = configuration.ndkRoot.appending(
                "toolchains/llvm/prebuilt/\(hostTag)")
            ndkRoot = configuration.ndkRoot
            cmakeToolchain = configuration.ndkRoot.appending(
                "build/cmake/android.toolchain.cmake")
            jobs = String(configuration.jobs)
            var environment = configuration.environment
            let compilerPrefix = ndkPrebuilt.appending(
                "bin/\(hostTriple)\(configuration.apiLevel)")
            environment["CC"] = compilerPrefix.string + "-clang"
            environment["CXX"] = compilerPrefix.string + "-clang++"
            environment["AR"] = ndkPrebuilt.appending("bin/llvm-ar").string
            environment["RANLIB"] =
                ndkPrebuilt.appending("bin/llvm-ranlib").string
            environment["STRIP"] =
                ndkPrebuilt.appending("bin/llvm-strip").string
            environment["NM"] = ndkPrebuilt.appending("bin/llvm-nm").string
            environment["OBJCOPY"] =
                ndkPrebuilt.appending("bin/llvm-objcopy").string
            environment["OBJDUMP"] =
                ndkPrebuilt.appending("bin/llvm-objdump").string
            environment["READELF"] =
                ndkPrebuilt.appending("bin/llvm-readelf").string
            environment["PKG_CONFIG_LIBDIR"] =
                staging.appending("usr/lib/pkgconfig").string
            environment["PKG_CONFIG_PATH"] = ""
            environment["CFLAGS"] = "-fPIC"
            environment["CXXFLAGS"] = "-fPIC"
            environment["CPPFLAGS"] = ""
            environment["LDFLAGS"] = ""
            for key in [
                "LIBRARY_PATH", "CPATH", "C_INCLUDE_PATH",
                "CPLUS_INCLUDE_PATH", "OBJC_INCLUDE_PATH",
            ] {
                environment.removeValue(forKey: key)
            }
            self.environment = environment
        }
    }

    private static func archiveExtractions(
        archives: ArchiveTasks,
        context: ArchitectureContext
    ) -> [String: TaskDeclaration] {
        Dictionary(uniqueKeysWithValues: archives.archives.map { archive in
            let source = context.sourceRoot.appending(archive.directory)
            let archivePath = archives.paths[archive.key]!
            let task = TaskDeclaration(
                id: extractID(archive, architecture: context.architecture),
                component: ComponentID(rawValue: "toolchain"),
                dependencies: [downloadID(archive)],
                inputs: [
                    .dependencyOutput(archivePath),
                    .tool(.named("tar")),
                ],
                outputs: [
                    OutputDeclaration(
                        path: source,
                        validation: .nonEmptyDirectory),
                ],
                operation: .sequence([
                    .removePath(source),
                    .createDirectory(context.sourceRoot),
                    .command(CommandSpec(
                        executable: .named("tar"),
                        arguments: [
                            "-xf", archivePath.string,
                            "-C", context.sourceRoot.string,
                        ],
                        workingDirectory: context.sourceRoot,
                        environment: context.environment)),
                ]))
            return (archive.key, task)
        })
    }

    private static func dependencyBuilds(
        extractions: [String: TaskDeclaration],
        context: ArchitectureContext
    ) -> [TaskDeclaration] {
        let zlib = buildZlib(extractions["zlib"]!, context)
        let xz = buildXZ(extractions["xz"]!, context)
        let iconv = buildIconv(extractions["libiconv"]!, context)
        let openssl = buildOpenSSL(
            extractions["openssl"]!, zlib: zlib, context)
        let nghttp2 = buildNGHTTP2(extractions["nghttp2"]!, context)
        let libxml2 = buildLibXML2(
            extractions["libxml2"]!,
            zlib: zlib,
            xz: xz,
            iconv: iconv,
            context)
        let libcurl = buildLibcurl(
            extractions["libcurl"]!,
            zlib: zlib,
            openssl: openssl,
            nghttp2: nghttp2,
            context)
        let sanitize = TaskDeclaration(
            id: TaskID(rawValue:
                "toolchain.android-foundation-\(context.architecture)-sanitize"),
            component: ComponentID(rawValue: "toolchain"),
            dependencies: [libxml2.id, libcurl.id],
            inputs: [
                .dependencyOutput(
                    context.staging.appending("usr/lib/libxml2.a")),
                .dependencyOutput(
                    context.staging.appending("usr/lib/libcurl.a")),
            ],
            outputs: [
                OutputDeclaration(
                    path: context.staging.appending("usr/lib/libxml2.a"),
                    validation: .regularFile),
                OutputDeclaration(
                    path: context.staging.appending("usr/lib/libcurl.a"),
                    validation: .regularFile),
            ],
            operation: .sanitizeLinkMetadata(LinkMetadataSanitization(
                root: context.staging.appending("usr/lib"),
                removedLinkerOptions: ["-pthread"])))
        return [zlib, xz, iconv, openssl, nghttp2, libxml2, libcurl, sanitize]
    }

    private static func buildZlib(
        _ extraction: TaskDeclaration,
        _ context: ArchitectureContext
    ) -> TaskDeclaration {
        let source = extraction.outputs[0].path
        return buildTask(
            name: "zlib",
            dependencies: [extraction.id],
            output: context.staging.appending("usr/lib/libz.a"),
            context: context,
            operations: [
                .command(CommandSpec(
                    executable: .taskOutput(source.appending("configure")),
                    arguments: [
                        "--prefix=\(context.staging.appending("usr"))",
                        "--static", "--uname=Linux",
                    ],
                    workingDirectory: source,
                    environment: context.environment)),
                make(["-j\(context.jobs)"], in: source, context),
                make(["install"], in: source, context),
            ])
    }

    private static func buildXZ(
        _ extraction: TaskDeclaration,
        _ context: ArchitectureContext
    ) -> TaskDeclaration {
        let source = extraction.outputs[0].path
        let build = source.appending("build-\(context.architecture)")
        return buildTask(
            name: "xz",
            dependencies: [extraction.id],
            output: context.staging.appending("usr/lib/liblzma.a"),
            context: context,
            operations: [
                .createDirectory(build),
                .command(CommandSpec(
                    executable: .taskOutput(source.appending("configure")),
                    arguments: autotoolsArguments(context) + [
                        "--disable-doc", "--disable-xz", "--disable-xzdec",
                        "--disable-lzmadec", "--disable-lzmainfo",
                        "--disable-scripts",
                    ],
                    workingDirectory: build,
                    environment: context.environment)),
                make(["-j\(context.jobs)"], in: build, context),
                make(["install"], in: build, context),
            ])
    }

    private static func buildIconv(
        _ extraction: TaskDeclaration,
        _ context: ArchitectureContext
    ) -> TaskDeclaration {
        let source = extraction.outputs[0].path
        let build = source.appending("build-\(context.architecture)")
        return buildTask(
            name: "libiconv",
            dependencies: [extraction.id],
            output: context.staging.appending("usr/lib/libiconv.a"),
            context: context,
            operations: [
                .createDirectory(build),
                .command(CommandSpec(
                    executable: .taskOutput(source.appending("configure")),
                    arguments: autotoolsArguments(context) + [
                        "--enable-extra-encodings", "--disable-rpath",
                    ],
                    workingDirectory: build,
                    environment: context.environment)),
                make(["-j\(context.jobs)"], in: build, context),
                make(["install"], in: build, context),
            ])
    }

    private static func buildOpenSSL(
        _ extraction: TaskDeclaration,
        zlib: TaskDeclaration,
        _ context: ArchitectureContext
    ) -> TaskDeclaration {
        let source = extraction.outputs[0].path
        var environment = context.environment
        environment["PATH"] = context.ndkPrebuilt.appending("bin").string
            + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["ANDROID_NDK_ROOT"] =
            context.ndkRoot.string
        return buildTask(
            name: "openssl",
            dependencies: [extraction.id, zlib.id],
            output: context.staging.appending("usr/lib/libssl.a"),
            context: context,
            operations: [
                .command(CommandSpec(
                    executable: .taskOutput(source.appending("Configure")),
                    arguments: [
                        context.opensslTarget,
                        "-D__ANDROID_API__=\(context.apiLevel)",
                        "--prefix=\(context.staging.appending("usr"))",
                        "--openssldir=\(context.staging.appending("usr/ssl"))",
                        "--with-zlib-include=\(context.staging.appending("usr/include"))",
                        "--with-zlib-lib=\(context.staging.appending("usr/lib"))",
                        "no-shared", "no-tests", "no-docs", "no-apps",
                        "no-engine", "no-legacy", "no-asan", "no-ubsan",
                        "zlib",
                    ],
                    workingDirectory: source,
                    environment: environment)),
                make(["-j\(context.jobs)", "build_libs"], in: source, context,
                     environment: environment),
                make(["install_dev"], in: source, context,
                     environment: environment),
            ])
    }

    private static func buildNGHTTP2(
        _ extraction: TaskDeclaration,
        _ context: ArchitectureContext
    ) -> TaskDeclaration {
        cmakeTask(
            name: "nghttp2",
            extraction: extraction,
            dependencies: [],
            output: context.staging.appending("usr/lib/libnghttp2.a"),
            options: [
                "-DBUILD_SHARED_LIBS=OFF",
                "-DBUILD_STATIC_LIBS=ON",
                "-DENABLE_LIB_ONLY=ON",
                "-DENABLE_APP=OFF",
                "-DENABLE_EXAMPLES=OFF",
                "-DENABLE_HPACK_TOOLS=OFF",
                "-DENABLE_DOC=OFF",
                "-DBUILD_TESTING=OFF",
            ],
            context: context)
    }

    private static func buildLibXML2(
        _ extraction: TaskDeclaration,
        zlib: TaskDeclaration,
        xz: TaskDeclaration,
        iconv: TaskDeclaration,
        _ context: ArchitectureContext
    ) -> TaskDeclaration {
        cmakeTask(
            name: "libxml2",
            extraction: extraction,
            dependencies: [zlib.id, xz.id, iconv.id],
            output: context.staging.appending("usr/lib/libxml2.a"),
            options: [
                "-DBUILD_SHARED_LIBS=OFF",
                "-DLIBXML2_WITH_PROGRAMS=OFF",
                "-DLIBXML2_WITH_TESTS=OFF",
                "-DLIBXML2_WITH_PYTHON=OFF",
                "-DLIBXML2_WITH_ICU=OFF",
                "-DLIBXML2_WITH_LZMA=ON",
                "-DLIBXML2_WITH_ICONV=ON",
                "-DLIBXML2_WITH_ZLIB=ON",
                "-DLIBXML2_WITH_HTTP=OFF",
                "-DLIBXML2_WITH_FTP=OFF",
                "-DLIBXML2_WITH_THREAD_ALLOC=OFF",
            ],
            context: context)
    }

    private static func buildLibcurl(
        _ extraction: TaskDeclaration,
        zlib: TaskDeclaration,
        openssl: TaskDeclaration,
        nghttp2: TaskDeclaration,
        _ context: ArchitectureContext
    ) -> TaskDeclaration {
        cmakeTask(
            name: "libcurl",
            extraction: extraction,
            dependencies: [zlib.id, openssl.id, nghttp2.id],
            output: context.staging.appending("usr/lib/libcurl.a"),
            options: [
                "-DBUILD_SHARED_LIBS=OFF",
                "-DBUILD_STATIC_LIBS=ON",
                "-DBUILD_CURL_EXE=OFF",
                "-DBUILD_TESTING=OFF",
                "-DCURL_USE_OPENSSL=ON",
                "-DCURL_USE_LIBSSH2=OFF",
                "-DCURL_USE_LIBPSL=OFF",
                "-DUSE_LIBIDN2=OFF",
                "-DUSE_NGHTTP2=ON",
                "-DCURL_DISABLE_LDAP=ON",
                "-DCURL_DISABLE_LDAPS=ON",
                "-DCURL_DISABLE_DICT=OFF",
                "-DCURL_ZLIB=ON",
            ],
            context: context)
    }

    private static func cmakeTask(
        name: String,
        extraction: TaskDeclaration,
        dependencies: [TaskID],
        output: FilePath,
        options: [String],
        context: ArchitectureContext
    ) -> TaskDeclaration {
        let source = extraction.outputs[0].path
        let build = source.appending("build-\(context.architecture)")
        let common = [
            "-DCMAKE_TOOLCHAIN_FILE=\(context.cmakeToolchain)",
            "-DANDROID_ABI=\(context.cmakeABI)",
            "-DANDROID_PLATFORM=android-\(context.apiLevel)",
            "-DCMAKE_INSTALL_PREFIX=\(context.staging.appending("usr"))",
            "-DCMAKE_FIND_ROOT_PATH=\(context.staging.appending("usr"))",
            "-DCMAKE_PREFIX_PATH=\(context.staging.appending("usr"))",
        ]
        return buildTask(
            name: name,
            dependencies: [extraction.id] + dependencies,
            output: output,
            context: context,
            operations: [
                .command(CommandSpec(
                    executable: .named("cmake"),
                    arguments: ["-S", source.string, "-B", build.string]
                        + common + options,
                    workingDirectory: source,
                    environment: context.environment)),
                .command(CommandSpec(
                    executable: .named("cmake"),
                    arguments: [
                        "--build", build.string, "-j\(context.jobs)",
                    ],
                    workingDirectory: source,
                    environment: context.environment)),
                .command(CommandSpec(
                    executable: .named("cmake"),
                    arguments: ["--install", build.string],
                    workingDirectory: source,
                    environment: context.environment)),
            ])
    }

    private static func buildTask(
        name: String,
        dependencies: [TaskID],
        output: FilePath,
        context: ArchitectureContext,
        operations: [TaskOperation]
    ) -> TaskDeclaration {
        TaskDeclaration(
            id: TaskID(rawValue:
                "toolchain.android-foundation-\(context.architecture)-\(name)"),
            component: ComponentID(rawValue: "toolchain"),
            dependencies: dependencies,
            inputs: dependencies.map {
                .value(name: "dependency", bytes: Array($0.rawValue.utf8))
            },
            outputs: [
                OutputDeclaration(path: output, validation: .regularFile),
            ],
            operation: .sequence([
                .createDirectory(context.staging.appending("usr/lib")),
                .createDirectory(context.staging.appending("usr/include")),
            ] + operations))
    }

    private static func make(
        _ arguments: [String],
        in directory: FilePath,
        _ context: ArchitectureContext,
        environment: [String: String]? = nil
    ) -> TaskOperation {
        .command(CommandSpec(
            executable: .named("make"),
            arguments: arguments,
            workingDirectory: directory,
            environment: environment ?? context.environment))
    }

    private static func autotoolsArguments(
        _ context: ArchitectureContext
    ) -> [String] {
        [
            "--host=\(context.hostTriple)",
            "--prefix=\(context.staging.appending("usr"))",
            "--disable-shared",
            "--enable-static",
        ]
    }

    private static func downloadID(_ archive: Archive) -> TaskID {
        TaskID(rawValue:
            "toolchain.android-foundation-download-\(archive.key)")
    }

    private static func extractID(
        _ archive: Archive,
        architecture: String
    ) -> TaskID {
        TaskID(rawValue:
            "toolchain.android-foundation-\(architecture)-extract-\(archive.key)")
    }
}
