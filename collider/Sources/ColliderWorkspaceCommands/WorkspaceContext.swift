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
    buildStore: FilePath?,
    verifying: Bool = false
) -> String {
    let domain =
        buildStore
        ?? FilePath(
            URL(fileURLWithPath: workspaceRoot.string)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path)
    // A verifying production owns its own workspaces. Sharing them would let
    // the second production build on what the first left behind, which reports
    // reuse as reproduction and destroys the intermediates the first would be
    // compared against. Ownership is placement and never reaches an identity,
    // so the two productions still answer for the same one.
    let domainName = verifying ? domain.string + verificationScratchSuffix : domain.string
    return ArtifactHasher.digest(bytes: Array(domainName.utf8)).hexadecimal
}

package func nucleusOCIRuntimeConfiguration(
    workspaceRoot: FilePath,
    verifying: Bool = false
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
        buildStore: buildStore,
        verifying: verifying)
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
    /// Collects what every plan this invocation freezes read, so the command
    /// that owns the invocation can decide whether the source it consumed
    /// changed while it ran. Absent when this invocation does not revalidate.
    package let sourceRevalidation: SourceRevalidation?
    private let requestedOCIConfiguration: OCIRuntimeConfiguration?
    /// Follows `producesIntoVerificationScratch`, because which workspaces a
    /// production owns is decided by whether it is verifying.
    package var ociConfiguration: OCIRuntimeConfiguration {
        requestedOCIConfiguration
            ?? nucleusOCIRuntimeConfiguration(
                workspaceRoot: root,
                verifying: producesIntoVerificationScratch)
    }
    let swiftPackageGraphs: SwiftPackageGraphResolver

    package init(
        root: FilePath,
        environment: [String: String],
        runtime: ColliderRuntime,
        console: CommandConsole = .processDefault,
        hostPhases: HostPhaseRecorder = HostPhaseRecorder(registry: nil, run: nil),
        sourceRevalidation: SourceRevalidation? = nil,
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
        self.sourceRevalidation = sourceRevalidation
        requestedOCIConfiguration = ociConfiguration
        swiftPackageGraphs = SwiftPackageGraphResolver(
            cacheRoot: Self.hostPackageGraphRoot(hostBuildRoot: hostBuildRoot),
            environment: normalizedEnvironment,
            identityPathMap: Self.identityPathMap(
                root: root,
                cacheRoot: resolvedCacheRoot,
                hostBuildRoot: hostBuildRoot,
                artifactRoot: artifactRoot,
                identityRoot: identityRoot,
                logRoot: logRoot))
    }

    func repository(_ name: String) -> FilePath { root.appending(name) }

    /// The placement-only roots every identity in this workspace resolves
    /// through. Task identities, SwiftPM task ids, host scratch directories,
    /// and container workspaces all use this one definition, because a
    /// disagreement between them would place the same build in two locations
    /// while claiming they were the same.
    /// Produce into a location beside the retained one instead of into it.
    ///
    /// A build reuses one working set per identity, so it never has an
    /// opportunity to disagree with itself and its bytes cannot be checked
    /// against anything. Where a package manager builds is not part of what it
    /// builds, so directing the same identity at a second location produces it
    /// independently and leaves the retained result to compare against.
    package var producesIntoVerificationScratch = false

    package var identityPathMap: IdentityPathMap {
        Self.identityPathMap(
            root: root,
            cacheRoot: cacheRoot,
            hostBuildRoot: hostBuildRoot,
            artifactRoot: artifactRoot,
            identityRoot: identityRoot,
            logRoot: logRoot)
    }

    /// Every root a path in this workspace may sit under.
    ///
    /// Build intermediates, staged artifacts, and durable identity material
    /// are named individually rather than by the one directory that happens to
    /// hold them, because that directory is not the same directory in both
    /// layouts. Without a machine build store the three live under the cache
    /// root; with one they move beside it, under the store's state root. Only
    /// their own names exist in both, so only their own names make the two
    /// layouts agree -- which is the same requirement that makes two checkouts
    /// agree, applied to one host that can be provisioned two ways. The log
    /// root moves the same way, from inside the checkout to inside the store,
    /// and lanes that name their own log directory put it in an identity.
    ///
    /// A root that is literally another root needs one name, not two, so the
    /// list is reduced by path in a fixed order. Deriving that order from the
    /// paths would make it a property of placement again.
    /// Where host SwiftPM builds this checkout.
    ///
    /// One name, one directory per checkout. Task identity resolves paths
    /// through the declared roots, so both checkouts canonicalize this to
    /// `swiftpm-scratch` and a build done in one is still reusable by the
    /// other -- which is the whole point of placement-independent identity.
    /// The directory itself cannot be shared: SwiftPM records absolute source
    /// paths in its incremental state, so a scratch written by a checkout at
    /// one path is fully rebuilt by a checkout at another. That is what the
    /// authoritative checkout and CI's own checkout were doing to each other
    /// on every alternation, at 437 seconds a time.
    ///
    /// The container case is different and is left alone: there the checkout is
    /// mounted at a canonical path, so the two genuinely are the same to
    /// SwiftPM and one workspace is correct.
    /// Where package-graph resolution keeps its workspace state.
    ///
    /// Resolving writes: SwiftPM materializes workspace state into the scratch
    /// and compiled manifests into the cache. The machine build store admits
    /// one writer, so a resolver rooted there can only be driven by the
    /// builder, and every other account fails -- not merely when the graph
    /// changes, which is what made this look intermittent, but whenever
    /// SwiftPM opens either directory for writing.
    ///
    /// So it belongs to the account resolving. That alone is not enough: the
    /// scratch holds the dependency checkouts, and their paths reach task
    /// identity, so an undeclared per-account root puts a home directory into
    /// every identity that names one. It is declared below for the same reason
    /// the per-checkout SwiftPM scratch is -- two accounts resolve into two
    /// directories and identity cannot tell them apart.
    static func hostPackageGraphRoot(hostBuildRoot: FilePath) -> FilePath {
        #if os(macOS)
        return MacOSHostStorageLayout.developerOwned().developerRoot
            .appending("swift-package-graphs")
        #else
        return hostBuildRoot.appending("swift-package-graphs")
        #endif
    }

    static func hostSwiftPMScratchRoot(
        root: FilePath,
        hostBuildRoot: FilePath
    ) -> FilePath {
        hostBuildRoot
            .appending("swiftpm")
            .appending(
                ArtifactHasher.digest(bytes: Array(root.string.utf8))
                    .hexadecimal
                    .prefix(16)
                    .description)
    }

    static func identityPathMap(
        root: FilePath,
        cacheRoot: FilePath,
        hostBuildRoot: FilePath,
        artifactRoot: FilePath,
        identityRoot: FilePath,
        logRoot: FilePath
    ) -> IdentityPathMap {
        var seen: Set<FilePath> = []
        var roots: [IdentityPathRoot] = []
        for (name, path) in [
            ("workspace", root), ("cache", cacheRoot), ("build", hostBuildRoot),
            ("artifacts", artifactRoot), ("identity", identityRoot),
            ("logs", logRoot),
            ("swiftpm-scratch", hostSwiftPMScratchRoot(root: root, hostBuildRoot: hostBuildRoot)),
            ("package-graphs", hostPackageGraphRoot(hostBuildRoot: hostBuildRoot)),
        ] where seen.insert(path).inserted {
            roots.append(IdentityPathRoot(name: name, path: path))
        }
        return IdentityPathMap(roots: roots)
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
    ///
    /// Declared roots overlap. Without a machine build store the build,
    /// artifact, and identity roots all sit under the cache root; with one
    /// they move beside it, but the per-checkout SwiftPM scratch sits under
    /// the build root in both. So more than one mapping matches the same file,
    /// and which one applies is decided by order -- in opposite directions:
    ///
    ///     swiftc -file-prefix-map A=/A -file-prefix-map A/b=/B   -> /A/b/t
    ///     swiftc -file-prefix-map A/b=/B -file-prefix-map A=/A   -> /B/t
    ///     clang -ffile-prefix-map=A=/A -ffile-prefix-map=A/b=/B  -> /B/t
    ///     clang -ffile-prefix-map=A/b=/B -ffile-prefix-map=A=/A  -> /A/b/t
    ///
    /// Swift takes the first match and Clang the last, so one sequence cannot
    /// serve both and emitting one was emitting it wrong for one of them. In
    /// name order the containing root reached the scratch first, and Swift
    /// recorded it as `/nucleus-build/swiftpm/<digest of the checkout path>`:
    /// the placement this mapping exists to erase, reintroduced by the order
    /// rather than by any value. Each list is therefore built to put the most
    /// specific root where that compiler looks for it.
    ///
    /// The ranking is containment, not path length. Length is a property of
    /// where a checkout sits -- the authoritative checkout's cache path
    /// outruns its workspace path while a runner work tree's workspace path
    /// outruns both, so ordering by it emitted the same revision's flags in
    /// two sequences and lowered it to two identities in one shared store.
    /// Containment is structural: the scratch is inside the build root in
    /// every checkout. Roots that do not overlap are ranked by name, where the
    /// sequence is arbitrary and only has to be fixed.
    package var filePrefixMapFlags: (swift: [String], clang: [String]) {
        let ranked = identityPathMap.roots
            .map { root in
                (
                    root: root,
                    depth: identityPathMap.roots.count(where: { other in
                        other.path != root.path
                            && root.path.starts(with: other.path)
                    })
                )
            }
            .sorted {
                $0.depth != $1.depth
                    ? $0.depth > $1.depth : $0.root.name < $1.root.name
            }
            .map { "\($0.root.path.string)=\(Self.mappedPrefix(for: $0.root))" }
        return (
            swift: ranked.flatMap { ["-file-prefix-map", $0] },
            clang: ranked.reversed().map { "-ffile-prefix-map=\($0)" }
        )
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
