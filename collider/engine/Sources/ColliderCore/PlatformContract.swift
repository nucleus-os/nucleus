public enum PlatformOperatingSystem: String, Codable, Hashable, Sendable {
    case android
    case linux
    case macOS = "macos"
}

public enum PlatformArchitecture: String, Codable, Hashable, Sendable {
    case arm64
    case x86_64
}

public struct RunnerPlatform: Codable, Hashable, Sendable {
    public let operatingSystem: PlatformOperatingSystem
    public let architecture: PlatformArchitecture

    public init(
        operatingSystem: PlatformOperatingSystem,
        architecture: PlatformArchitecture
    ) {
        self.operatingSystem = operatingSystem
        self.architecture = architecture
    }

    public static let current = RunnerPlatform(
        operatingSystem: currentOperatingSystem,
        architecture: currentArchitecture)
}

public struct ExecutionPlatform: Codable, Hashable, Sendable {
    public enum Environment: String, Codable, Hashable, Sendable {
        case native
        case oci
    }

    public let environment: Environment
    public let operatingSystem: PlatformOperatingSystem
    public let architecture: PlatformArchitecture

    public init(
        environment: Environment,
        operatingSystem: PlatformOperatingSystem,
        architecture: PlatformArchitecture
    ) {
        self.environment = environment
        self.operatingSystem = operatingSystem
        self.architecture = architecture
    }

    public static let linuxAMD64OCI = ExecutionPlatform(
        environment: .oci,
        operatingSystem: .linux,
        architecture: .x86_64)

    public static let linuxARM64OCI = ExecutionPlatform(
        environment: .oci,
        operatingSystem: .linux,
        architecture: .arm64)
}

public struct ArtifactTarget: Codable, Hashable, Sendable {
    public let operatingSystem: PlatformOperatingSystem
    public let architecture: PlatformArchitecture
    public let abi: String?
    public let androidAPILevel: UInt32?

    public init(
        operatingSystem: PlatformOperatingSystem,
        architecture: PlatformArchitecture,
        abi: String? = nil,
        androidAPILevel: UInt32? = nil
    ) {
        self.operatingSystem = operatingSystem
        self.architecture = architecture
        self.abi = abi
        self.androidAPILevel = androidAPILevel
    }

    public static let linuxX86_64 = ArtifactTarget(
        operatingSystem: .linux,
        architecture: .x86_64,
        abi: "glibc")

    public static let linuxARM64 = ArtifactTarget(
        operatingSystem: .linux,
        architecture: .arm64,
        abi: "glibc")

    public static func androidARM64(apiLevel: UInt32) -> ArtifactTarget {
        ArtifactTarget(
            operatingSystem: .android,
            architecture: .arm64,
            abi: "bionic",
            androidAPILevel: apiLevel)
    }

    public static func androidX86_64(apiLevel: UInt32) -> ArtifactTarget {
        ArtifactTarget(
            operatingSystem: .android,
            architecture: .x86_64,
            abi: "bionic",
            androidAPILevel: apiLevel)
    }
}

public enum ExecutionBackend: String, Codable, Hashable, Sendable {
    case appleContainer = "apple-container"
    case native
    case podman
}

public enum OCIBackendContract {
    public static let appleOfflineNetwork = "nucleus-build-internal"
}

private let currentOperatingSystem: PlatformOperatingSystem = {
    #if os(macOS)
    .macOS
    #elseif os(Linux)
    .linux
    #else
    #error("Collider requires a supported runner operating system")
    #endif
}()

private let currentArchitecture: PlatformArchitecture = {
    #if arch(arm64)
    .arm64
    #elseif arch(x86_64)
    .x86_64
    #else
    #error("Collider requires a supported runner architecture")
    #endif
}()
