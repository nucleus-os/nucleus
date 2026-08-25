import ColliderCore
import Foundation
import SystemPackage

/// The one path at which the host-hydrated Repo cache is visible.
let aospSourceInputsTarget = "/inputs/source-inputs"

func aospOutputWorkspace(apiLevel: UInt32) -> PersistentWorkspaceDeclaration {
    PersistentWorkspaceDeclaration(
        identity: PersistentWorkspaceIdentity(
            key: "aosp-output-api\(apiLevel)",
            artifactTarget: nil,
            role: "build"),
        capacityBytes: 300 * 1_024 * 1_024 * 1_024,
        filesystem: .ext4,
        journal: .writeback64MiB,
        // Build output, not authoritative state. It is expensive to rebuild
        // and so is never reclaimed on its own, but a structural change the
        // tool's own incremental state cannot follow leaves no way forward
        // when it cannot be named and removed.
        retentionPolicy: .explicitClean)
}

func aospCompilerCacheWorkspace(
    apiLevel: UInt32
) -> PersistentWorkspaceDeclaration {
    PersistentWorkspaceDeclaration(
        identity: PersistentWorkspaceIdentity(
            key: "aosp-ccache-api\(apiLevel)",
            artifactTarget: nil,
            role: "compiler-cache"),
        capacityBytes: 50 * 1_024 * 1_024 * 1_024,
        filesystem: .ext4,
        journal: .writeback64MiB,
        retentionPolicy: .toolManagedLimit(maximumBytes: 50 * 1_024 * 1_024 * 1_024))
}

func aospSourceWorkspace(apiLevel: UInt32) -> PersistentWorkspaceDeclaration {
    PersistentWorkspaceDeclaration(
        identity: PersistentWorkspaceIdentity(
            key: "aosp-source-api\(apiLevel)",
            artifactTarget: nil,
            role: "source"),
        capacityBytes: 300 * 1_024 * 1_024 * 1_024,
        filesystem: .ext4,
        journal: .writeback64MiB,
        // A working tree checked out from the host-hydrated object store. It
        // exists because AOSP needs case-sensitive files, not because it holds
        // anything the host does not, so it is expensive to rebuild rather
        // than authoritative.
        retentionPolicy: .explicitClean)
}

struct AOSPProductSourceOverlay: Hashable, Sendable {
    let source: FilePath
    let relativeDestination: String
}

struct AOSPProductBuild: Hashable, Sendable {
    let architecture: PlatformArchitecture
    let deviceSource: FilePath
    /// The host-hydrated Repo cache. The materialized source references its
    /// object store rather than copying it, so every execution that mounts the
    /// source volume mounts this too.
    let sourceInputs: FilePath
    let sourceProvenance: FilePath
    let artifactRoot: FilePath
    let sourceWorkspace: PersistentWorkspaceDeclaration
    let outputWorkspace: PersistentWorkspaceDeclaration
    let compilerCacheWorkspace: PersistentWorkspaceDeclaration
    let buildEntrypoint: OCIMountedEntrypoint
    let artifactEntrypoint: OCIMountedEntrypoint
    let signingIdentity: FilePath
    let product: String
    let release: String
    let variant: String
    let buildNumber: String
    let buildTimestamp: UInt64
    let buildJobs: UInt32
    let expectedPlatformSDK: UInt32
    let expectedVendorAPILevel: UInt32
    let environment: [String: String]
    let sourceOverlays: [AOSPProductSourceOverlay]

