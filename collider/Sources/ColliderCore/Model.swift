import FoundationEssentials
import SystemPackage

public struct TaskID: RawRepresentable, Hashable, Codable, Sendable,
    CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

public struct ComponentID: RawRepresentable, Hashable, Codable, Sendable,
    CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

public struct ArtifactDigest: Hashable, Codable, Sendable,
    CustomStringConvertible
{
    public enum Algorithm: String, Codable, Sendable { case sha256 }

    public let algorithm: Algorithm
    public let bytes: [UInt8]

    public init(algorithm: Algorithm = .sha256, bytes: [UInt8]) {
        self.algorithm = algorithm
        self.bytes = bytes
    }

    public init?(sha256Hex value: String) {
        guard value.utf8.count == 64,
              value.utf8.allSatisfy({ byte in
                  (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                      || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
              })
        else { return nil }
        var bytes: [UInt8] = []
        var index = value.startIndex
        while index < value.endIndex {
            let end = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<end], radix: 16) else { return nil }
            bytes.append(byte)
            index = end
        }
        self.init(bytes: bytes)
    }

    public var description: String {
        let digits = Array("0123456789abcdef".utf8)
        let encoded = bytes.flatMap { byte in
            [digits[Int(byte >> 4)], digits[Int(byte & 0x0f)]]
        }
        return algorithm.rawValue + ":" + String(decoding: encoded, as: UTF8.self)
    }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        let pieces = value.split(separator: ":", maxSplits: 1)
        guard pieces.count == 2,
              let algorithm = Algorithm(rawValue: String(pieces[0])),
              pieces[1].count.isMultiple(of: 2)
        else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "invalid labelled artifact digest")
        }
        var bytes: [UInt8] = []
        var index = pieces[1].startIndex
        while index < pieces[1].endIndex {
            let end = pieces[1].index(index, offsetBy: 2)
            guard let byte = UInt8(pieces[1][index..<end], radix: 16) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "artifact digest is not lowercase hexadecimal")
            }
            bytes.append(byte)
            index = end
        }
        self.init(algorithm: algorithm, bytes: bytes)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public struct CommandSpec: Hashable, Sendable {
    public enum Executable: Hashable, Sendable {
        case named(String)
        case path(FilePath)
        /// An executable built earlier in the same ordered task operation.
        ///
        /// Its producing command and sources define the task identity, so the
        /// path is framed without requiring the file to exist during planning.
        case taskOutput(FilePath)
    }

    public enum Output: Hashable, Sendable {
        case inherited
        case logged
        case terminal
        case captured(limit: Int)
        case combined(limit: Int)
    }

    public enum Input: Hashable, Sendable {
        case none
        case terminal
        case bytes([UInt8])
    }

    public let executable: Executable
    public let arguments: [String]
    public let workingDirectory: FilePath
    public let environment: [String: String]
    public let input: Input
    public let output: Output
    public let timeoutNanoseconds: UInt64?

    public init(
        executable: Executable,
        arguments: [String],
        workingDirectory: FilePath,
        environment: [String: String],
        input: Input = .none,
        output: Output = .inherited,
        timeoutNanoseconds: UInt64? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.input = input
        self.output = output
        self.timeoutNanoseconds = timeoutNanoseconds
    }
}

public struct CommandResult: Hashable, Sendable {
    public let status: Int32
    public let standardOutput: String
    public let timedOut: Bool

    public init(status: Int32, standardOutput: String = "", timedOut: Bool = false) {
        self.status = status
        self.standardOutput = standardOutput
        self.timedOut = timedOut
    }
}

public struct DownloadSpec: Hashable, Sendable {
    public enum Resumption: String, Hashable, Codable, Sendable {
        case disabled
        case validatorRequired
    }

    public let url: URL
    public let permittedRedirectOrigins: Set<String>
    public let expectedDigest: ArtifactDigest
    public let maximumResponseSize: Int64
    public let acceptedMediaTypes: Set<String>
    public let requestTimeoutSeconds: UInt64
    public let inactivityTimeoutSeconds: UInt64
    public let maximumRedirects: Int
    public let maximumRetries: Int
    public let resumption: Resumption

    public init(
        url: URL,
        permittedRedirectOrigins: Set<String>,
        expectedDigest: ArtifactDigest,
        maximumResponseSize: Int64,
        acceptedMediaTypes: Set<String>,
        requestTimeoutSeconds: UInt64 = 300,
        inactivityTimeoutSeconds: UInt64 = 30,
        maximumRedirects: Int = 5,
        maximumRetries: Int = 2,
        resumption: Resumption = .validatorRequired
    ) throws {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil
        else { throw DownloadSpecFailure.invalidURL }
        guard expectedDigest.algorithm == .sha256,
              expectedDigest.bytes.count == 32
        else { throw DownloadSpecFailure.invalidDigest }
        guard maximumResponseSize > 0 else {
            throw DownloadSpecFailure.unboundedResponse
        }
        guard !acceptedMediaTypes.isEmpty else {
            throw DownloadSpecFailure.missingMediaType
        }
        guard requestTimeoutSeconds > 0,
              inactivityTimeoutSeconds > 0,
              maximumRedirects >= 0,
              maximumRetries >= 0
        else { throw DownloadSpecFailure.invalidPolicy }
        self.url = url
        self.permittedRedirectOrigins = permittedRedirectOrigins
        self.expectedDigest = expectedDigest
        self.maximumResponseSize = maximumResponseSize
        self.acceptedMediaTypes = acceptedMediaTypes
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.inactivityTimeoutSeconds = inactivityTimeoutSeconds
        self.maximumRedirects = maximumRedirects
        self.maximumRetries = maximumRetries
        self.resumption = resumption
    }
}

public enum DownloadSpecFailure: Error, CustomStringConvertible, Sendable {
    case invalidURL
    case invalidDigest
    case unboundedResponse
    case missingMediaType
    case invalidPolicy

    public var description: String {
        switch self {
        case .invalidURL: "downloads require an HTTPS URL without embedded credentials"
        case .invalidDigest: "downloads require a complete SHA-256 digest"
        case .unboundedResponse: "downloads require a positive maximum response size"
        case .missingMediaType: "downloads require at least one accepted media type"
        case .invalidPolicy: "download timeout, redirect, or retry policy is invalid"
        }
    }
}
