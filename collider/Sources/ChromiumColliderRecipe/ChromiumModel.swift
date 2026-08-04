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
    package let repositories: [ChromiumSourceRepository]
    package let depotTools: ChromiumDepotToolsLock

    package init(
        cefBranch: String,
        chromiumVersion: String,
        repositories: [ChromiumSourceRepository],
        depotTools: ChromiumDepotToolsLock
    ) {
        self.cefBranch = cefBranch
        self.chromiumVersion = chromiumVersion
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
    package let sourceLockFile: FilePath
    package let sourceLock: ChromiumSourceLock
    package let environment: [String: String]

    package init(
        sourceID: String,
        sourceRoot: FilePath,
        sourceGenerations: FilePath,
        current: FilePath,
        depotTools: FilePath,
        sourceLockFile: FilePath,
        sourceLock: ChromiumSourceLock,
        environment: [String: String]
    ) {
        self.sourceID = sourceID
        self.sourceRoot = sourceRoot
        self.sourceGenerations = sourceGenerations
        self.current = current
        self.depotTools = depotTools
        self.sourceLockFile = sourceLockFile
        self.sourceLock = sourceLock
        self.environment = environment
    }
}

package enum ChromiumProduct: String, Hashable, Sendable {
    case cef
    case browser
}

package struct ChromiumProductBuild: Hashable, Sendable {
    package let product: ChromiumProduct
    package let sourceRoot: FilePath
    package let output: FilePath
    package let depotTools: FilePath
    package let containerImageID: FilePath
    package let gnArguments: String?
    package let targets: [String]
    package let jobs: UInt32
    package let environment: [String: String]

    package init(
        product: ChromiumProduct,
        sourceRoot: FilePath,
        output: FilePath,
        depotTools: FilePath,
        containerImageID: FilePath,
        gnArguments: String? = nil,
        targets: [String],
        jobs: UInt32,
        environment: [String: String]
    ) {
        self.product = product
        self.sourceRoot = sourceRoot
        self.output = output
        self.depotTools = depotTools
        self.containerImageID = containerImageID
        self.gnArguments = gnArguments
        self.targets = targets
        self.jobs = jobs
        self.environment = environment
    }
}

package struct BrowserArtifactAssembly: Hashable, Sendable {
    package let chromiumSource: FilePath
    package let buildOutput: FilePath
    package let distributionRoot: FilePath
    package let launcher: FilePath
    package let desktopTemplate: FilePath
    package let environment: [String: String]

    package init(
        chromiumSource: FilePath,
        buildOutput: FilePath,
        distributionRoot: FilePath,
        launcher: FilePath,
        desktopTemplate: FilePath,
        environment: [String: String]
    ) {
        self.chromiumSource = chromiumSource
        self.buildOutput = buildOutput
        self.distributionRoot = distributionRoot
        self.launcher = launcher
        self.desktopTemplate = desktopTemplate
        self.environment = environment
    }
}

package struct CEFArtifactAssembly: Hashable, Sendable {
    package let chromiumSource: FilePath
    package let buildOutput: FilePath
    package let depotTools: FilePath
    package let distributionRoot: FilePath
    package let cefCheckout: String
    package let chromiumVersion: String
    package let environment: [String: String]

    package init(
        chromiumSource: FilePath,
        buildOutput: FilePath,
        depotTools: FilePath,
        distributionRoot: FilePath,
        cefCheckout: String,
        chromiumVersion: String,
        environment: [String: String]
    ) {
        self.chromiumSource = chromiumSource
        self.buildOutput = buildOutput
        self.depotTools = depotTools
        self.distributionRoot = distributionRoot
        self.cefCheckout = cefCheckout
        self.chromiumVersion = chromiumVersion
        self.environment = environment
    }
}

package struct BrowserInstallation: Hashable, Sendable {
    package let distributionRoot: FilePath
    package let prefix: FilePath
    package let systemSandboxDirectory: FilePath
    package let widevineCandidates: [FilePath]
    package let environment: [String: String]

    package init(
        distributionRoot: FilePath,
        prefix: FilePath,
        systemSandboxDirectory: FilePath = FilePath(
            "/usr/local/libexec/nucleus-browser"),
        widevineCandidates: [FilePath] = [
            FilePath("/opt/google/chrome/WidevineCdm"),
            FilePath("/opt/google/chrome-unstable/WidevineCdm"),
        ],
        environment: [String: String]
    ) {
        self.distributionRoot = distributionRoot
        self.prefix = prefix
        self.systemSandboxDirectory = systemSandboxDirectory
        self.widevineCandidates = widevineCandidates
        self.environment = environment
    }
}
