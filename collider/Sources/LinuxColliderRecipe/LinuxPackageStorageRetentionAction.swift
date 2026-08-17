import ColliderCore
import ColliderPersistence
import Foundation
import LinuxPackageContracts
import SystemPackage

package struct LinuxPackageStorageRetentionLane: Hashable, Sendable {
    package let architecture: PlatformArchitecture
    package let packageRoot: FilePath

    package init(
        architecture: PlatformArchitecture,
        packageRoot: FilePath
    ) {
        self.architecture = architecture
        self.packageRoot = packageRoot
    }
}

package struct LinuxPackageStorageRetentionAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        package let lanes: [LinuxPackageStorageRetentionLane]
        package let productStoreRoot: FilePath
        package let rollbackGenerationCount: UInt32

        package func encode(into encoder: inout IdentityEncoder) {
            encoder.appendSequence(lanes) { entry, lane in
                entry.appendEnum(lane.architecture)
                entry.append(path: lane.packageRoot)
            }
            encoder.append(path: productStoreRoot)
            encoder.append(UInt64(rollbackGenerationCount))
        }
    }

    package static let kind: ActionKind = "linux.retain-package-storage"

    private let lanes: [LinuxPackageStorageRetentionLane]
    private let productStoreRoot: FilePath
    private let rollbackGenerationCount: UInt32

    package var identity: Identity {
        Identity(
            lanes: lanes,
            productStoreRoot: productStoreRoot,
            rollbackGenerationCount: rollbackGenerationCount)
    }

    package var requirements: ActionRequirements {
        ActionRequirements(
            effects: lanes.map {
                ActionEffect(.readWrite, scope: .publication($0.packageRoot))
            } + [
                ActionEffect(.readWrite, scope: .publication(productStoreRoot))
            ],
            executionPlatform: .macOSARM64Native)
    }

    package init(
        lanes: [LinuxPackageStorageRetentionLane],
        productStoreRoot: FilePath,
        rollbackGenerationCount: UInt32
    ) {
        self.lanes = lanes.sorted {
            $0.architecture.rawValue < $1.architecture.rawValue
        }
        self.productStoreRoot = productStoreRoot
        self.rollbackGenerationCount = rollbackGenerationCount
    }

    package func execute(in context: ActionContext) async throws {
        for lane in lanes {
            let generations = lane.packageRoot.appending("generations")
            try context.files.pruneDirectories(
                DirectoryRetentionPlan(
                    safetyRoot: lane.packageRoot,
                    rules: [
                        DirectoryRetentionRule(
                            root: generations,
                            current: lane.packageRoot.appending("current"),
                            retain: rollbackGenerationCount,
                            naming: .artifactDigestDirectory),
                        DirectoryRetentionRule(
                            root: generations,
                            retain: 0,
                            naming: DirectoryNamePattern(rawValue: #"^\.candidate$"#)),
                    ]))
        }
        let retained = try retainedProductArtifacts(files: context.files)
        _ = try LocalProductArtifactStore(root: productStoreRoot).prune(
            retaining: retained)
    }

    package func validateOutputs(using files: ActionFileSystem) throws {
        for lane in lanes {
            try validateLinuxNativePackagePublication(
                architecture: lane.architecture,
                outputRoot: lane.packageRoot,
                productStoreRoot: productStoreRoot,
                files: files)
        }
    }

    private func retainedProductArtifacts(
        files: ActionFileSystem
    ) throws -> Set<ProductArtifactID> {
        var retained: Set<ProductArtifactID> = []
        for lane in lanes {
            let generations = lane.packageRoot.appending("generations")
            guard
                (try? generations.stat(followTargetSymlink: false).type)
                    == .directory
            else { continue }
            for name in try FileManager.default.contentsOfDirectory(
                atPath: generations.string
            ).sorted() where isArtifactGenerationName(name) {
                let manifestPath = generations.appending(name).appending(
                    "linux-native-package-cohort.json")
                let manifest: LinuxNativePackageCohortPublication
                do {
                    manifest = try JSONDecoder().decode(
                        LinuxNativePackageCohortPublication.self,
                        from: Data(files.read(manifestPath)))
                } catch {
                    throw LinuxPackageStorageRetentionFailure(
                        "could not decode retained package cohort at "
                            + "\(manifestPath): \(error)")
                }
                guard manifest.architecture == lane.architecture else {
                    throw LinuxPackageStorageRetentionFailure(
                        "retained package cohort has the wrong architecture: "
                            + manifestPath.string)
                }
                retained.formUnion(manifest.products.map(\.productArtifact))
            }
        }
        guard !retained.isEmpty else {
            throw LinuxPackageStorageRetentionFailure(
                "package storage retention found no retained products")
        }
        return retained
    }
}

private struct LinuxPackageStorageRetentionFailure: Error,
    CustomStringConvertible, Sendable
{
    let description: String

    init(_ description: String) {
        self.description = "Linux package storage retention failed: \(description)"
    }
}

private func isArtifactGenerationName(_ name: String) -> Bool {
    let prefix = "sha256-"
    guard name.hasPrefix(prefix) else { return false }
    let digest = name.dropFirst(prefix.count)
    return digest.utf8.count == 64
        && digest.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
}
