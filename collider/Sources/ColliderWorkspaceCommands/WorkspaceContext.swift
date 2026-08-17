import ColliderCore
import ColliderPersistence
import ColliderRuntime
import Foundation
import SystemPackage

package func nucleusOCIRuntimeConfiguration(
    workspaceRoot: FilePath
) -> OCIRuntimeConfiguration {
    let canonicalRoot = FilePath(
        URL(fileURLWithPath: workspaceRoot.string)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path)
    let owner = ArtifactHasher.digest(bytes: Array(canonicalRoot.string.utf8)).hexadecimal
    return OCIRuntimeConfiguration(
        isolatedNetwork: "nucleus-build-internal",
        guestHome: "/home/nucleus-build",
        managedLabels: ["dev.nucleus.collider.managed=true"],
        managedLabelNamespace: "dev.nucleus.collider",
        persistentWorkspaceOwner: owner,
        loggerLabel: "dev.nucleus.collider.apple-container")
}

package let nucleusSwiftPMEnvironmentProjection = EnvironmentProjection(
    names: ["LANG", "LC_ALL", "TZ", "TERM"],
    prefixes: ["NUCLEUS_", "SWIFTPM_", "CCACHE_"],
    excludedNames: ["NUCLEUS_NATIVE_SDK_ROOT"])

package func nucleusLogRoot(workspaceRoot: FilePath) -> FilePath {
    #if os(macOS)
    return (try? MacOSHostStorageLayout.current().logsRoot)
        ?? workspaceRoot.appending(".nucleus")
    #else
    return workspaceRoot.appending(".nucleus")
    #endif
}

package func nucleusRunRegistryRoot(workspaceRoot: FilePath) -> FilePath {
    nucleusLogRoot(workspaceRoot: workspaceRoot).appending("runs")
}

