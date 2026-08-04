import Foundation

public enum AndroidAddonArchitecture: String, Codable, CaseIterable, Sendable {
    case arm64
    case x86_64
}

public enum AndroidAddonManifestFailure: Error, Equatable, CustomStringConvertible {
    case unsupportedFormat(UInt16)
    case invalidIdentifier(String)
    case invalidIdentity(String)
    case invalidRelease
    case invalidPayloadPath(String)
    case duplicatePayloadPath(String)
    case invalidPayloadDigest(String)
    case emptyPayload
    case incompatibleNucleusBuild(expected: String, actual: String)
    case incompatibleKernel(expected: String, actual: String)
    case incompatibleArchitecture(
        expected: AndroidAddonArchitecture,
        actual: AndroidAddonArchitecture)

    public var description: String {
        switch self {
        case .unsupportedFormat(let version):
            "unsupported Android add-on format version \(version)"
        case .invalidIdentifier(let identifier):
            "unsupported Android add-on identifier: \(identifier)"
        case .invalidIdentity(let field):
            "Android add-on \(field) must be a lowercase SHA-256 identity"
        case .invalidRelease:
            "Android add-on release and build number must be nonempty single-line values"
        case .invalidPayloadPath(let path):
            "Android add-on payload path is invalid: \(path)"
        case .duplicatePayloadPath(let path):
            "Android add-on payload path is declared more than once: \(path)"
        case .invalidPayloadDigest(let path):
            "Android add-on payload digest is invalid: \(path)"
        case .emptyPayload:
            "Android add-on payload must not be empty"
        case .incompatibleNucleusBuild(let expected, let actual):
            "Android add-on requires Nucleus build \(expected); installed build is \(actual)"
        case .incompatibleKernel(let expected, let actual):
            "Android add-on requires kernel capability \(expected); installed capability is \(actual)"
        case .incompatibleArchitecture(let expected, let actual):
            "Android add-on requires \(expected.rawValue); installed system is \(actual.rawValue)"
        }
    }
}

public struct AndroidAddonPayloadFile: Codable, Equatable, Sendable {
    public let path: String
    public let size: UInt64
    public let sha256: String
    public let executable: Bool

    public init(
        path: String,
        size: UInt64,
        sha256: String,
        executable: Bool = false
    ) throws {
        guard Self.validRelativePath(path) else {
            throw AndroidAddonManifestFailure.invalidPayloadPath(path)
        }
        guard Self.validSHA256(sha256) else {
            throw AndroidAddonManifestFailure.invalidPayloadDigest(path)
        }
        self.path = path
        self.size = size
        self.sha256 = sha256
        self.executable = executable
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case size
        case sha256
        case executable
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            path: values.decode(String.self, forKey: .path),
            size: values.decode(UInt64.self, forKey: .size),
            sha256: values.decode(String.self, forKey: .sha256),
            executable: values.decodeIfPresent(Bool.self, forKey: .executable) ?? false)
    }

    static func validSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy {
                $0 >= Character("0").asciiValue!
                    && $0 <= Character("9").asciiValue!
                    || $0 >= Character("a").asciiValue!
                        && $0 <= Character("f").asciiValue!
            }
    }

    private static func validRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 4_096,
            value.first != "/", value.last != "/", !value.contains("\0"),
            !value.contains("//")
        else {
            return false
        }
        return value.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { component in
                component != "." && component != ".."
                    && component.utf8.allSatisfy {
                        $0 >= 0x41 && $0 <= 0x5a
                            || $0 >= 0x61 && $0 <= 0x7a
                            || $0 >= 0x30 && $0 <= 0x39
                            || $0 == 0x2b || $0 == 0x2d || $0 == 0x2e
                            || $0 == 0x5f
                    }
            }
    }
}

public struct AndroidAddonCompatibility: Codable, Equatable, Sendable {
    public let nucleusBuildIdentity: String
    public let kernelCapabilityIdentity: String
    public let architecture: AndroidAddonArchitecture

    public init(
        nucleusBuildIdentity: String,
        kernelCapabilityIdentity: String,
        architecture: AndroidAddonArchitecture
    ) throws {
        guard AndroidAddonPayloadFile.validSHA256(nucleusBuildIdentity) else {
            throw AndroidAddonManifestFailure.invalidIdentity(
                "Nucleus build identity")
        }
        guard AndroidAddonPayloadFile.validSHA256(kernelCapabilityIdentity) else {
            throw AndroidAddonManifestFailure.invalidIdentity(
                "kernel capability identity")
        }
        self.nucleusBuildIdentity = nucleusBuildIdentity
        self.kernelCapabilityIdentity = kernelCapabilityIdentity
        self.architecture = architecture
    }
}

public struct AndroidAddonManifest: Codable, Equatable, Sendable {
    public static let currentFormatVersion: UInt16 = 1
    public static let identifier = "android"

    public let formatVersion: UInt16
    public let identifier: String
    public let release: String
    public let buildNumber: String
    public let architecture: AndroidAddonArchitecture
    public let requiredNucleusBuildIdentity: String
    public let requiredKernelCapabilityIdentity: String
    public let payload: [AndroidAddonPayloadFile]

