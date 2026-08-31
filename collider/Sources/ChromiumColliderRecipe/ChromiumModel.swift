import ColliderCore
import SystemPackage

package struct ChromiumSourceRepository: Codable, Hashable, Sendable {
    package let name: String
    package let checkoutPath: String
    package let remote: String
    package let upstreamRemote: String
    package let upstreamCommit: String
    package let commit: String
    package let tree: String

    package init(
        name: String,
        checkoutPath: String,
        remote: String,
        upstreamRemote: String,
        upstreamCommit: String,
        commit: String,
        tree: String
    ) {
        self.name = name
        self.checkoutPath = checkoutPath
        self.remote = remote
        self.upstreamRemote = upstreamRemote
        self.upstreamCommit = upstreamCommit
        self.commit = commit
        self.tree = tree
    }
}

package struct ChromiumDepotToolsLock: Codable, Hashable, Sendable {
    package let remote: String
    package let commit: String

    package init(remote: String, commit: String) {
        self.remote = remote
        self.commit = commit
    }
}

package struct ChromiumSourceLock: Codable, Hashable, Sendable {
    package let cefBranch: String
    package let chromiumVersion: String
    package let buildHostPlatform: String
    package let devtoolsRollupPlatform: String
    package let repositories: [ChromiumSourceRepository]
    package let depotTools: ChromiumDepotToolsLock

    package init(
        cefBranch: String,
        chromiumVersion: String,
        buildHostPlatform: String,
        devtoolsRollupPlatform: String,
        repositories: [ChromiumSourceRepository],
        depotTools: ChromiumDepotToolsLock
    ) {
        self.cefBranch = cefBranch
        self.chromiumVersion = chromiumVersion
        self.buildHostPlatform = buildHostPlatform
        self.devtoolsRollupPlatform = devtoolsRollupPlatform
        self.repositories = repositories
        self.depotTools = depotTools
    }
}

package struct ChromiumSourcePreparation: Hashable, Sendable {
    package let sourceID: String
    package let sourceRoot: FilePath
    package let sourceGenerations: FilePath
    package let current: FilePath
    package let depotTools: FilePath
    package let linuxHostCIPDAdapter: FilePath
    package let sourceLockFile: FilePath
    package let sourceLock: ChromiumSourceLock
    package let environment: [String: String]

    package init(
        sourceID: String,
        sourceRoot: FilePath,
        sourceGenerations: FilePath,
        current: FilePath,
        depotTools: FilePath,
        linuxHostCIPDAdapter: FilePath,
        sourceLockFile: FilePath,
        sourceLock: ChromiumSourceLock,
        environment: [String: String]
    ) {
        self.sourceID = sourceID
        self.sourceRoot = sourceRoot
        self.sourceGenerations = sourceGenerations
        self.current = current
        self.depotTools = depotTools
        self.linuxHostCIPDAdapter = linuxHostCIPDAdapter
        self.sourceLockFile = sourceLockFile
        self.sourceLock = sourceLock
        self.environment = environment
    }
}

package enum ChromiumProduct: String, CaseIterable, Hashable, Sendable {
    case cef
    case browser
}

package struct ChromiumLinuxTarget: Hashable, Sendable {
    package let architecture: PlatformArchitecture

    package init(architecture: PlatformArchitecture) {
        precondition(architecture == .arm64 || architecture == .x86_64)
        self.architecture = architecture
    }

    package var identifier: String { "linux-\(architecture.rawValue)" }

    package var artifactTarget: ArtifactTarget {
        switch architecture {
        case .arm64: .linuxARM64
        case .x86_64: .linuxX86_64
        }
    }

    package var gnCPU: String {
        switch architecture {
        case .arm64: "arm64"
        case .x86_64: "x64"
        }
    }

    package var cefBuildFlag: String {
        switch architecture {
        case .arm64: "--arm64-build"
        case .x86_64: "--x64-build"
        }
    }

    package var cefPlatformName: String {
        switch architecture {
        case .arm64: "linuxarm64"
        case .x86_64: "linux64"
        }
    }
}

package let chromiumLinuxTargets = PlatformArchitecture.allCases.map {
    ChromiumLinuxTarget(architecture: $0)
}