package func nucleusCacheLayout(
    environment: [String: String]
) -> ColliderCacheLayout {
    #if os(macOS)
    let root =
        (try? MacOSHostStorageLayout.current().cacheRoot)
        ?? FilePath(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/Nucleus/Collider").path)
    #else
    let base: FilePath
    if let value = environment["XDG_CACHE_HOME"], !value.isEmpty {
        base = FilePath(value)
    } else if let home = environment["HOME"], !home.isEmpty {
        base = FilePath(home).appending(".cache")
    } else {
        base = FilePath(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache", isDirectory: true).path)
    }
    let root = base.appending("nucleus")
    #endif
    return ColliderCacheLayout(
        root: root,
        downloadNamespace: FilePath("downloads"))
}

package struct WorkspaceContext: Sendable {
    package let root: FilePath
    package let environment: [String: String]
    package let cacheRoot: FilePath
    package let nativeSDKRoot: FilePath
    package let hostBuildRoot: FilePath
    package let artifactRoot: FilePath
    package let logRoot: FilePath
    package let runtime: ColliderRuntime
    package let console: CommandConsole
    package let hostPhases: HostPhaseRecorder
    package let ociConfiguration: OCIRuntimeConfiguration
    let swiftPackageGraphs: SwiftPackageGraphResolver

    package init(
        root: FilePath,
        environment: [String: String],
        runtime: ColliderRuntime,
        console: CommandConsole = .processDefault,
        hostPhases: HostPhaseRecorder = HostPhaseRecorder(registry: nil, run: nil),
        ociConfiguration: OCIRuntimeConfiguration? = nil,
        cacheRoot: FilePath? = nil,
        hostBuildRoot requestedHostBuildRoot: FilePath? = nil,
        artifactRoot requestedArtifactRoot: FilePath? = nil,
        logRoot requestedLogRoot: FilePath? = nil
    ) {
        self.root = root
        var normalizedEnvironment = environment
        let cacheLayout = nucleusCacheLayout(environment: normalizedEnvironment)
        let resolvedCacheRoot = cacheRoot ?? cacheLayout.root
        #if os(macOS)
        let hostLayout = try? MacOSHostStorageLayout.current()
        let defaultNativeSDKRoot =
            hostLayout?.nativeSDKs
            .appending("linux-\(RunnerPlatform.current.architecture.rawValue)")
            ?? resolvedCacheRoot.appending(
                "native-sdks/linux-\(RunnerPlatform.current.architecture.rawValue)")
        #else
        let defaultNativeSDKRoot = resolvedCacheRoot.appending(
            "nucleus-native-sdk/linux-\(RunnerPlatform.current.architecture.rawValue)")
        #endif
        let resolvedNativeSDKRoot =
            normalizedEnvironment["NUCLEUS_NATIVE_SDK_ROOT"]
            .flatMap { $0.isEmpty ? nil : FilePath($0) }
            ?? defaultNativeSDKRoot
        normalizedEnvironment["NUCLEUS_NATIVE_SDK_ROOT"] =
            resolvedNativeSDKRoot.string
        #if os(macOS)
        hostBuildRoot =
            requestedHostBuildRoot ?? hostLayout?.hostBuildState
            ?? resolvedCacheRoot.appending("build")
        artifactRoot =
            requestedArtifactRoot ?? hostLayout?.artifacts
            ?? resolvedCacheRoot.appending("artifacts")
        logRoot = requestedLogRoot ?? nucleusLogRoot(workspaceRoot: root)
        #else
        hostBuildRoot = requestedHostBuildRoot ?? resolvedCacheRoot.appending("build")
        artifactRoot = requestedArtifactRoot ?? resolvedCacheRoot.appending("artifacts")
        logRoot = requestedLogRoot ?? nucleusLogRoot(workspaceRoot: root)
        #endif
        self.environment = normalizedEnvironment
        self.cacheRoot = resolvedCacheRoot
        self.nativeSDKRoot = resolvedNativeSDKRoot
        self.runtime = runtime
        self.console = console
        self.hostPhases = hostPhases
        self.ociConfiguration =
            ociConfiguration ?? nucleusOCIRuntimeConfiguration(workspaceRoot: root)
        swiftPackageGraphs = SwiftPackageGraphResolver(
            cacheRoot: hostBuildRoot.appending("swift-package-graphs"),
            environment: normalizedEnvironment)
    }

    func repository(_ name: String) -> FilePath { root.appending(name) }

    package var stateRoot: FilePath { hostBuildRoot.appending("state") }
    package var taskStateRoot: FilePath { stateRoot.appending("tasks") }
    package var lockRoot: FilePath { stateRoot.appending("locks") }
    package var workRoot: FilePath { hostBuildRoot.appending("work") }

    package var taskEnvironment: [String: String] {
        var environment = sanitizedEnvironment(self.environment)
        environment.removeValue(forKey: "NUCLEUS_RUN_DIR")
        environment.removeValue(forKey: "NUCLEUS_RUN_LOG")
        environment["CCACHE_BASEDIR"] = root.string
        environment["CCACHE_COMPILERCHECK"] = "content"
        environment["CCACHE_DIR"] = cacheRoot.appending("host-ccache").string
        environment["CCACHE_MAXSIZE"] = "50G"
        environment["CCACHE_SLOPPINESS"] =
            "include_file_ctime,include_file_mtime,locale"
        environment["BuildDescriptionInMemoryCacheSize"] = "64"
        environment["BuildDescriptionOnDiskCacheSize"] = "64"
        return environment
    }
}

package func nucleusWorkspaceEnvironment(
    root: FilePath,
    environment: [String: String]
) -> [String: String] {
    var resolved = environment
    resolved["NUCLEUS_WORKSPACE_ROOT"] = root.string
    #if os(macOS)
    if let layout = try? MacOSHostStorageLayout.current() {
        resolved.removeValue(forKey: "XDG_CACHE_HOME")
        resolved["NUCLEUS_BUILD_ROOT"] = layout.hostBuildState.string
        resolved["NUCLEUS_NATIVE_SDK_ROOT"] =
            layout.nativeSDKs
            .appending("linux-arm64").string
        resolved["ANDROID_SDK_ROOT"] = layout.androidSDKs.string
        resolved["ANDROID_HOME"] = layout.androidSDKs.string
    }
    #endif
    return resolved
}
