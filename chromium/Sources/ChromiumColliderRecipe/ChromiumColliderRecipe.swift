import ColliderCore
import Foundation
import SystemPackage

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

public enum ChromiumColliderRecipe {
    public static let cefBranch = "7922"
    public static let cefCheckout =
        "6c664b86a4ef3be5c95b1290068f5e5d52b72db3"
    public static let chromiumVersion = "151.0.7922.19"
    public static let chromiumCheckout =
        "8f914546f6536ee67a34edb3607f946616f55994"
    public static let depotToolsRevision =
        "35892a9e24190cc5f3a511d3954319c93445926c"

    public static let patchDirectories = [
        "chromium/patches/common",
        "cef/patches",
        "chromium/patches/browser",
        "chromium/patches/dawn",
    ]

    public static func tasks(
        workspaceRoot: FilePath,
        environment: [String: String],
        layout: ChromiumRecipeLayout
    ) throws -> [TaskDeclaration] {
        let chromium = workspaceRoot.appending("chromium")
        let cef = workspaceRoot.appending("cef")
        let cache = layout.cacheRoot
        let sources = cache.appending("source-generations")
        let source = sources.appending(layout.sourceID)
        let chromiumSource = source.appending("chromium/src")
        let browserOutput = chromiumSource.appending(
            "out/NucleusBrowser_GN_x64")
        let cefDistribution = cache.appending("dist")
        let browserDistribution = cache.appending("browser-dist")
        let depotTools = cache.appending("depot_tools")
        let automateScript = cache.appending(
            "downloads/automate-git-\(cefCheckout).py")
        guard let automateDigest = ArtifactDigest(
            sha256Hex:
                "fe0c880fd2a91ac3ab4c82301f596295"
                + "cecc1901e503507e36300a5b58578dcd")
        else {
            preconditionFailure("invalid pinned CEF automation digest")
        }
        let childEnvironment = environment.merging([
            "NUCLEUS_CHROMIUM_ORCHESTRATED": "1",
            "NUCLEUS_CEF_BRANCH": cefBranch,
            "NUCLEUS_CEF_CHECKOUT": cefCheckout,
            "NUCLEUS_CEF_CHROMIUM_VERSION": chromiumVersion,
            "NUCLEUS_CHROMIUM_CHECKOUT": chromiumCheckout,
            "NUCLEUS_DEPOT_TOOLS_REVISION": depotToolsRevision,
            "NUCLEUS_CEF_CACHE_ROOT": cache.string,
            "NUCLEUS_CEF_DEPOT_TOOLS": depotTools.string,
            "NUCLEUS_CHROMIUM_SOURCE_ID": layout.sourceID,
            "NUCLEUS_CHROMIUM_SOURCE_GENERATIONS": sources.string,
            "NUCLEUS_CHROMIUM_SOURCE_CURRENT": sources.appending(
                "current").string,
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
        let commonInputs: [ArtifactInput] = [
            .value(name: "source-id", bytes: Array(layout.sourceID.utf8)),
            .file(chromium.appending("Package.swift")),
            .file(chromium.appending("launcher/nucleus-browser")),
            .file(chromium.appending(
                "share/applications/dev.nucleus.Browser.desktop.in")),
        ] + patchDirectories.map {
            .tree(workspaceRoot.appending($0))
        }
        let depotToolsTask = TaskDeclaration(
            id: TaskID(rawValue: "browser.depot-tools"),
            component: ComponentID(rawValue: "browser"),
            inputs: [
                .value(
                    name: "depot-tools-revision",
                    bytes: Array(depotToolsRevision.utf8)),
                .tool(.named("git")),
            ],
            outputs: [
                OutputDeclaration(
                    path: depotTools.appending(".git/HEAD"),
                    validation: .regularFile),
            ],
            locks: [.shared(cache.appending("locks/depot-tools.lock"))],
            cachePolicy: .always,
            operation: .syncGitCheckout(GitCheckoutSync(
                repository: depotTools,
                remote:
                    "https://chromium.googlesource.com/chromium/"
                    + "tools/depot_tools.git",
                revision: .commit(depotToolsRevision),
                environment: childEnvironment)))
        let depotBootstrap = TaskDeclaration(
            id: TaskID(rawValue: "browser.depot-tools-bootstrap"),
            component: ComponentID(rawValue: "browser"),
            dependencies: [depotToolsTask.id],
            inputs: [
                .dependencyOutput(depotTools.appending("ensure_bootstrap")),
            ],
            outputs: [
                OutputDeclaration(
                    path: depotTools.appending("python3_bin_reldir.txt"),
                    validation: .regularFile),
            ],
            locks: [.shared(cache.appending("locks/depot-tools.lock"))],
            operation: .command(CommandSpec(
                executable: .taskOutput(
                    depotTools.appending("ensure_bootstrap")),
                arguments: [],
                workingDirectory: depotTools,
                environment: childEnvironment)))
        let automateDownload = TaskDeclaration(
            id: TaskID(rawValue: "browser.cef-automation"),
            component: ComponentID(rawValue: "browser"),
            inputs: [
                .value(
                    name: "cef-automation-sha256",
                    bytes: Array(
                        "fe0c880fd2a91ac3ab4c82301f596295"
                            .utf8)),
            ],
            outputs: [
                OutputDeclaration(
                    path: automateScript,
                    validation: .regularFile),
            ],
            locks: [.shared(cache.appending("locks/downloads.lock"))],
            operation: .download(
                try DownloadSpec(
                    url: URL(string:
                        "https://raw.githubusercontent.com/"
                        + "chromiumembedded/cef/\(cefCheckout)/"
                        + "tools/automate/automate-git.py")!,
                    permittedRedirectOrigins: [
                        "https://raw.githubusercontent.com",
                    ],
                    expectedDigest: automateDigest,
                    maximumResponseSize: 2 * 1_024 * 1_024,
                    acceptedMediaTypes: ["text/plain"]),
                candidate: automateScript))
        let sourcePreparation = ChromiumSourcePreparation(
            workspace: workspaceRoot,
            sourceID: layout.sourceID,
            sourceRoot: source,
            sourceGenerations: sources,
            current: sources.appending("current"),
            depotTools: depotTools,
            automateScript: automateScript,
            cefBranch: cefBranch,
            cefCheckout: cefCheckout,
            chromiumCheckout: chromiumCheckout,
            depotToolsRevision: depotToolsRevision,
            patchStacks: [
                ChromiumPatchStack(
                    repository: chromiumSource,
                    directory: chromium.appending("patches/common")),
                ChromiumPatchStack(
                    repository: chromiumSource,
                    directory: cef.appending("patches")),
                ChromiumPatchStack(
                    repository: chromiumSource,
                    directory: chromium.appending("patches/browser")),
                ChromiumPatchStack(
                    repository: chromiumSource.appending(
                        "third_party/dawn"),
                    directory: chromium.appending("patches/dawn")),
            ],
            environment: childEnvironment)
        let sourceTask = TaskDeclaration(
            id: TaskID(rawValue: "browser.source"),
            component: ComponentID(rawValue: "browser"),
            dependencies: [depotBootstrap.id, automateDownload.id],
            inputs: commonInputs,
            outputs: [
                OutputDeclaration(
                    path: source.appending("nucleus-source-manifest.json"),
                    validation: .json),
            ],
            locks: [
                .shared(cache.appending("locks/source.lock")),
            ],
            operation: .prepareChromiumSource(sourcePreparation))
        let cefAssembly = CEFArtifactAssembly(
            sourceRoot: source,
            chromiumSource: chromiumSource,
            buildOutput: chromiumSource.appending("out/Release_GN_x64"),
            depotTools: depotTools,
            distributionRoot: cefDistribution,
            cefBranch: cefBranch,
            cefCheckout: cefCheckout,
            chromiumVersion: chromiumVersion,
            environment: childEnvironment)
        let cefTask = TaskDeclaration(
            id: TaskID(rawValue: "browser.cef"),
            component: ComponentID(rawValue: "browser"),
            dependencies: [sourceTask.id],
            inputs: commonInputs,
            outputs: [
                OutputDeclaration(
                    path: cefDistribution.appending("current"),
                    validation: .exists),
            ],
            locks: [
                .shared(cache.appending("locks/cef-output.lock")),
                .shared(cache.appending("locks/cef-publication.lock")),
            ],
            operation: .sequence([
                .buildChromiumProduct(ChromiumProductBuild(
                    product: .cef,
                    sourceRoot: source,
                    output: chromiumSource.appending("out/Release_GN_x64"),
                    depotTools: depotTools,
                    targets: ["cefsimple", "chrome_sandbox"],
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
                    validation: .exists),
            ],
            locks: [
                .shared(cache.appending("locks/browser-output.lock")),
                .shared(cache.appending("locks/browser-publication.lock")),
            ],
            operation: .sequence([
                .buildChromiumProduct(ChromiumProductBuild(
                    product: .browser,
                    sourceRoot: source,
                    output: browserOutput,
                    depotTools: depotTools,
                    gnArguments: browserGNArguments,
                    targets: ["chrome", "chrome_sandbox"],
                    jobs: UInt32(layout.jobs),
                    environment: childEnvironment)),
                .assembleBrowserArtifact(browserAssembly),
                .validateBrowserArtifact(browserAssembly),
            ]))
        let retention = TaskDeclaration(
            id: TaskID(rawValue: "browser.retention"),
            component: ComponentID(rawValue: "browser"),
            dependencies: [browserTask.id],
            inputs: commonInputs,
            locks: [
                .shared(cache.appending("locks/cache-retention.lock")),
            ],
            cachePolicy: .always,
            operation: .pruneDirectories(DirectoryRetentionPlan(
                safetyRoot: cache,
                rules: [
                    DirectoryRetentionRule(
                        root: sources,
                        current: sources.appending("current"),
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
        let bootstrapPackages = TaskDeclaration(
            id: TaskID(rawValue: "browser.bootstrap-packages"),
            component: ComponentID(rawValue: "browser"),
            inputs: [
                .file(cef.appending("apt-deps.txt")),
                .tool(.named("dpkg-query")),
            ],
            cachePolicy: .always,
            operation: .validateAptPackages(AptPackageValidation(
                packageList: cef.appending("apt-deps.txt"),
                environment: childEnvironment)))
        let bootstrapSource = TaskDeclaration(
            id: TaskID(rawValue: "browser.bootstrap-source"),
            component: ComponentID(rawValue: "browser"),
            dependencies: [
                bootstrapPackages.id,
                depotBootstrap.id,
                automateDownload.id,
            ],
            inputs: sourceTask.inputs,
            outputs: sourceTask.outputs,
            locks: sourceTask.locks,
            operation: .prepareChromiumSource(sourcePreparation))
        let test = TaskDeclaration(
            id: TaskID(rawValue: "browser.test"),
            component: ComponentID(rawValue: "browser"),
            dependencies: [browserTask.id],
            inputs: commonInputs,
            locks: [
                .shared(cache.appending("locks/cef-output.lock")),
                .shared(cache.appending("locks/browser-output.lock")),
            ],
            cachePolicy: .always,
            operation: .sequence([
                .command(CommandSpec(
                    executable: .taskOutput(
                        depotTools.appending("autoninja")),
                    arguments: [
                        "-j", String(layout.jobs),
                        "-C", browserOutput.string,
                        "ui/ozone:ozone_unittests",
                        "components/viz/service:"
                            + "output_presenter_ozone_unittests",
                    ],
                    workingDirectory: chromiumSource,
                    environment: childEnvironment)),
                .command(CommandSpec(
                    executable: .taskOutput(
                        browserOutput.appending("ozone_unittests")),
                    arguments: [
                        "--gtest_filter=*OzonePresenter*",
                        "--single-process-tests",
                    ],
                    workingDirectory: browserOutput,
                    environment: childEnvironment)),
                .command(CommandSpec(
                    executable: .taskOutput(browserOutput.appending(
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
            id: TaskID(rawValue: "browser.install"),
            component: ComponentID(rawValue: "browser"),
            dependencies: [browserTask.id],
            inputs: commonInputs,
            locks: [
                .shared(cache.appending("locks/browser-publication.lock")),
            ],
            cachePolicy: .always,
            operation: .sequence([
                .validateBrowserArtifact(browserAssembly),
                .installBrowser(BrowserInstallation(
                    distributionRoot: browserDistribution,
                    prefix: layout.installPrefix,
                    environment: childEnvironment)),
            ]))
        return [
            depotToolsTask, depotBootstrap, automateDownload,
            sourceTask, cefTask, browserTask, retention,
            bootstrapPackages, bootstrapSource, test, install,
        ]
    }
}

private let cefGNArguments =
    #"proprietary_codecs=true ffmpeg_branding=Chrome use_dbus=true is_official_build=true symbol_level=0 dcheck_always_on=false enable_expensive_dchecks=false chrome_pgo_phase=2 use_thin_lto=true thin_lto_enable_optimizations=true use_mold=false use_lld=true use_siso=true cc_wrapper="" use_allocator_shim=false enable_backup_ref_ptr_support=false enable_swiftshader=false enable_swiftshader_vulkan=false angle_enable_swiftshader=false treat_warnings_as_errors=false ozone_platform=wayland ozone_platform_wayland=true ozone_platform_x11=false"#

private let browserGNArguments =
    #"proprietary_codecs=true ffmpeg_branding="Chrome" is_chrome_branded=false enable_cef=false use_dbus=true enable_widevine=true is_official_build=true is_component_build=false symbol_level=0 dcheck_always_on=false enable_expensive_dchecks=false chrome_pgo_phase=2 use_thin_lto=true thin_lto_enable_optimizations=true use_mold=false use_lld=true use_siso=true cc_wrapper="" use_allocator_shim=true use_partition_alloc_as_malloc=true enable_backup_ref_ptr_support=true enable_swiftshader=false enable_swiftshader_vulkan=false angle_enable_swiftshader=false treat_warnings_as_errors=false clang_use_chrome_plugins=false ozone_platform="wayland" ozone_platform_wayland=true ozone_platform_x11=false use_sysroot=false target_cpu="x64""#