// V8 deliberately uses its x64 builtins profile for both x64 and arm64.
package let chromiumV8BuiltinsPGOProfile = "x64.profile"
package let chromiumLinuxClangRoot = "third_party/llvm-build/Linux_x64"

package func chromiumOutputWorkspace(
    product: ChromiumProduct,
    target: ChromiumLinuxTarget
) -> PersistentWorkspaceDeclaration {
    PersistentWorkspaceDeclaration(
        identity: PersistentWorkspaceIdentity(
            key: "chromium-\(product.rawValue)-output",
            artifactTarget: target.artifactTarget,
            role: "build"),
        capacityBytes: 150 * 1_024 * 1_024 * 1_024,
        filesystem: .ext4,
        journal: .writeback64MiB)
}

package func chromiumCompilerCacheWorkspace(
    target: ChromiumLinuxTarget
) -> PersistentWorkspaceDeclaration {
    PersistentWorkspaceDeclaration(
        identity: PersistentWorkspaceIdentity(
            key: "chromium-ccache",
            artifactTarget: target.artifactTarget,
            role: "compiler-cache"),
        capacityBytes: 30 * 1_024 * 1_024 * 1_024,
        filesystem: .ext4,
        journal: .writeback64MiB,
        retentionPolicy: .toolManagedLimit(maximumBytes: 30 * 1_024 * 1_024 * 1_024))
}

package func chromiumSourceWorkspace(
    target: ChromiumLinuxTarget
) -> PersistentWorkspaceDeclaration {
    PersistentWorkspaceDeclaration(
        identity: PersistentWorkspaceIdentity(
            key: "chromium-source",
            artifactTarget: target.artifactTarget,
            role: "source"),
        capacityBytes: 64 * 1_024 * 1_024 * 1_024,
        filesystem: .ext4,
        journal: .writeback64MiB,
        retentionPolicy: .explicitClean,
        // Resident. Unlike AOSP there is no second copy to fall back on: the
        // host holds the pinned inputs but not a materialized tree, so
        // collecting this one turns the next Chromium build into a full
        // source materialization.
        residency: .resident(
            reason: "the only materialized Chromium tree; the host holds "
                + "pinned inputs but nothing checked out"))
}

package struct ChromiumProductBuild: Hashable, Sendable {
    package let product: ChromiumProduct
    package let target: ChromiumLinuxTarget
    package let sourceRoot: FilePath
    package let buildManifest: FilePath
    package let inputRoot: FilePath
    package let sourceWorkspace: PersistentWorkspaceDeclaration
    package let outputWorkspace: PersistentWorkspaceDeclaration
    package let compilerCacheWorkspace: PersistentWorkspaceDeclaration
    package let entrypoint: OCIMountedEntrypoint
    package let gnArguments: String?
    package let targets: [String]
    package let jobs: UInt32
    package let environment: [String: String]

    package init(
        product: ChromiumProduct,
        target: ChromiumLinuxTarget,
        sourceRoot: FilePath,
        buildManifest: FilePath,
        inputRoot: FilePath,
        sourceWorkspace: PersistentWorkspaceDeclaration,
        outputWorkspace: PersistentWorkspaceDeclaration,
        compilerCacheWorkspace: PersistentWorkspaceDeclaration,
        entrypoint: OCIMountedEntrypoint,
        gnArguments: String? = nil,
        targets: [String],
        jobs: UInt32,
        environment: [String: String]
    ) {
        self.product = product
        self.target = target
        self.sourceRoot = sourceRoot
        self.buildManifest = buildManifest
        self.inputRoot = inputRoot
        self.sourceWorkspace = sourceWorkspace
        self.outputWorkspace = outputWorkspace
        self.compilerCacheWorkspace = compilerCacheWorkspace
        self.entrypoint = entrypoint
        self.gnArguments = gnArguments
        self.targets = targets
        self.jobs = jobs
        self.environment = environment
    }

    package var outputMount: OCIPersistentWorkspaceMount {
        OCIPersistentWorkspaceMount(
            workspace: outputWorkspace,
            target: "/build",
            access: .readWrite)
    }

    package var sourceMount: OCIPersistentWorkspaceMount {
        OCIPersistentWorkspaceMount(
            workspace: sourceWorkspace,
            target: "/source",
            access: .readOnly)
    }

    package var writableSourceMount: OCIPersistentWorkspaceMount {
        OCIPersistentWorkspaceMount(
            workspace: sourceWorkspace,
            target: "/source",
            access: .readWrite)
    }

    package var readOnlyOutputMount: OCIPersistentWorkspaceMount {
        OCIPersistentWorkspaceMount(
            workspace: outputWorkspace,
            target: "/build",
            access: .readOnly)
    }

    package var compilerCacheMount: OCIPersistentWorkspaceMount {
        OCIPersistentWorkspaceMount(
            workspace: compilerCacheWorkspace,
            target: "/ccache",
            access: .readWrite)
    }
}

