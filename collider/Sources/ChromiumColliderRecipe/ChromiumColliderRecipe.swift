import ColliderCore
import Foundation
import SystemPackage

package enum ChromiumTaskIDs {
    package static let source = TaskID(rawValue: "browser.source")
    package static let retention = TaskID(rawValue: "browser.retention")
    package static let test = TaskID(rawValue: "browser.test")
    package static let install = TaskID(rawValue: "browser.install")
}

public struct ChromiumRecipeLayout: Hashable, Sendable {
    public let sourceID: String
    public let cacheRoot: FilePath
    public let installPrefix: FilePath
    public let jobs: Int

    public init(
        sourceID: String,
        cacheRoot: FilePath,
        installPrefix: FilePath,
        jobs: Int
    ) {
        self.sourceID = sourceID
        self.cacheRoot = cacheRoot
        self.installPrefix = installPrefix
        self.jobs = jobs
    }
}

public enum ChromiumColliderRecipe: ColliderComponent {
    public static let descriptor = ComponentDescriptor(
        id: ComponentID(rawValue: "browser"),
        canonicalName: "browser",
        directoryName: "chromium",
        aliases: ["chromium"])

    public static func makeComponent(
        in context: RecipeContext
    ) throws -> ComponentDefinition {
        let lock = try JSONDecoder().decode(
            ChromiumSourceLock.self,
            from: Data(
                contentsOf: URL(
                    fileURLWithPath: context.repositoryRoot.appending(
                        "chromium/source.lock.json"
                    ).string)))
        try validateSourceLock(lock)
        let sourceID =
            ([lock.depotTools.commit]
            + lock.repositories.sorted(by: { $0.name < $1.name }).map(\.commit))
            .map { String($0.prefix(32)) }
            .joined(separator: "-")
        let prefix =
            context.environment["PREFIX"]
            ?? context.environment["HOME"].map { FilePath($0).appending(".local").string }
            ?? "/tmp/nucleus-browser"
        let tasks = try tasks(
            workspaceRoot: context.repositoryRoot,
            environment: context.environment,
            layout: ChromiumRecipeLayout(
                sourceID: sourceID,
                cacheRoot: context.cacheRoot.appending("nucleus/cef"),
                installPrefix: FilePath(prefix),
                jobs: Int(context.environment["NUCLEUS_CHROMIUM_JOBS"] ?? "")
                    ?? 16))
        return try ComponentDefinition(
            descriptor: descriptor,
            tasks: tasks,
            entrypoints: [
                ComponentEntrypoint(
                    id: .bootstrap,
                    roots: [ChromiumTaskIDs.source]),
                ComponentEntrypoint(id: .build, roots: [ChromiumTaskIDs.retention]),
                ComponentEntrypoint(id: .testDefault, roots: [ChromiumTaskIDs.test]),
                ComponentEntrypoint(id: .install, roots: [ChromiumTaskIDs.install]),
            ])
    }

