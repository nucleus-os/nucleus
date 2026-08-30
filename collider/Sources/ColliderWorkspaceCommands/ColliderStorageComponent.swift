import ColliderCore
import SystemPackage

enum ColliderStorageComponent {
    static let descriptor = ComponentDescriptor(
        id: ComponentID(rawValue: "collider-storage"),
        canonicalName: "collider-storage",
        directoryName: ".nucleus")

    static func makeComponent(in context: WorkspaceContext) throws -> ComponentDefinition {
        let owner = descriptor.id
        let root = context.root
        let state = context.stateRoot
        let cache = context.cacheRoot
        return try ComponentDefinition(
            descriptor: descriptor,
            tasks: [],
            entrypoints: [],
            storage: [
                StorageDeclaration(
                    id: "collider-state",
                    owner: owner,
                    producers: [.runtime("task-state")],
                    storageClass: .incremental,
                    root: state,
                    safetyRoot: context.hostBuildRoot,
                    retentionPolicy: .protected),
                StorageDeclaration(
                    id: "host-swiftpm-builds",
                    owner: owner,
                    producers: [.runtime("swiftpm")],
                    storageClass: .incremental,
                    root: context.hostBuildRoot.appending("swiftpm"),
                    safetyRoot: context.hostBuildRoot,
                    // Two levels, not one: a host scratch is per checkout, so a
                    // context sits under `<checkout>/<sanitizer>` rather than
                    // `<sanitizer>` alone. Retaining twice as many for the same
                    // reason -- the reachable set is one checkout's, so every
                    // context belonging to the other counts as unreachable, and
                    // collecting one checkout's work from the other's run is
                    // what giving them separate scratches was meant to stop.
                    retentionPolicy: .taskIdentityContexts(
                        .init(intermediateLevels: 2, naming: .artifactDigestDirectory),
                        retaining: 8)),
                StorageDeclaration(
                    id: "swift-package-graphs",
                    owner: owner,
                    producers: [.runtime("swiftpm-graph")],
                    storageClass: .cache,
                    root: context.hostBuildRoot.appending("swift-package-graphs"),
                    safetyRoot: context.hostBuildRoot,
                    retentionPolicy: .singleWorkingSet),
                StorageDeclaration(
                    id: "language-server-configuration",
                    owner: owner,
                    producers: [.runtime("sourcekit-lsp-publication")],
                    storageClass: .published,
                    root: root.appending(".sourcekit-lsp"),
                    safetyRoot: root,
                    retentionPolicy: .protected),
                StorageDeclaration(
                    id: "run-records",
                    owner: owner,
                    producers: [.runtime("run-registry")],
                    storageClass: .runRecord,
                    root: context.logRoot.appending("runs"),
                    safetyRoot: context.logRoot,
                    retentionPolicy: .boundedHistory(maximumEntries: 20)),
                StorageDeclaration(
                    id: "run-registry-locks",
                    owner: owner,
                    producers: [.runtime("run-registry")],
                    storageClass: .identity,
                    root: context.logRoot.appending("locks"),
                    safetyRoot: context.logRoot,
                    retentionPolicy: .protected),
                StorageDeclaration(
                    id: "run-registry-index",
                    owner: owner,
                    producers: [.runtime("run-registry")],
                    storageClass: .identity,
                    root: context.logRoot.appending("latest"),
                    safetyRoot: context.logRoot,
                    retentionPolicy: .protected),
                StorageDeclaration(
                    id: "apple-container-service-logs",
                    owner: owner,
                    producers: [.runtime("apple-container-service")],
                    storageClass: .diagnostic,
                    root: context.logRoot.appending("service"),
                    safetyRoot: context.logRoot,
                    retentionPolicy: .boundedHistory(maximumEntries: 2)),
                StorageDeclaration(
                    id: "downloads",
                    owner: owner,
                    producers: [.runtime("download-manager")],
                    storageClass: .download,
                    root: cache.appending("downloads"),
                    safetyRoot: cache,
                    retentionPolicy: .singleWorkingSet),
                StorageDeclaration(
                    id: "host-compiler-cache",
                    owner: owner,
                    producers: [.runtime("host-swiftpm")],
                    storageClass: .cache,
                    root: cache.appending("host-ccache"),
                    safetyRoot: cache,
                    retentionPolicy: .toolManagedLimit(
                        maximumBytes: 50 * 1_024 * 1_024 * 1_024)),
                StorageDeclaration(
                    id: "swift-package-cache",
                    owner: owner,
                    producers: [.runtime("swiftpm")],
                    storageClass: .cache,
                    root: cache.appending("swiftpm-user"),
                    safetyRoot: cache,
                    retentionPolicy: .singleWorkingSet),
                StorageDeclaration(
                    id: "swiftpm-host-boundaries",
                    owner: owner,
                    producers: [.runtime("swiftpm")],
                    storageClass: .cache,
                    root: cache.appending("swiftpm"),
                    safetyRoot: cache,
                    // Contexts sit under a target and a sanitizer, as
                    // `linux-arm64/unsanitized/sha256-…`.
                    retentionPolicy: .taskIdentityContexts(
                        .init(intermediateLevels: 2, naming: .artifactDigestDirectory),
                        retaining: 4)),
                StorageDeclaration(
                    id: "swiftpm-tool-host-boundaries",
                    owner: owner,
                    producers: [.runtime("swiftpm")],
                    storageClass: .cache,
                    root: cache.appending("swiftpm-tools"),
                    safetyRoot: cache,
                    // Contexts sit under a tool and a sanitizer, as
                    // `runtime-assembler/unsanitized/sha256-…`.
                    retentionPolicy: .taskIdentityContexts(
                        .init(intermediateLevels: 2, naming: .artifactDigestDirectory),
                        retaining: 4)),
                StorageDeclaration(
                    id: "android-sdk",
                    owner: owner,
                    producers: [.runtime("android-toolchain")],
                    storageClass: .published,
                    root: FilePath(
                        context.environment["ANDROID_SDK_ROOT"]
                            ?? context.cacheRoot.appending("android-sdks").string),
                    safetyRoot: FilePath(
                        context.environment["ANDROID_SDK_ROOT"]
                            ?? context.cacheRoot.appending("android-sdks").string
                    ).removingLastComponent(),
                    retentionPolicy: .singleWorkingSet),
            ])
    }
}