package struct BrowserArtifactAssembly: Hashable, Sendable {
    package let target: ChromiumLinuxTarget
    package let chromiumSource: FilePath
    package let buildManifest: FilePath
    package let sourceWorkspace: PersistentWorkspaceDeclaration
    package let outputWorkspace: PersistentWorkspaceDeclaration
    package let entrypoint: OCIMountedEntrypoint
    package let distributionRoot: FilePath
    package let launcher: FilePath
    package let desktopTemplate: FilePath
    package let environment: [String: String]

    package init(
        target: ChromiumLinuxTarget,
        chromiumSource: FilePath,
        buildManifest: FilePath,
        sourceWorkspace: PersistentWorkspaceDeclaration,
        outputWorkspace: PersistentWorkspaceDeclaration,
        entrypoint: OCIMountedEntrypoint,
        distributionRoot: FilePath,
        launcher: FilePath,
        desktopTemplate: FilePath,
        environment: [String: String]
    ) {
        self.target = target
        self.chromiumSource = chromiumSource
        self.buildManifest = buildManifest
        self.sourceWorkspace = sourceWorkspace
        self.outputWorkspace = outputWorkspace
        self.entrypoint = entrypoint
        self.distributionRoot = distributionRoot
        self.launcher = launcher
        self.desktopTemplate = desktopTemplate
        self.environment = environment
    }

    package var readOnlyOutputMount: OCIPersistentWorkspaceMount {
        OCIPersistentWorkspaceMount(
            workspace: outputWorkspace,
            target: "/build",
            access: .readOnly)
    }

    package var readOnlySourceMount: OCIPersistentWorkspaceMount {
        OCIPersistentWorkspaceMount(
            workspace: sourceWorkspace,
            target: "/source",
            access: .readOnly)
    }
}

package struct CEFArtifactAssembly: Hashable, Sendable {
    package let target: ChromiumLinuxTarget
    package let chromiumSource: FilePath
    package let buildManifest: FilePath
    package let sourceWorkspace: PersistentWorkspaceDeclaration
    package let outputWorkspace: PersistentWorkspaceDeclaration
    package let entrypoint: OCIMountedEntrypoint
    package let distributionRoot: FilePath
    package let cefCheckout: String
    package let chromiumVersion: String
    package let environment: [String: String]

    package init(
        target: ChromiumLinuxTarget,
        chromiumSource: FilePath,
        buildManifest: FilePath,
        sourceWorkspace: PersistentWorkspaceDeclaration,
        outputWorkspace: PersistentWorkspaceDeclaration,
        entrypoint: OCIMountedEntrypoint,
        distributionRoot: FilePath,
        cefCheckout: String,
        chromiumVersion: String,
        environment: [String: String]
    ) {
        self.target = target
        self.chromiumSource = chromiumSource
        self.buildManifest = buildManifest
        self.sourceWorkspace = sourceWorkspace
        self.outputWorkspace = outputWorkspace
        self.entrypoint = entrypoint
        self.distributionRoot = distributionRoot
        self.cefCheckout = cefCheckout
        self.chromiumVersion = chromiumVersion
        self.environment = environment
    }

    package var readOnlyOutputMount: OCIPersistentWorkspaceMount {
        OCIPersistentWorkspaceMount(
            workspace: outputWorkspace,
            target: "/build",
            access: .readOnly)
    }

    package var readOnlySourceMount: OCIPersistentWorkspaceMount {
        OCIPersistentWorkspaceMount(
            workspace: sourceWorkspace,
            target: "/source",
            access: .readOnly)
    }
}
