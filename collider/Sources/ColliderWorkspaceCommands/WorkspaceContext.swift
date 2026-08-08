import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

package let nucleusOCIRuntimeConfiguration = OCIRuntimeConfiguration(
    isolatedNetwork: "nucleus-build-internal",
    guestHome: "/home/nucleus-build",
    managedLabels: ["dev.nucleus.collider.managed=true"],
    loggerLabel: "dev.nucleus.collider.apple-container")

package let nucleusSwiftPMEnvironmentProjection = EnvironmentProjection(
    names: ["LANG", "LC_ALL", "TZ", "TERM"],
    prefixes: ["NUCLEUS_", "SWIFTPM_", "CCACHE_"],
    excludedNames: ["NUCLEUS_NATIVE_SDK_ROOT"])

package func nucleusCacheLayout(
    environment: [String: String]
) -> ColliderCacheLayout {
    let root: FilePath
    if let value = environment["XDG_CACHE_HOME"], !value.isEmpty {
        root = FilePath(value)
    } else if let home = environment["HOME"], !home.isEmpty {
        root = FilePath(home).appending(".cache")
    } else {
        root = FilePath(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache", isDirectory: true).path)
    }
    return ColliderCacheLayout(
        root: root,
        downloadNamespace: FilePath("nucleus/downloads"))
}

package struct WorkspaceContext: Sendable {
    package let root: FilePath
    package let environment: [String: String]
    package let cacheRoot: FilePath
    package let nativeSDKRoot: FilePath
    package let runtime: ColliderRuntime
    package let console: CommandConsole
    package let ociConfiguration: OCIRuntimeConfiguration
    let swiftPackageGraphs: SwiftPackageGraphResolver

    package init(
        root: FilePath,
        environment: [String: String],
        runtime: ColliderRuntime,
        console: CommandConsole = .processDefault,
        ociConfiguration: OCIRuntimeConfiguration = nucleusOCIRuntimeConfiguration
    ) {
        self.root = root
        var normalizedEnvironment = environment
        let cacheLayout = nucleusCacheLayout(environment: normalizedEnvironment)
        let resolvedCacheRoot = cacheLayout.root
        let resolvedNativeSDKRoot =
            normalizedEnvironment["NUCLEUS_NATIVE_SDK_ROOT"]
            .flatMap { $0.isEmpty ? nil : FilePath($0) }
            ?? resolvedCacheRoot.appending(
                "nucleus/nucleus-native-sdk/linux-\(RunnerPlatform.current.architecture.rawValue)")
        normalizedEnvironment["NUCLEUS_NATIVE_SDK_ROOT"] =
            resolvedNativeSDKRoot.string
        self.environment = normalizedEnvironment
        self.cacheRoot = resolvedCacheRoot
        self.nativeSDKRoot = resolvedNativeSDKRoot
        self.runtime = runtime
        self.console = console
        self.ociConfiguration = ociConfiguration
        swiftPackageGraphs = SwiftPackageGraphResolver(
            cacheRoot: root.appending(".nucleus/swift-package-graphs"),
            environment: normalizedEnvironment)
    }

    func repository(_ name: String) -> FilePath { root.appending(name) }

    package var taskEnvironment: [String: String] {
        var environment = sanitizedEnvironment(self.environment)
        environment.removeValue(forKey: "NUCLEUS_RUN_DIR")
        environment.removeValue(forKey: "NUCLEUS_RUN_LOG")
        environment["CCACHE_BASEDIR"] = root.string
        environment["CCACHE_COMPILERCHECK"] = "content"
        environment["CCACHE_DIR"] = cacheRoot.appending("nucleus/host-ccache").string
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
    if let contract = try? MacOSBuilderContract.load(root: root) {
        if resolved["XDG_CACHE_HOME"]?.isEmpty != false {
            resolved["XDG_CACHE_HOME"] = contract.environment.xdgCacheHome
        }
        if resolved["NUCLEUS_NATIVE_SDK_ROOT"]?.isEmpty != false {
            resolved["NUCLEUS_NATIVE_SDK_ROOT"] = contract.environment.nativeSDKRoot
        }
        if resolved["ANDROID_SDK_ROOT"]?.isEmpty != false {
            resolved["ANDROID_SDK_ROOT"] = contract.environment.androidSDKRoot
        }
        if resolved["ANDROID_HOME"]?.isEmpty != false {
            resolved["ANDROID_HOME"] = contract.environment.androidSDKRoot
        }
    }
    #endif
    return resolved
}
