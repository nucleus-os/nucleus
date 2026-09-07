import ColliderCore
import ColliderRuntime
import ContainerAPIClient
import ContainerResource
import Crypto
import Foundation

struct AppleContainerVolumeOperations: Sendable {
    let create:
        @Sendable (
            _ name: String,
            _ driver: String,
            _ options: [String: String],
            _ labels: [String: String]
        ) async throws -> VolumeConfiguration
    let inspect: @Sendable (_ name: String) async throws -> VolumeConfiguration
    let list: @Sendable () async throws -> [VolumeConfiguration]
    let delete: @Sendable (_ name: String) async throws -> Void
    let allocatedBytes: @Sendable (_ name: String) async throws -> UInt64
    let activeNames: @Sendable () async throws -> Set<String>

    static let live = AppleContainerVolumeOperations(
        create: { name, driver, options, labels in
            try await ClientVolume.create(
                name: name,
                driver: driver,
                driverOpts: options,
                labels: labels)
        },
        inspect: { try await ClientVolume.inspect($0) },
        list: { try await ClientVolume.list() },
        delete: { try await ClientVolume.delete(name: $0) },
        allocatedBytes: { try await ClientVolume.volumeDiskUsage(name: $0) },
        activeNames: {
            let containers = try await ContainerClient().list()
            var names: Set<String> = []
            for container in containers {
                for mount in container.configuration.mounts {
                    if mount.isVolume, let name = mount.volumeName {
                        names.insert(name)
                    }
                }
            }
            return names
        })
}

struct ApplePersistentWorkspaceReconciliation: Sendable {
    let identity: PersistentWorkspaceIdentity
    let name: String
    let reason: String
}

struct ApplePersistentWorkspaceResolution: Sendable {
    let names: [PersistentWorkspaceIdentity: String]
    let created: [OCIPersistentWorkspaceMount]
    let reconciled: [ApplePersistentWorkspaceReconciliation]
}

/// How an existing volume disagrees with the declaration that claims it.
private enum WorkspaceDivergence {
    case none
    /// The image's shape disagrees. A persistent workspace holds rebuildable
    /// intermediates by construction, and its shape is a declared property, so
    /// the declaration wins and the volume is recreated to match it. Leaving
    /// this to an operator puts the ceiling back where retention policy already
    /// refused to leave it: in how often someone remembers to intervene.
    case shape(String)
    /// Ownership or naming disagrees, so recreating would destroy something
    /// this declaration does not own. That is never reconciled automatically.
    case identity(String)
}

struct ApplePersistentWorkspaceManager: Sendable {
    private let configuration: OCIRuntimeConfiguration
    private let operations: AppleContainerVolumeOperations

    init(
        configuration: OCIRuntimeConfiguration,
        operations: AppleContainerVolumeOperations = .live
    ) {
        self.configuration = configuration
        self.operations = operations
    }

    func resolve(
        _ mounts: [OCIPersistentWorkspaceMount]
    ) async throws -> ApplePersistentWorkspaceResolution {
        guard !mounts.isEmpty else {
            return ApplePersistentWorkspaceResolution(
                names: [:], created: [], reconciled: [])
        }
        _ = try owner()
        var names: [PersistentWorkspaceIdentity: String] = [:]
        var created: [OCIPersistentWorkspaceMount] = []
        var reconciled: [ApplePersistentWorkspaceReconciliation] = []
        var activeNames: Set<String>?
        for mount in mounts {
            let declaration = mount.workspace
            let name = try physicalName(for: declaration.identity)
            let expectedLabels = try labels(for: declaration.identity)
            let expectedOptions = options(for: declaration)
            var volume: VolumeConfiguration
            do {
                volume = try await operations.create(
                    name,
                    "local",
                    expectedOptions,
                    expectedLabels)
                created.append(mount)
            } catch {
                guard isAlreadyExists(error) else { throw error }
                volume = try await operations.inspect(name)
            }
            switch divergence(
                volume,
                declaration: declaration,
                expectedName: name,
                expectedLabels: expectedLabels,
                expectedOptions: expectedOptions)
            {
            case .none:
                break
            case .identity(let reason):
                throw AppleContainerFailure.persistentWorkspaceConfigurationMismatch(
                    name: name,
                    reason: reason)
            case .shape(let reason):
                // Reconciling a volume a container is holding would pull the
                // filesystem out from under a running build, so an in-use
                // workspace still refuses rather than reconciling.
                if activeNames == nil {
                    activeNames = try await operations.activeNames()
                }
                guard activeNames?.contains(name) != true else {
                    throw AppleContainerFailure.persistentWorkspaceConfigurationMismatch(
                        name: name,
                        reason: "\(reason); a running container holds it")
                }
                try await operations.delete(name)
                volume = try await operations.create(
                    name,
                    "local",
                    expectedOptions,
                    expectedLabels)
                guard
                    case .none = divergence(
                        volume,
                        declaration: declaration,
                        expectedName: name,
                        expectedLabels: expectedLabels,
                        expectedOptions: expectedOptions)
                else {
                    throw AppleContainerFailure.persistentWorkspaceConfigurationMismatch(
                        name: name,
                        reason: "\(reason); recreating it did not resolve the difference")
                }
                created.append(mount)
                reconciled.append(
                    ApplePersistentWorkspaceReconciliation(
                        identity: declaration.identity,
                        name: name,
                        reason: reason))
            }
            // A workspace that has been recreated in this pass is empty, so
            // there is nothing to measure and nothing that could be full.
            if !created.contains(where: { $0.workspace.identity == declaration.identity }) {
                let allocated = try await operations.allocatedBytes(name)
                let threshold = declaration.exhaustionThresholdBytes
                guard allocated < threshold else {
                    throw AppleContainerFailure.persistentWorkspaceExhausted(
                        name: name,
                        allocatedBytes: allocated,
                        capacityBytes: declaration.capacityBytes,
                        thresholdBytes: threshold)
                }
            }
            names[declaration.identity] = name
        }
        return ApplePersistentWorkspaceResolution(
            names: names, created: created, reconciled: reconciled)
    }