    public init(
        formatVersion: UInt16 = currentFormatVersion,
        identifier: String = AndroidAddonManifest.identifier,
        release: String,
        buildNumber: String,
        architecture: AndroidAddonArchitecture,
        requiredNucleusBuildIdentity: String,
        requiredKernelCapabilityIdentity: String,
        payload: [AndroidAddonPayloadFile]
    ) throws {
        guard formatVersion == Self.currentFormatVersion else {
            throw AndroidAddonManifestFailure.unsupportedFormat(formatVersion)
        }
        guard identifier == Self.identifier else {
            throw AndroidAddonManifestFailure.invalidIdentifier(identifier)
        }
        guard Self.validLabel(release), Self.validLabel(buildNumber) else {
            throw AndroidAddonManifestFailure.invalidRelease
        }
        guard AndroidAddonPayloadFile.validSHA256(requiredNucleusBuildIdentity) else {
            throw AndroidAddonManifestFailure.invalidIdentity(
                "required Nucleus build identity")
        }
        guard AndroidAddonPayloadFile.validSHA256(requiredKernelCapabilityIdentity) else {
            throw AndroidAddonManifestFailure.invalidIdentity(
                "required kernel capability identity")
        }
        guard !payload.isEmpty else {
            throw AndroidAddonManifestFailure.emptyPayload
        }
        var paths = Set<String>()
        for file in payload where !paths.insert(file.path).inserted {
            throw AndroidAddonManifestFailure.duplicatePayloadPath(file.path)
        }
        self.formatVersion = formatVersion
        self.identifier = identifier
        self.release = release
        self.buildNumber = buildNumber
        self.architecture = architecture
        self.requiredNucleusBuildIdentity = requiredNucleusBuildIdentity
        self.requiredKernelCapabilityIdentity = requiredKernelCapabilityIdentity
        self.payload = payload.sorted { $0.path < $1.path }
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case identifier
        case release
        case buildNumber
        case architecture
        case requiredNucleusBuildIdentity
        case requiredKernelCapabilityIdentity
        case payload
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            formatVersion: values.decode(UInt16.self, forKey: .formatVersion),
            identifier: values.decode(String.self, forKey: .identifier),
            release: values.decode(String.self, forKey: .release),
            buildNumber: values.decode(String.self, forKey: .buildNumber),
            architecture: values.decode(
                AndroidAddonArchitecture.self, forKey: .architecture),
            requiredNucleusBuildIdentity: values.decode(
                String.self, forKey: .requiredNucleusBuildIdentity),
            requiredKernelCapabilityIdentity: values.decode(
                String.self, forKey: .requiredKernelCapabilityIdentity),
            payload: values.decode(
                [AndroidAddonPayloadFile].self, forKey: .payload))
    }

    public func validateCompatibility(
        _ compatibility: AndroidAddonCompatibility
    ) throws {
        guard requiredNucleusBuildIdentity == compatibility.nucleusBuildIdentity else {
            throw AndroidAddonManifestFailure.incompatibleNucleusBuild(
                expected: requiredNucleusBuildIdentity,
                actual: compatibility.nucleusBuildIdentity)
        }
        guard requiredKernelCapabilityIdentity == compatibility.kernelCapabilityIdentity else {
            throw AndroidAddonManifestFailure.incompatibleKernel(
                expected: requiredKernelCapabilityIdentity,
                actual: compatibility.kernelCapabilityIdentity)
        }
        guard architecture == compatibility.architecture else {
            throw AndroidAddonManifestFailure.incompatibleArchitecture(
                expected: architecture,
                actual: compatibility.architecture)
        }
    }

    private static func validLabel(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && !value.contains("\0") && !value.contains("\n")
            && !value.contains("\r")
    }
}

public struct AndroidAddonStoreLayout: Equatable, Sendable {
    public let root: URL
    public let persistentStateRoot: URL

    public init(root: URL, persistentStateRoot: URL) throws {
        let content = root.standardizedFileURL
        let state = persistentStateRoot.standardizedFileURL
        let contentPath = content.path.hasSuffix("/") ? content.path : content.path + "/"
        let statePath = state.path.hasSuffix("/") ? state.path : state.path + "/"
        guard content.path.first == "/", state.path.first == "/",
            content != state,
            !contentPath.hasPrefix(statePath),
            !statePath.hasPrefix(contentPath)
        else {
            throw AndroidRuntimeFailure(
                "Android add-on content and persistent state require disjoint absolute roots")
        }
        self.root = content
        self.persistentStateRoot = state
    }

    public var generations: URL {
        root.appendingPathComponent("generations", isDirectory: true)
    }

    public var active: URL {
        root.appendingPathComponent("current", isDirectory: true)
    }

    public var capabilityRegistry: URL {
        root.appendingPathComponent("session-capabilities", isDirectory: true)
    }

    public var activeCapabilityManifest: URL {
        capabilityRegistry.appendingPathComponent("android.json")
    }
}