    public static func tasks(
        workspaceRoot: FilePath,
        environment: [String: String],
        layout: ChromiumRecipeLayout
    ) throws -> [TaskDeclaration] {
        let chromium = workspaceRoot.appending("chromium")
        let sourceLockFile = chromium.appending("source.lock.json")
        let sourceLock = try JSONDecoder().decode(
            ChromiumSourceLock.self,
            from: Data(
                contentsOf: URL(
                    fileURLWithPath: sourceLockFile.string)))
        try validateSourceLock(sourceLock)
        var repositories: [String: ChromiumSourceRepository] = [:]
        for repository in sourceLock.repositories {
            guard
                repositories.updateValue(
                    repository,
                    forKey: repository.name
                ) == nil
            else {
                throw ChromiumRecipeFailure.invalidSourceLock
            }
        }
        guard let chromiumRepository = repositories["chromium"],
            let cefRepository = repositories["cef"],
            repositories["angle"] != nil,
            repositories["skia"] != nil,
            repositories["v8"] != nil,
            repositories["dawn"] != nil,
            repositories.count == 6
        else {
            throw ChromiumRecipeFailure.invalidSourceLock
        }
        let cache = layout.cacheRoot
        let sources = cache.appending("source-generations")
        let source = sources.appending(layout.sourceID)
        let chromiumSource = source.appending("chromium/src")
        let buildGeneration = cache.appending("build").appending(
            layout.sourceID)
        let cefOutput = buildGeneration.appending("cef")
        let browserOutput = buildGeneration.appending("browser")
        let cefDistribution = cache.appending("dist")
        let browserDistribution = cache.appending("browser-dist")
        let depotTools = cache.appending("depot_tools")
        let builderContext = chromium.appending("build-container")
        let builderImageID = cache.appending("build-container/image-id")
        let childEnvironment = environment.merging([
            "NUCLEUS_CHROMIUM_ORCHESTRATED": "1",
            "NUCLEUS_CEF_BRANCH": sourceLock.cefBranch,
            "NUCLEUS_CEF_CHECKOUT": cefRepository.commit,
            "NUCLEUS_CEF_CHROMIUM_VERSION": sourceLock.chromiumVersion,
            "NUCLEUS_CHROMIUM_CHECKOUT": chromiumRepository.commit,
            "NUCLEUS_DEPOT_TOOLS_REVISION": sourceLock.depotTools.commit,
            "NUCLEUS_CEF_CACHE_ROOT": cache.string,
            "NUCLEUS_CEF_DEPOT_TOOLS": depotTools.string,
            "NUCLEUS_CHROMIUM_SOURCE_ID": layout.sourceID,
            "NUCLEUS_CHROMIUM_SOURCE_GENERATIONS": sources.string,
            "NUCLEUS_CHROMIUM_SOURCE_CURRENT": sources.appending(
                "current"
            ).string,
            "NUCLEUS_CEF_SRC_ROOT": source.string,
            "NUCLEUS_CHROMIUM_SRC_ROOT": chromiumSource.string,
            "CHROMIUM_BROWSER_OUT": browserOutput.string,
            "NUCLEUS_CEF_DIST_ROOT": cefDistribution.string,
            "NUCLEUS_BROWSER_DIST_ROOT": browserDistribution.string,
            "NUCLEUS_CEF_LOG_DIR": cache.appending("logs").string,
            "NUCLEUS_CHROMIUM_JOBS": String(layout.jobs),
            "GN_DEFINES": cefGNArguments,
            "CHROMIUM_BROWSER_GN_DEFINES_BASE": browserGNArguments,
            "PREFIX": layout.installPrefix.string,
        ]) { _, required in required }
        let depotEnvironment = childEnvironment.merging([
            "PATH": depotTools.string + ":"
                + (childEnvironment["PATH"] ?? "/usr/bin:/bin")
        ]) { _, required in required }
        let commonInputs: [ArtifactInput] =
            [
                .value(name: "source-id", bytes: Array(layout.sourceID.utf8)),
                .file(sourceLockFile),
                .file(chromium.appending("launcher/nucleus-browser")),
                .file(
                    chromium.appending(
                        "share/applications/dev.nucleus.Browser.desktop.in")),
            ]
        let depotToolsTask = TaskDeclaration(
            id: TaskID(rawValue: "browser.depot-tools"),
            component: ComponentID(rawValue: "browser"),
            inputs: [
                .value(
                    name: "depot-tools-revision",
                    bytes: Array(sourceLock.depotTools.commit.utf8)),
                .tool(.named("git")),
            ],
            outputs: [
                OutputDeclaration(
                    path: depotTools.appending(".git/HEAD"),
                    validation: .regularFile)
            ],
            locks: [.shared(cache.appending("locks/depot-tools.lock"))],
            assessmentPolicy: .always,
            operation: .prepareChromiumDepotTools(
                ChromiumDepotToolsPreparation(
                    repository: depotTools,
                    remote: sourceLock.depotTools.remote,
                    commit: sourceLock.depotTools.commit,
                    environment: childEnvironment)))
        let depotBootstrap = TaskDeclaration(
            id: TaskID(rawValue: "browser.depot-tools-bootstrap"),
            component: ComponentID(rawValue: "browser"),
            dependencies: [depotToolsTask.id],
            inputs: [
                .dependencyOutput(depotTools.appending("ensure_bootstrap"))
            ],
            outputs: [
                OutputDeclaration(
                    path: depotTools.appending("python3_bin_reldir.txt"),
                    validation: .regularFile)
            ],
            locks: [.shared(cache.appending("locks/depot-tools.lock"))],
            operation: .command(
                CommandSpec(
                    executable: .taskOutput(
                        depotTools.appending("ensure_bootstrap")),
                    arguments: [],
                    workingDirectory: depotTools,
                    environment: depotEnvironment)))
        let sourcePreparation = ChromiumSourcePreparation(
            sourceID: layout.sourceID,
            sourceRoot: source,
            sourceGenerations: sources,
            current: sources.appending("current"),
            depotTools: depotTools,
            sourceLockFile: sourceLockFile,
            sourceLock: sourceLock,
            environment: childEnvironment)
        let sourceTask = TaskDeclaration(
            id: ChromiumTaskIDs.source,
            component: ComponentID(rawValue: "browser"),
            dependencies: [depotBootstrap.id],
            inputs: commonInputs,
            outputs: [
                OutputDeclaration(
                    path: source.appending("source-provenance.json"),
                    validation: .json)
            ],
            locks: [
                .shared(cache.appending("locks/source.lock"))
            ],
            operation: .prepareChromiumSource(sourcePreparation))
        let builderTask = TaskDeclaration(
            id: TaskID(rawValue: "browser.builder"),
            component: ComponentID(rawValue: "browser"),
            inputs: [
                .tree(builderContext)
            ],
            outputs: [
                OutputDeclaration(
                    path: builderImageID,
                    validation: .regularFile)
            ],
            locks: [.shared(cache.appending("locks/builder.lock"))],
            operation: .prepareOCIImage(
                OCIImagePreparation(
                    executionPlatform: .linuxAMD64OCI,
                    context: builderContext,
                    containerFile: builderContext.appending("Containerfile"),
                    imageID: builderImageID,
                    imageName: "localhost/nucleus-chromium-build",
                    environment: childEnvironment)))
        let cefAssembly = CEFArtifactAssembly(
            chromiumSource: chromiumSource,
            buildOutput: cefOutput,
            depotTools: depotTools,
            distributionRoot: cefDistribution,
            cefCheckout: cefRepository.commit,
            chromiumVersion: sourceLock.chromiumVersion,
            environment: childEnvironment)
        let cefTask = TaskDeclaration(
            id: TaskID(rawValue: "browser.cef"),
            component: ComponentID(rawValue: "browser"),
            dependencies: [sourceTask.id, builderTask.id],
            inputs: commonInputs + [.dependencyOutput(builderImageID)],
            outputs: [
                OutputDeclaration(
                    path: cefDistribution.appending("current"),
                    validation: .symlinkTarget)
            ],
            locks: [
                .shared(cache.appending("locks/cef-output.lock")),
                .shared(cache.appending("locks/cef-publication.lock")),
            ],
            operation: .sequence([
                .buildChromiumProduct(
                    ChromiumProductBuild(
                        product: .cef,
                        sourceRoot: source,
                        output: cefOutput,
                        depotTools: depotTools,
                        containerImageID: builderImageID,
                        gnArguments: cefGNArguments,
                        targets: ["libcef", "chrome_sandbox"],
                        jobs: UInt32(layout.jobs),
                        environment: childEnvironment)),
                .assembleCEFArtifact(cefAssembly),
                .validateCEFArtifact(cefAssembly),
            ]))
        let browserAssembly = BrowserArtifactAssembly(
            chromiumSource: chromiumSource,
            buildOutput: browserOutput,
            distributionRoot: browserDistribution,
            launcher: chromium.appending("launcher/nucleus-browser"),
            desktopTemplate: chromium.appending(
                "share/applications/dev.nucleus.Browser.desktop.in"),
            environment: childEnvironment)
        let browserTask = TaskDeclaration(
            id: TaskID(rawValue: "browser.artifact"),
            component: ComponentID(rawValue: "browser"),
            dependencies: [cefTask.id],
            inputs: commonInputs,
            outputs: [
                OutputDeclaration(
                    path: browserDistribution.appending("current"),
                    validation: .symlinkTarget)
            ],
            locks: [
                .shared(cache.appending("locks/browser-output.lock")),
                .shared(cache.appending("locks/browser-publication.lock")),
            ],
            operation: .sequence([
                .buildChromiumProduct(
                    ChromiumProductBuild(
                        product: .browser,
                        sourceRoot: source,
                        output: browserOutput,
                        depotTools: depotTools,
                        containerImageID: builderImageID,
                        gnArguments: browserGNArguments,
                        targets: ["chrome", "chrome_sandbox"],
                        jobs: UInt32(layout.jobs),
                        environment: childEnvironment)),
                .assembleBrowserArtifact(browserAssembly),
                .validateBrowserArtifact(browserAssembly),
            ]))
        let retention = TaskDeclaration(
            id: ChromiumTaskIDs.retention,
            component: ComponentID(rawValue: "browser"),
            dependencies: [browserTask.id],
            inputs: commonInputs,
            locks: [
                .shared(cache.appending("locks/cache-retention.lock"))
            ],
            assessmentPolicy: .always,
            operation: .pruneDirectories(
                DirectoryRetentionPlan(
                    safetyRoot: cache,
                    rules: [
                        DirectoryRetentionRule(
                            root: sources,
                            current: sources.appending("current"),
                            retain: 1,
                            naming: .contentIdentity),
                        DirectoryRetentionRule(
                            root: cache.appending("build"),
                            current: nil,
                            retain: 1,
                            naming: .contentIdentity),
                        DirectoryRetentionRule(
                            root: cefDistribution.appending("releases"),
                            current: cefDistribution.appending("current-release"),
                            retain: 2,
                            naming: .contentIdentity),
                        DirectoryRetentionRule(
                            root: browserDistribution.appending("generations"),
                            current: browserDistribution.appending("current"),
                            retain: 2,
                            naming: .contentIdentity),
                    ])))
        let test = TaskDeclaration(
            id: ChromiumTaskIDs.test,
            component: ComponentID(rawValue: "browser"),
            dependencies: [browserTask.id],
            inputs: commonInputs,
            locks: [
                .shared(cache.appending("locks/cef-output.lock")),
                .shared(cache.appending("locks/browser-output.lock")),
            ],
            assessmentPolicy: .always,
            operation: .sequence([
                .runOCI(
                    chromiumBuildExecution(
                        imageID: builderImageID,
                        source: source,
                        depotTools: depotTools,
                        output: browserOutput,
                        jobs: layout.jobs,
                        targets: [
                            "ui/ozone:ozone_unittests",
                            "components/viz/service:"
                                + "output_presenter_ozone_unittests",
                        ],
                        environment: childEnvironment)),
                .command(
                    CommandSpec(
                        executable: .taskOutput(
                            browserOutput.appending("ozone_unittests")),
                        arguments: [
                            "--gtest_filter=*OzonePresenter*",
                            "--single-process-tests",
                        ],
                        workingDirectory: browserOutput,
                        environment: childEnvironment)),
                .command(
                    CommandSpec(
                        executable: .taskOutput(
                            browserOutput.appending(
                                "output_presenter_ozone_unittests")),
                        arguments: [
                            "--gtest_filter=OutputPresenterOzoneTest.*",
                            "--single-process-tests",
                        ],
                        workingDirectory: browserOutput,
                        environment: childEnvironment)),
                .validateBrowserArtifact(browserAssembly),
            ]))
        let install = TaskDeclaration(
            id: ChromiumTaskIDs.install,
            component: ComponentID(rawValue: "browser"),
            dependencies: [browserTask.id],
            inputs: commonInputs,
            locks: [
                .shared(cache.appending("locks/browser-publication.lock"))
            ],
            assessmentPolicy: .always,
            operation: .sequence([
                .validateBrowserArtifact(browserAssembly),
                .installBrowser(
                    BrowserInstallation(
                        distributionRoot: browserDistribution,
                        prefix: layout.installPrefix,
                        environment: childEnvironment)),
            ]))
        return [
            depotToolsTask, depotBootstrap,
            sourceTask, builderTask, cefTask, browserTask, retention,
            test, install,
        ]
    }

