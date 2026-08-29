import Foundation
import SystemPackage

/// The machine-wide Collider state a privileged provisioning step installs.
///
/// Every path here is root-owned and lives outside any account's storage, so the
/// interactive developer and the trusted builder identity reach the same state
/// without either one reading the other's home. The contract root itself is
/// writable by neither; only individual declared files within it are, and only
/// where a cross-account protocol requires it.
///
/// `tools/macos-builder/contract.json` declares the same paths for the
/// privileged shell provisioning, and `MacOSBuilderContract` rejects any
/// disagreement. These constants are compiled in because the machine decides
/// which inode serializes its execution; a checkout must not be able to move
/// that decision by editing a file it owns.
package enum MacOSMachineStorageLayout {
    package static let contractRoot = FilePath("/Library/Nucleus/Builder")

    /// The one inode every Collider execution on a provisioned host locks.
    package static var hostExecutionAdmission: FilePath {
        contractRoot.appending("host-execution.lock")
    }

    /// Persistent fail-closed state installed by the privileged quarantine
    /// boundary. Only retirement removes the root that contains it.
    package static var builderQuarantine: FilePath {
        contractRoot.appending("quarantined")
    }

    /// The root-owned launcher that runs a build as the identity permitted to
    /// write the store. Named in refusals so an account that cannot execute is
    /// told what can.
    package static let builderLauncher = FilePath("/usr/local/bin/nucleus-builder-run")

    /// Every byte of Collider's retained build state.
    ///
    /// Two accounts execute on this host, and the state they share is neither
    /// one's property, so it lives outside both homes. The builder writes it and
    /// a second group reads it, which is what lets the interactive developer
    /// inspect run records and finished artifacts without privilege and without
    /// the builder's home being readable.
    package static let buildStore = FilePath("/Library/Nucleus/Collider")

    /// Durable service metadata and configuration.
    package static var buildStoreConfiguration: FilePath {
        buildStore.appending("configuration")
    }

    /// The Apple-container application root, persistent volumes, build
    /// intermediates, task state, staged artifacts, and the product store.
    package static var buildStoreState: FilePath { buildStore.appending("state") }

    /// Downloads, SDKs, package and repository inputs, and compiler caches.
    package static var buildStoreCache: FilePath { buildStore.appending("cache") }

    /// Service logs and durable run records.
    package static var buildStoreLogs: FilePath { buildStore.appending("logs") }

    /// Whether a privileged provisioning step has installed the store.
    ///
    /// Presence selects it, exactly as it does for the execution lease. A host
    /// with no store runs Collider from one account into that account's own
    /// storage, which is the only correct answer where no second identity
    /// exists to share with.
    package static func buildStoreIsInstalled() -> Bool {
        (try? URL(fileURLWithPath: buildStore.string)
            .resourceValues(forKeys: [.isDirectoryKey])
            .isDirectory) == true
    }
}