    init(
        architecture: PlatformArchitecture,
        deviceSource: FilePath,
        sourceInputs: FilePath,
        sourceProvenance: FilePath,
        artifactRoot: FilePath,
        sourceWorkspace: PersistentWorkspaceDeclaration,
        outputWorkspace: PersistentWorkspaceDeclaration,
        compilerCacheWorkspace: PersistentWorkspaceDeclaration,
        buildEntrypoint: OCIMountedEntrypoint,
        artifactEntrypoint: OCIMountedEntrypoint,
        signingIdentity: FilePath,
        product: String,
        release: String,
        variant: String,
        buildNumber: String,
        buildTimestamp: UInt64,
        buildJobs: UInt32,
        expectedPlatformSDK: UInt32,
        expectedVendorAPILevel: UInt32,
        environment: [String: String],
        sourceOverlays: [AOSPProductSourceOverlay] = []
    ) {
        self.architecture = architecture
        self.deviceSource = deviceSource
        self.sourceInputs = sourceInputs
        self.sourceProvenance = sourceProvenance
        self.artifactRoot = artifactRoot
        self.sourceWorkspace = sourceWorkspace
        self.outputWorkspace = outputWorkspace
        self.compilerCacheWorkspace = compilerCacheWorkspace
        self.buildEntrypoint = buildEntrypoint
        self.artifactEntrypoint = artifactEntrypoint
        self.signingIdentity = signingIdentity
        self.product = product
        self.release = release
        self.variant = variant
        self.buildNumber = buildNumber
        self.buildTimestamp = buildTimestamp
        self.buildJobs = buildJobs
        self.expectedPlatformSDK = expectedPlatformSDK
        self.expectedVendorAPILevel = expectedVendorAPILevel
        self.environment = environment
        self.sourceOverlays = sourceOverlays
    }

    var outputMount: OCIPersistentWorkspaceMount {
        OCIPersistentWorkspaceMount(
            workspace: outputWorkspace,
            target: "/src/out",
            access: .readWrite)
    }

    /// Where the container reaches the object store the working tree's git
    /// metadata points at.
    var sourceInputsMount: OCIMount {
        OCIMount(
            source: sourceInputs,
            target: aospSourceInputsTarget,
            access: .readOnly)
    }

    var sourceMount: OCIPersistentWorkspaceMount {
        OCIPersistentWorkspaceMount(
            workspace: sourceWorkspace,
            target: "/src",
            access: .readOnly)
    }

    var readOnlyOutputMount: OCIPersistentWorkspaceMount {
        OCIPersistentWorkspaceMount(
            workspace: outputWorkspace,
            target: "/src/out",
            access: .readOnly)
    }

    var compilerCacheMount: OCIPersistentWorkspaceMount {
        OCIPersistentWorkspaceMount(
            workspace: compilerCacheWorkspace,
            target: "/ccache",
            access: .readWrite)
    }

    /// What this product's images run on.
    var artifactTarget: ArtifactTarget {
        switch architecture {
        case .arm64: .androidARM64(apiLevel: expectedPlatformSDK)
        case .x86_64: .androidX86_64(apiLevel: expectedPlatformSDK)
        }
    }

    var assembledDeviceSource: FilePath {
        artifactRoot.appending("product-input")
    }

    /// What every execution the shared builder produces reaches on the host,
    /// whichever entrypoint it selects.
    ///
    /// One function builds them all, so one definition says what they reach:
    /// the entrypoint image, the directory the entrypoint executable is
    /// mounted from, and the object store the working tree's Git metadata
    /// points at.
    func hostEffects(entrypoint: OCIMountedEntrypoint) -> [ActionEffect] {
        [
            ActionEffect(.read, scope: .input(entrypoint.image.path)),
            entrypoint.effect,
            ActionEffect(.read, scope: .input(sourceInputs)),
        ]
    }
}

func aospProductDefinitionDigest(
    deviceSource: FilePath,
    sourceOverlays: [AOSPProductSourceOverlay],
    files: ActionFileSystem
) throws -> ArtifactDigest {
    var bytes = try files.digest(tree: deviceSource).bytes
    for overlay in sourceOverlays.sorted(by: {
        $0.relativeDestination < $1.relativeDestination
    }) {
        bytes += Array(overlay.relativeDestination.utf8)
        bytes.append(0)
        bytes += try files.digest(tree: overlay.source).bytes
    }
    return ArtifactDigest.sha256(Data(bytes))
}