    func states() async throws -> [OCIPersistentWorkspaceState] {
        let active = try await operations.activeNames()
        var result: [OCIPersistentWorkspaceState] = []
        for volume in try await operations.list()
        where try isOwned(volume) {
            guard let identity = identity(from: volume.labels),
                let capacity = volume.sizeInBytes
            else {
                throw AppleContainerFailure.persistentWorkspaceConfigurationMismatch(
                    name: volume.name,
                    reason: "managed labels or capacity are incomplete")
            }
            result.append(
                OCIPersistentWorkspaceState(
                    name: volume.name,
                    identity: identity,
                    capacityBytes: capacity,
                    allocatedBytes: try await operations.allocatedBytes(volume.name),
                    active: active.contains(volume.name)))
        }
        return result.sorted { $0.name < $1.name }
    }

    func deleteOwned(name: String) async throws {
        let volume = try await operations.inspect(name)
        guard try isOwned(volume) else {
            throw AppleContainerFailure.persistentWorkspaceDeletionRefused(name)
        }
        try await operations.delete(name)
    }

    func physicalName(
        for identity: PersistentWorkspaceIdentity
    ) throws -> String {
        let owner = try owner()
        let target = targetName(identity.artifactTarget)
        let full = "collider-\(owner)-\(identity.key)-\(target)-\(identity.role)"
        guard full.utf8.count > 255 else { return full }
        let digest = SHA256.hash(data: Data(full.utf8)).hexadecimalPrefix(16)
        return [
            "collider",
            owner,
            String(identity.key.prefix(48)),
            String(target.prefix(40)),
            String(identity.role.prefix(32)),
            digest,
        ].joined(separator: "-")
    }

    func labels(
        for identity: PersistentWorkspaceIdentity
    ) throws -> [String: String] {
        let namespace = configuration.managedLabelNamespace
        var labels = try managedLabels()
        labels["\(namespace).persistent-workspace"] = "true"
        labels["\(namespace).persistent-workspace.owner"] = try owner()
        labels["\(namespace).persistent-workspace.key"] = identity.key
        labels["\(namespace).persistent-workspace.target"] = encodedTarget(
            identity.artifactTarget)
        labels["\(namespace).persistent-workspace.role"] = identity.role
        return labels
    }

    /// Ownership is settled before shape. A volume this declaration does not
    /// own must never reach the branch that recreates one.
    private func divergence(
        _ volume: VolumeConfiguration,
        declaration: PersistentWorkspaceDeclaration,
        expectedName: String,
        expectedLabels: [String: String],
        expectedOptions: [String: String]
    ) -> WorkspaceDivergence {
        if volume.name != expectedName {
            return .identity("name is \(volume.name), expected \(expectedName)")
        }
        if volume.labels != expectedLabels {
            return .identity("ownership labels differ")
        }
        if volume.driver != "local" {
            return .identity("driver is \(volume.driver), expected local")
        }
        if volume.format != declaration.filesystem.rawValue {
            return .shape(
                "format is \(volume.format), expected \(declaration.filesystem.rawValue)")
        }
        if volume.sizeInBytes != declaration.capacityBytes {
            return .shape(
                "capacity is \(volume.sizeInBytes.map(String.init) ?? "missing"), expected \(declaration.capacityBytes)"
            )
        }
        if volume.options != expectedOptions {
            return .shape("driver options differ")
        }
        return .none
    }

    private func options(
        for declaration: PersistentWorkspaceDeclaration
    ) -> [String: String] {
        [
            "size": String(declaration.capacityBytes),
            "journal":
                "\(declaration.journal.mode.rawValue):\(declaration.journal.sizeBytes)",
        ]
    }

    private func owner() throws -> String {
        guard let owner = configuration.persistentWorkspaceOwner,
            owner.utf8.count == 64,
            owner.utf8.allSatisfy({
                ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
            })
        else {
            throw AppleContainerFailure.invalidPersistentWorkspaceOwner(
                configuration.persistentWorkspaceOwner)
        }
        return owner
    }