    private static func validateSourceLock(
        _ sourceLock: ChromiumSourceLock
    ) throws {
        let expected:
            [String: (
                path: String,
                remote: String,
                upstream: String
            )] = [
                "chromium": (
                    "chromium/src",
                    "https://github.com/nucleus-os/chromium.git",
                    "https://chromium.googlesource.com/chromium/src.git"
                ),
                "cef": (
                    "chromium/src/cef",
                    "https://github.com/nucleus-os/cef.git",
                    "https://github.com/chromiumembedded/cef.git"
                ),
                "angle": (
                    "chromium/src/third_party/angle",
                    "https://github.com/nucleus-os/angle.git",
                    "https://chromium.googlesource.com/angle/angle.git"
                ),
                "skia": (
                    "chromium/src/third_party/skia",
                    "https://github.com/nucleus-os/skia.git",
                    "https://skia.googlesource.com/skia.git"
                ),
                "v8": (
                    "chromium/src/v8",
                    "https://github.com/nucleus-os/v8.git",
                    "https://chromium.googlesource.com/v8/v8.git"
                ),
                "dawn": (
                    "chromium/src/third_party/dawn",
                    "https://github.com/nucleus-os/dawn.git",
                    "https://dawn.googlesource.com/dawn.git"
                ),
            ]
        guard sourceLock.repositories.count == expected.count,
            sourceLock.cefBranch.allSatisfy(\.isNumber),
            !sourceLock.cefBranch.isEmpty,
            sourceLock.chromiumVersion.split(separator: ".").count == 4,
            sourceLock.depotTools.remote
                == "https://chromium.googlesource.com/chromium/tools/depot_tools.git",
            isGitObjectID(sourceLock.depotTools.commit)
        else {
            throw ChromiumRecipeFailure.invalidSourceLock
        }
        for repository in sourceLock.repositories {
            guard let requirement = expected[repository.name],
                repository.checkoutPath == requirement.path,
                repository.remote == requirement.remote,
                repository.upstreamRemote == requirement.upstream,
                isGitObjectID(repository.upstreamCommit),
                isGitObjectID(repository.commit),
                isGitObjectID(repository.tree)
            else {
                throw ChromiumRecipeFailure.invalidSourceLock
            }
        }
    }

