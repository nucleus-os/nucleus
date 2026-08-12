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
                    cleanupPolicy: .protected,
                    retention: "task state and workflow locks remain with host build state"),
                StorageDeclaration(
                    id: "host-swiftpm-builds",
                    owner: owner,
                    producers: [.runtime("swiftpm")],
                    storageClass: .incremental,
                    root: context.hostBuildRoot.appending("swiftpm"),
                    safetyRoot: context.hostBuildRoot,
                    cleanupPolicy: .explicitClean,
                    retention: "host SwiftPM build contexts remain reusable until explicit clean"),
                StorageDeclaration(
                    id: "swift-package-graphs",
                    owner: owner,
                    producers: [.runtime("swiftpm-graph")],
                    storageClass: .cache,
                    root: context.hostBuildRoot.appending("swift-package-graphs"),
                    safetyRoot: context.hostBuildRoot,
                    cleanupPolicy: .explicitClean,
                    retention: "resolved package graphs remain reusable until explicit clean"),
                StorageDeclaration(
                    id: "language-server-configuration",
                    owner: owner,
                    producers: [.runtime("sourcekit-lsp-publication")],
                    storageClass: .published,
                    root: root.appending(".sourcekit-lsp"),
                    safetyRoot: root,
                    cleanupPolicy: .protected,
                    retention: "the generated editor build configuration remains published"),
                StorageDeclaration(
                    id: "run-records",
                    owner: owner,
                    producers: [.runtime("run-registry")],
                    storageClass: .runRecord,
                    root: context.logRoot.appending("runs"),
                    safetyRoot: context.logRoot,
                    cleanupPolicy: .automaticRetention,
                    retention:
                        "running records, the 20 newest terminal records, and the newest failed record are retained"
                ),
                StorageDeclaration(
                    id: "downloads",
                    owner: owner,
                    producers: [.runtime("download-manager")],
                    storageClass: .download,
                    root: cache.appending("downloads"),
                    safetyRoot: cache,
                    cleanupPolicy: .protected,
                    retention:
                        "content-addressed downloads remain while referenced by the resolved graph"
                ),
                StorageDeclaration(
                    id: "host-compiler-cache",
                    owner: owner,
                    producers: [.runtime("host-swiftpm")],
                    storageClass: .cache,
                    root: cache.appending("host-ccache"),
                    safetyRoot: cache,
                    cleanupPolicy: .explicitClean,
                    retention: "host compiler results remain reusable until explicit clean"),
                StorageDeclaration(
                    id: "swift-package-cache",
                    owner: owner,
                    producers: [.runtime("swiftpm")],
                    storageClass: .cache,
                    root: cache.appending("swiftpm-user"),
                    safetyRoot: cache,
                    cleanupPolicy: .explicitClean,
                    retention: "locked Swift package sources remain reusable until explicit clean"),
                StorageDeclaration(
                    id: "swiftpm-host-boundaries",
                    owner: owner,
                    producers: [.runtime("swiftpm")],
                    storageClass: .cache,
                    root: cache.appending("swiftpm"),
                    safetyRoot: cache,
                    cleanupPolicy: .explicitClean,
                    retention:
                        "host-resolved dependency inputs and bounded Linux product exports remain reusable until explicit clean"
                ),
                StorageDeclaration(
                    id: "swiftpm-tool-host-boundaries",
                    owner: owner,
                    producers: [.runtime("swiftpm")],
                    storageClass: .cache,
                    root: cache.appending("swiftpm-tools"),
                    safetyRoot: cache,
                    cleanupPolicy: .explicitClean,
                    retention:
                        "host-resolved tool dependency inputs and bounded Linux tool exports remain reusable until explicit clean"
                ),
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
                            ?? context.cacheRoot.appending("android-sdks").string),
                    cleanupPolicy: .protected,
                    retention: "the pinned Android SDK remains provisioned"),
            ])
    }
}
