import ColliderCore
import ColliderRuntime
import Foundation
import Synchronization
import SystemPackage

private let activeCommandLogging = Mutex<CommandLogging?>(nil)
private let activeCancellation = Mutex<RuntimeCancellation?>(nil)
private let activeRuntime = Mutex<ColliderRuntime?>(nil)

package let nucleusOCIRuntimeConfiguration = OCIRuntimeConfiguration(
    externalNetwork: "default",
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

package func setActiveCommandRuntime(
    logging: CommandLogging?,
    cancellation: RuntimeCancellation?,
    runtime: ColliderRuntime?
) {
    activeCommandLogging.withLock { $0 = logging }
    activeCancellation.withLock { $0 = cancellation }
    activeRuntime.withLock { $0 = runtime }
}

package struct WorkspaceContext: Sendable {
    package let root: FilePath
    package let environment: [String: String]
    package let cacheRoot: FilePath
    package let nativeSDKRoot: FilePath
    package let runtime: ColliderRuntime
    package let ociConfiguration: OCIRuntimeConfiguration

    package init(
        root: FilePath,
        environment: [String: String],
        runtime: ColliderRuntime? = nil,
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
        self.runtime =
            runtime
            ?? ColliderRuntime(
                downloadCacheRoot: cacheLayout.downloads,
                ociConfiguration: ociConfiguration)
        self.ociConfiguration = ociConfiguration
    }

    package static func load() throws -> WorkspaceContext {
        var environment = ProcessInfo.processInfo.environment
        let root = try resolveWorkspaceRoot(environment: environment)
        environment["NUCLEUS_WORKSPACE_ROOT"] = root.string
        #if os(macOS)
        if let contract = try? MacOSBuilderContract.load(root: root) {
            if environment["XDG_CACHE_HOME"]?.isEmpty != false {
                environment["XDG_CACHE_HOME"] = contract.environment.xdgCacheHome
            }
            if environment["NUCLEUS_NATIVE_SDK_ROOT"]?.isEmpty != false {
                environment["NUCLEUS_NATIVE_SDK_ROOT"] =
                    contract.environment.nativeSDKRoot
            }
            if environment["ANDROID_SDK_ROOT"]?.isEmpty != false {
                environment["ANDROID_SDK_ROOT"] = contract.environment.androidSDKRoot
            }
            if environment["ANDROID_HOME"]?.isEmpty != false {
                environment["ANDROID_HOME"] = contract.environment.androidSDKRoot
            }
        }
        #endif
        let logging = activeCommandLogging.withLock { $0 }
        let cancellation = activeCancellation.withLock { $0 } ?? RuntimeCancellation()
        let cacheLayout = nucleusCacheLayout(environment: environment)
        let runtime =
            activeRuntime.withLock { $0 }
            ?? ColliderRuntime(
                logging: logging,
                cancellation: cancellation,
                downloadCacheRoot: cacheLayout.downloads,
                ociConfiguration: nucleusOCIRuntimeConfiguration)
        if let logging {
            environment["NUCLEUS_RUN_DIR"] = logging.run.directory.string
            environment["NUCLEUS_RUN_LOG"] =
                logging.run.directory
                .appending("run.log").string
        }
        return WorkspaceContext(
            root: root,
            environment: environment,
            runtime: runtime)
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