    private static func isGitObjectID(_ value: String) -> Bool {
        value.utf8.count == 40
            && value.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
            }
    }
}

private func chromiumBuildExecution(
    imageID: FilePath,
    source: FilePath,
    depotTools: FilePath,
    output: FilePath,
    jobs: Int,
    targets: [String],
    environment: [String: String]
) -> OCIExecution {
    OCIExecution(
        executionPlatform: .linuxAMD64OCI,
        artifactTarget: .linuxX86_64,
        imageID: imageID,
        hostname: "chromium-build",
        workingDirectory: "/source/chromium/src",
        hostWorkingDirectory: source.appending("chromium/src"),
        mounts: [
            OCIMount(
                source: source,
                target: "/source",
                access: .readOnly),
            OCIMount(
                source: depotTools,
                target: "/depot_tools",
                access: .readOnly),
            OCIMount(
                source: output.removingLastComponent().appending(".inputs"),
                target: "/inputs",
                access: .readOnly),
            OCIMount(
                source: output,
                target: "/build",
                access: .readWrite),
        ],
        temporaryDirectory: output.removingLastComponent().appending(
            ".temporary"),
        networkPolicy: .externalDisabled,
        userPolicy: .builder,
        capabilityPolicy: .dropAll,
        privilegePolicy: .prohibitAcquisition,
        processFilesystemPolicy: .standard,
        resourceLimits: .build,
        containerEnvironment: [
            "DEPOT_TOOLS_UPDATE": "0",
            "HOME": "/tmp/nucleus-home",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PYTHONDONTWRITEBYTECODE": "1",
            "TZ": "UTC",
        ],
        command: ["build", String(jobs)] + targets,
        environment: environment,
        output: .logged)
}

