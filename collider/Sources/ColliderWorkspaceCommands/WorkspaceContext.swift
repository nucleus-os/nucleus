import ColliderCore
import ColliderPersistence
import ColliderRuntime
import Foundation
import SystemPackage

/// The domain that owns persistent workspaces.
///
/// Where a machine-wide build store exists, the store is that domain: the clean
/// CI checkout and the authoritative development checkout resolve to the same
/// value and therefore select the same volumes, which is the whole point of
/// sharing warm state between them. Without a store, a checkout owns its own
/// workspaces, which is the only correct answer where nothing is shared.
///
/// The value stays a digest rather than becoming absent. Volume names carry it,
/// and two Collider domains sharing one container application root — production
/// and an integration test among them — would otherwise collide on name alone
/// while their labels disagreed.
package func nucleusPersistentWorkspaceOwner(
    workspaceRoot: FilePath,
    buildStore: FilePath?
) -> String {
    let domain =
        buildStore
        ?? FilePath(
            URL(fileURLWithPath: workspaceRoot.string)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path)
    return ArtifactHasher.digest(bytes: Array(domain.string.utf8)).hexadecimal
}

package func nucleusOCIRuntimeConfiguration(
    workspaceRoot: FilePath
) -> OCIRuntimeConfiguration {
    #if os(macOS)
    let buildStore =
        MacOSMachineStorageLayout.buildStoreIsInstalled()
        ? MacOSMachineStorageLayout.buildStore : nil
    #else
    let buildStore: FilePath? = nil
    #endif
    let owner = nucleusPersistentWorkspaceOwner(
        workspaceRoot: workspaceRoot,
        buildStore: buildStore)
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
    excludedNames: [
        "NUCLEUS_NATIVE_SDK_ROOT",
        "NUCLEUS_PRODUCT_SOURCE_AUTHORITY",
        "NUCLEUS_PRODUCT_SOURCE_COMMIT",
        "NUCLEUS_PRODUCT_SOURCE_REF",
        "NUCLEUS_PRODUCT_PRODUCER_TRUST_DOMAIN",
    ])

private let nucleusProductProvenanceEnvironmentNames: Set<String> = [
    "NUCLEUS_PRODUCT_SOURCE_AUTHORITY",
    "NUCLEUS_PRODUCT_SOURCE_COMMIT",
    "NUCLEUS_PRODUCT_SOURCE_REF",
    "NUCLEUS_PRODUCT_PRODUCER_TRUST_DOMAIN",
]

/// Coordinates used to enter and observe one Collider invocation. These values
/// decide how the CLI reaches a checkout or run record, not what any task
/// builds, so allowing them into recipe environments would make equivalent CI
/// and locally initiated builds claim different identities.
private let nucleusInvocationEnvironmentNames: Set<String> = [
    "NUCLEUS_REVALIDATE_SOURCE",
    "NUCLEUS_RUN_DIR",
    "NUCLEUS_RUN_LOG",
    "NUCLEUS_WORKSPACE_ROOT",
]

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
    package let identityRoot: FilePath
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
        identityRoot requestedIdentityRoot: FilePath? = nil,
        logRoot requestedLogRoot: FilePath? = nil
    ) {
        self.root = root
        var normalizedEnvironment = environment
        let effectiveUser = NSUserName()
        if normalizedEnvironment["USER"]?.isEmpty != false {
            normalizedEnvironment["USER"] = effectiveUser
        }
        if normalizedEnvironment["LOGNAME"]?.isEmpty != false {
            normalizedEnvironment["LOGNAME"] = effectiveUser
        }
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
        identityRoot =
            requestedIdentityRoot ?? hostLayout?.identity
            ?? resolvedCacheRoot.appending("identity")
        logRoot = requestedLogRoot ?? nucleusLogRoot(workspaceRoot: root)
        #else
        hostBuildRoot = requestedHostBuildRoot ?? resolvedCacheRoot.appending("build")
        artifactRoot = requestedArtifactRoot ?? resolvedCacheRoot.appending("artifacts")
        identityRoot = requestedIdentityRoot ?? resolvedCacheRoot.appending("identity")
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

    /// The placement-only roots every identity in this workspace resolves
    /// through. Task identities, SwiftPM task ids, host scratch directories,
    /// and container workspaces all use this one definition, because a
    /// disagreement between them would place the same build in two locations
    /// while claiming they were the same.
    package var identityPathMap: IdentityPathMap {
        IdentityPathMap(roots: [
            IdentityPathRoot(name: "workspace", path: root),
            IdentityPathRoot(name: "cache", path: cacheRoot),
        ])
    }

    /// Where a mapped root appears in compiled output.
    ///
    /// A recorded file path must not say which checkout produced an object, or
    /// two builds of one source are not interchangeable however equal their
    /// identities claim to be. The mapped roots are exactly the roots identity
    /// resolves through, so output and identity cannot disagree about what
    /// counts as placement.
    package static func mappedPrefix(for root: IdentityPathRoot) -> String {
        "/nucleus-\(root.name)"
    }

    /// Swift and Clang spellings of that mapping, in the order each expects.
    package var filePrefixMapFlags: (swift: [String], clang: [String]) {
        var swift: [String] = []
        var clang: [String] = []
        for root in identityPathMap.roots {
            let mapping = "\(root.path.string)=\(Self.mappedPrefix(for: root))"
            swift += ["-file-prefix-map", mapping]
            clang.append("-ffile-prefix-map=\(mapping)")
        }
        return (swift, clang)
    }

    package var stateRoot: FilePath { hostBuildRoot.appending("state") }
    package var taskStateRoot: FilePath { stateRoot.appending("tasks") }
    package var lockRoot: FilePath { stateRoot.appending("locks") }
    package var workRoot: FilePath { hostBuildRoot.appending("work") }

    /// The pinned host tools, ahead of anything the invoking environment
    /// offers. A named tool's file digest feeds task identity, so resolution
    /// has to be a property of this repository rather than of whichever shell,
    /// launchd session, or account started the build.
    package var hostToolBinaryDirectories: [FilePath] {
        guard let manifest = try? HostToolManifest.load(root: root) else { return [] }
        return HostToolchain(manifest: manifest, cacheRoot: cacheRoot).binaryDirectories
    }

    package var taskEnvironment: [String: String] {
        var environment = sanitizedEnvironment(self.environment)
        for name
            in nucleusProductProvenanceEnvironmentNames
            .union(nucleusInvocationEnvironmentNames)
        {
            environment.removeValue(forKey: name)
        }
        environment.removeValue(forKey: "LANG")
        environment.removeValue(forKey: "SHELL")
        environment.removeValue(forKey: "TERM")
        environment.removeValue(forKey: "TMPDIR")
        for name in Array(environment.keys) where name.hasPrefix("LC_") {
            environment.removeValue(forKey: name)
        }
        let pinned = hostToolBinaryDirectories.map(\.string)
        environment["PATH"] =
            (pinned + ["/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"])
            .joined(separator: ":")
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

    package func productProvenanceEnvironment(
        from environment: [String: String]? = nil
    ) -> [String: String] {
        (environment ?? self.environment).filter {
            nucleusProductProvenanceEnvironmentNames.contains($0.key)
        }
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
