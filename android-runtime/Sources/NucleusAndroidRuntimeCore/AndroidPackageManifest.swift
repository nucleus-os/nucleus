import Foundation

public enum AndroidPackageArchitecture: String, Codable, CaseIterable, Sendable {
    case arm64
    case x86_64
}

public enum AndroidPackageManifestFailure: Error, Equatable, CustomStringConvertible {
    case invalidIdentifier(String)
    case invalidRelease
    case invalidPayloadPath(String)
    case duplicatePayloadPath(String)
    case invalidPayloadDigest(String)
    case emptyPayload

    public var description: String {
        switch self {
        case .invalidIdentifier(let identifier):
            "unsupported Android package identifier: \(identifier)"
        case .invalidRelease:
            "Android package release and build number must be nonempty single-line values"
        case .invalidPayloadPath(let path):
            "Android package payload path is invalid: \(path)"
        case .duplicatePayloadPath(let path):
            "Android package payload path is declared more than once: \(path)"
        case .invalidPayloadDigest(let path):
            "Android package payload digest is invalid: \(path)"
        case .emptyPayload:
            "Android package payload must not be empty"
        }
    }
}

public struct AndroidPackagePayloadFile: Codable, Equatable, Sendable {
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
            throw AndroidPackageManifestFailure.invalidPayloadPath(path)
        }
        guard Self.validSHA256(sha256) else {
            throw AndroidPackageManifestFailure.invalidPayloadDigest(path)
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

public struct AndroidPackageManifest: Codable, Equatable, Sendable {
    public static let identifier = "android"

    public let identifier: String
    public let release: String
    public let buildNumber: String
    public let architecture: AndroidPackageArchitecture
    public let payload: [AndroidPackagePayloadFile]

    public init(
        identifier: String = AndroidPackageManifest.identifier,
        release: String,
        buildNumber: String,
        architecture: AndroidPackageArchitecture,
        payload: [AndroidPackagePayloadFile]
    ) throws {
        guard identifier == Self.identifier else {
            throw AndroidPackageManifestFailure.invalidIdentifier(identifier)
        }
        guard Self.validLabel(release), Self.validLabel(buildNumber) else {
            throw AndroidPackageManifestFailure.invalidRelease
        }
        guard !payload.isEmpty else {
            throw AndroidPackageManifestFailure.emptyPayload
        }
        var paths = Set<String>()
        for file in payload where !paths.insert(file.path).inserted {
            throw AndroidPackageManifestFailure.duplicatePayloadPath(file.path)
        }
        self.identifier = identifier
        self.release = release
        self.buildNumber = buildNumber
        self.architecture = architecture
        self.payload = payload.sorted { $0.path < $1.path }
    }

    private enum CodingKeys: String, CodingKey {
        case identifier
        case release
        case buildNumber
        case architecture
        case payload
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            identifier: values.decode(String.self, forKey: .identifier),
            release: values.decode(String.self, forKey: .release),
            buildNumber: values.decode(String.self, forKey: .buildNumber),
            architecture: values.decode(
                AndroidPackageArchitecture.self, forKey: .architecture),
            payload: values.decode(
                [AndroidPackagePayloadFile].self, forKey: .payload))
    }

    private static func validLabel(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && !value.contains("\0") && !value.contains("\n")
            && !value.contains("\r")
    }
}
