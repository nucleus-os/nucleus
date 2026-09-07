import ColliderCore
import ColliderPersistence
import Foundation
import LinuxPackageAssembly
import LinuxPackageContracts
import SystemPackage

/// Reports a package cohort this host already carries that the store cannot
/// serve.
///
/// Retention asks this question too, and has to ask it after publication
/// because it also collects what publication leaves behind. The question
/// itself is about state a previous run left, so it can be asked before this
/// run touches anything, and asking it there is what turns a corrupt host into
/// a report in the first seconds rather than one in the last.
package struct LinuxPackageStorageAssertionAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        package let lanes: [LinuxPackageStorageRetentionLane]
        package let productStoreRoot: FilePath

        package func encode(into encoder: inout IdentityEncoder) {
            encoder.appendSequence(lanes) { entry, lane in
                entry.appendEnum(lane.architecture)
                entry.append(path: lane.packageRoot)
            }
            encoder.append(path: productStoreRoot)
        }
    }

    package static let kind: ActionKind = "linux.assert-package-storage"

    private let lanes: [LinuxPackageStorageRetentionLane]
    private let productStoreRoot: FilePath

    package var identity: Identity {
        Identity(lanes: lanes, productStoreRoot: productStoreRoot)
    }

    package var requirements: ActionRequirements {
        ActionRequirements(
            effects: lanes.map {
                ActionEffect(.read, scope: .publication($0.packageRoot))
            } + [
                ActionEffect(.read, scope: .publication(productStoreRoot))
            ],
            executionPlatform: .macOSARM64Native)
    }

    package init(
        lanes: [LinuxPackageStorageRetentionLane],
        productStoreRoot: FilePath
    ) {
        self.lanes = lanes.sorted {
            $0.architecture.rawValue < $1.architecture.rawValue
        }
        self.productStoreRoot = productStoreRoot
    }

    package func execute(in context: ActionContext) async throws {
        let store = LocalProductArtifactStore(root: productStoreRoot)
        for lane in lanes {
            let current = lane.packageRoot.appending("current")
            // A host that has published nothing carries no cohort to be
            // unservable, and a cold machine is not a corrupt one.
            guard
                try context.files.metadataWithoutFollowingSymlinks(for: current)?
                    .type == .symbolicLink
            else { continue }
            let generation = lane.packageRoot.appending(
                try context.files.readSymbolicLink(current))
            let manifestPath = generation.appending(
                "linux-native-package-cohort.json")
            let manifest: LinuxNativePackageCohortPublication
            do {
                manifest = try JSONDecoder().decode(
                    LinuxNativePackageCohortPublication.self,
                    from: Data(context.files.read(manifestPath)))
            } catch {
                throw LinuxPackageStorageAssertionFailure(
                    "could not decode the active package cohort at "
                        + "\(manifestPath): \(error)")
            }
            guard manifest.architecture == lane.architecture else {
                throw LinuxPackageStorageAssertionFailure(
                    "the active package cohort has the wrong architecture: "
                        + manifestPath.string)
            }
            // Only presence, and deliberately not the full publication
            // validation retention performs afterwards. This asks the one
            // question that a run interrupted between a cohort becoming
            // durable and its products reaching the store can answer wrongly,
            // and asking more here would report a host as corrupt for reasons
            // this task cannot distinguish.
            let products = manifest.products.map(\.productArtifact)
            let absent = products.filter { !store.contains($0) }
            guard absent.isEmpty else {
                throw LinuxPackageStorageAssertionFailure(
                    "the active package cohort names \(absent.count) of "
                        + "\(products.count) products the store does not "
                        + "hold: \(manifestPath)")
            }
        }
    }
}

private struct LinuxPackageStorageAssertionFailure: Error,
    CustomStringConvertible, Sendable
{
    let description: String

    init(_ description: String) {
        self.description =
            "Linux package storage assertion failed: \(description)"
    }
}