private enum ChromiumRecipeFailure: Error {
    case invalidSourceLock
}

private let cefGNArguments =
    #"angle_enable_swiftshader=false blink_heap_inside_shared_library=true cc_wrapper="" chrome_pgo_phase=2 clang_use_chrome_plugins=false dcheck_always_on=false disable_fieldtrial_testing_config=true enable_background_mode=false enable_backup_ref_ptr_support=false enable_downgrade_processing=false enable_expensive_dchecks=false enable_linux_installer=false enable_precompiled_headers=false enable_resource_allowlist_generation=false enable_swiftshader=false enable_swiftshader_vulkan=false enable_widevine=true ffmpeg_branding="Chrome" forbid_non_component_debug_builds=false is_component_build=false is_debug=false is_official_build=true optimize_webui=true ozone_platform="wayland" ozone_platform_wayland=true ozone_platform_x11=false proprietary_codecs=true symbol_level=0 target_cpu="x64" thin_lto_enable_optimizations=true treat_warnings_as_errors=false use_allocator_shim=false use_dbus=true use_lld=true use_mold=false use_partition_alloc_as_malloc=false use_qt5=false use_qt6=false use_siso=true use_sysroot=false use_thin_lto=true use_unified_system_module=false"#

private let browserGNArguments =
    #"proprietary_codecs=true ffmpeg_branding="Chrome" is_chrome_branded=false enable_cef=false use_dbus=true enable_widevine=true is_official_build=true is_component_build=false symbol_level=0 dcheck_always_on=false enable_expensive_dchecks=false chrome_pgo_phase=2 use_thin_lto=true thin_lto_enable_optimizations=true use_mold=false use_lld=true use_siso=true cc_wrapper="" use_allocator_shim=true use_partition_alloc_as_malloc=true enable_backup_ref_ptr_support=true enable_swiftshader=false enable_swiftshader_vulkan=false angle_enable_swiftshader=false treat_warnings_as_errors=false clang_use_chrome_plugins=false ozone_platform="wayland" ozone_platform_wayland=true ozone_platform_x11=false use_sysroot=false target_cpu="x64""#