    private func managedLabels() throws -> [String: String] {
        var result: [String: String] = [:]
        for label in configuration.managedLabels {
            let parts = label.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = parts.first, !key.isEmpty else {
                throw AppleContainerFailure.persistentWorkspaceConfigurationMismatch(
                    name: "runtime configuration",
                    reason: "managed label is invalid: \(label)")
            }
            result[String(key)] = parts.count == 2 ? String(parts[1]) : ""
        }
        return result
    }

    private func isOwned(_ volume: VolumeConfiguration) throws -> Bool {
        try isOwned(labels: volume.labels)
    }

    /// Ownership read from labels alone, so the same decision serves the
    /// service's answer and the entity record on disk that produced it.
    func isOwned(labels: [String: String]) throws -> Bool {
        let namespace = configuration.managedLabelNamespace
        let expectedOwner = try owner()
        return labels["\(namespace).persistent-workspace"] == "true"
            && labels["\(namespace).persistent-workspace.owner"] == expectedOwner
    }

    func identity(
        from labels: [String: String]
    ) -> PersistentWorkspaceIdentity? {
        let namespace = configuration.managedLabelNamespace
        guard let key = labels["\(namespace).persistent-workspace.key"],
            let encodedTarget = labels["\(namespace).persistent-workspace.target"],
            let role = labels["\(namespace).persistent-workspace.role"]
        else { return nil }
        // A workspace holding no target's state encodes an empty target, which
        // is a value rather than a parse failure. Reading it back as a failure
        // makes every such workspace unreadable, and one unreadable workspace
        // fails the whole enumeration.
        let target: ArtifactTarget?
        if encodedTarget.isEmpty {
            target = nil
        } else {
            guard let decoded = decodedTarget(encodedTarget) else { return nil }
            target = decoded
        }
        return PersistentWorkspaceIdentity(
            key: key,
            artifactTarget: target,
            role: role)
    }

    /// A workspace holding no target's state is named for that, so it cannot
    /// collide with one that does.
    private func targetName(_ target: ArtifactTarget?) -> String {
        guard let target else { return "any" }
        var fields = [
            target.operatingSystem.rawValue,
            target.architecture.rawValue,
        ]
        if let abi = target.abi { fields.append(abi) }
        if let apiLevel = target.androidAPILevel { fields.append("api\(apiLevel)") }
        return fields.joined(separator: "-").map {
            $0.isLetter || $0.isNumber ? Character(String($0).lowercased()) : "-"
        }.reduce(into: "") { $0.append($1) }
    }

    private func encodedTarget(_ target: ArtifactTarget?) -> String {
        guard let target else { return "" }
        return [
            target.operatingSystem.rawValue,
            target.architecture.rawValue,
            target.abi ?? "",
            target.androidAPILevel.map(String.init) ?? "",
        ].map { "\($0.utf8.count):\($0)" }.joined(separator: ":")
    }

    private func decodedTarget(_ value: String) -> ArtifactTarget? {
        var remainder = value[...]
        var fields: [String] = []
        for _ in 0..<4 {
            guard let separator = remainder.firstIndex(of: ":"),
                let length = Int(remainder[..<separator])
            else { return nil }
            remainder = remainder[remainder.index(after: separator)...]
            guard
                let end = remainder.index(
                    remainder.startIndex,
                    offsetBy: length,
                    limitedBy: remainder.endIndex)
            else { return nil }
            fields.append(String(remainder[..<end]))
            remainder = remainder[end...]
            if !remainder.isEmpty {
                guard remainder.first == ":" else { return nil }
                remainder = remainder.dropFirst()
            }
        }
        guard remainder.isEmpty,
            let operatingSystem = PlatformOperatingSystem(rawValue: fields[0]),
            let architecture = PlatformArchitecture(rawValue: fields[1])
        else { return nil }
        let apiLevel: UInt32?
        if fields[3].isEmpty {
            apiLevel = nil
        } else {
            guard let parsed = UInt32(fields[3]) else { return nil }
            apiLevel = parsed
        }
        return ArtifactTarget(
            operatingSystem: operatingSystem,
            architecture: architecture,
            abi: fields[2].isEmpty ? nil : fields[2],
            androidAPILevel: apiLevel)
    }

    private func isAlreadyExists(_ error: any Error) -> Bool {
        if let error = error as? VolumeError,
            case .volumeAlreadyExists = error
        {
            return true
        }
        return String(describing: error).contains("already exists")
    }
}

extension SHA256Digest {
    fileprivate func hexadecimalPrefix(_ count: Int) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var result: [UInt8] = []
        result.reserveCapacity(count)
        for byte in self where result.count < count {
            result.append(digits[Int(byte >> 4)])
            if result.count < count {
                result.append(digits[Int(byte & 0x0f)])
            }
        }
        return String(decoding: result, as: UTF8.self)
    }
}
