import ColliderCore

enum DirectWorkloadExecution: Hashable, Sendable {
    case host
    case target(ExecutionPlatform)
}

struct DirectWorkloadPlacement: Hashable, Sendable {
    let id: String
    let requiredTargetOperatingSystem: PlatformOperatingSystem
    let execution: DirectWorkloadExecution

    var isValid: Bool {
        switch execution {
        case .host:
            false
        case .target(let platform):
            platform.operatingSystem == requiredTargetOperatingSystem
                && platform.environment == .oci
        }
    }
}

enum DirectWorkloadPlacementAudit {
    static let current = [
        DirectWorkloadPlacement(
            id: "benchmark",
            requiredTargetOperatingSystem: .linux,
            execution: .target(.linuxARM64OCI)),
        DirectWorkloadPlacement(
            id: "sanitize",
            requiredTargetOperatingSystem: .linux,
            execution: .target(.linuxARM64OCI)),
        DirectWorkloadPlacement(
            id: "test.release-gate",
            requiredTargetOperatingSystem: .linux,
            execution: .target(.linuxARM64OCI)),
    ]

    static var invalidIDs: [String] {
        current.filter { !$0.isValid }.map(\.id).sorted()
    }
}
