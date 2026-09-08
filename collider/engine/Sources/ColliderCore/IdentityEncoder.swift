import SystemPackage

public struct IdentityEncoder: Sendable {
    private enum ValueType: UInt8 {
        case bytes = 1
        case string
        case integer
        case boolean
        case path
        case enumeration
        case optional
        case record
        case sequence
    }

    public private(set) var bytes: [UInt8] = []
    public let identityPathMap: IdentityPathMap

    public init(identityPathMap: IdentityPathMap = .empty) {
        self.identityPathMap = identityPathMap
    }

    /// Splices in identity bytes another encoder produced.
    ///
    /// Those bytes were canonicalized by whatever map that encoder held, which
    /// is not necessarily this one. A declared root surviving into them means
    /// the same source at a second location would produce a different identity
    /// and reuse nothing from the first, which is exactly the fault the roots
    /// are declared to prevent and one that otherwise shows up only as an
    /// unexplained full rebuild.
    public mutating func append(bytes value: [UInt8]) {
        append(.bytes, payload: value)
    }

    public mutating func append(_ value: String) {
        append(.string, payload: Array(value.utf8))
    }

    public mutating func append(_ value: UInt64) {
        append(.integer, payload: bigEndianBytes(value))
    }

    public mutating func append(_ value: Bool) {
        append(.boolean, payload: [value ? 1 : 0])
    }

    /// A command argument, which routinely carries a path inside a larger
    /// string: `-I/path`, `--sysroot=/path`, `-ffile-prefix-map=/path=/token`.
    /// Those paths are placement like any other and resolve through the
    /// declared roots. Appending the argument as an opaque string instead keeps
    /// the host's own directories in the identity, so the same compilation from
    /// a second checkout hashes differently and reuses nothing.
    public mutating func append(argument value: String) {
        append(canonicalizingPathsIn: value)
    }

    /// A string whose semantic value may contain a declared placement root.
    ///
    /// This is broader than a command argument: artifact-input strings also
    /// carry symlink targets and other path-valued configuration. Replacing
    /// only declared roots preserves every other byte while making those
    /// values independent of where the workspace and cache happen to live.
    public mutating func append(canonicalizingPathsIn value: String) {
        append(.string, payload: Array(identityPathMap.canonicalize(value).utf8))
    }

    public mutating func append(path: FilePath) {
        append(.path, payload: Array(identityPathMap.canonicalize(path.string).utf8))
    }

    /// Distinguishes what an action does from what it is given.
    ///
    /// Identity records the inputs that decide reuse, so an action whose
    /// behavior changes while its inputs do not stays clean and its outputs
    /// stay as the previous behavior left them. Raising this revision is how
    /// such a change reaches every machine, rather than only the one where
    /// someone deletes a directory by hand. It is spelled distinctly because a
    /// bare appended number reads as payload, and a reviewer cannot tell the
    /// difference at the point where it matters.
    ///
    /// Hashing the action's own code instead would invalidate every task on any
    /// Collider edit, which is the cost semantic identity exists to avoid.
    public mutating func appendBehaviorRevision(_ revision: UInt64) {
        append("behavior-revision")
        append(revision)
    }

    public mutating func appendEnum<Value>(_ value: Value)
    where Value: RawRepresentable, Value.RawValue == String {
        append(.enumeration, payload: Array(value.rawValue.utf8))
    }

    public mutating func appendOptional<Value>(
        _ value: Value?,
        encode: (inout IdentityEncoder, Value) -> Void
    ) {
        var payload: [UInt8] = [value == nil ? 0 : 1]
        if let value {
            var nested = IdentityEncoder(identityPathMap: identityPathMap)
            encode(&nested, value)
            payload += frame(nested.bytes)
        }
        append(.optional, payload: payload)
    }

    public mutating func appendRecord(
        _ encode: (inout IdentityEncoder) -> Void
    ) {
        var nested = IdentityEncoder(identityPathMap: identityPathMap)
        encode(&nested)
        append(.record, payload: nested.bytes)
    }

    public mutating func appendSequence<Values: Collection>(
        _ values: Values,
        encode: (inout IdentityEncoder, Values.Element) throws -> Void
    ) rethrows {
        var payload = bigEndianBytes(UInt64(values.count))
        for value in values {
            var nested = IdentityEncoder(identityPathMap: identityPathMap)
            try encode(&nested, value)
            payload += frame(nested.bytes)
        }
        append(.sequence, payload: payload)
    }

    public mutating func append<Identity: ColliderActionIdentity>(nested identity: Identity) {
        appendRecord { identity.encode(into: &$0) }
    }

    private mutating func append(_ type: ValueType, payload: [UInt8]) {
        bytes.append(type.rawValue)
        bytes += frame(payload)
    }
}

private func frame(_ bytes: [UInt8]) -> [UInt8] {
    bigEndianBytes(UInt64(bytes.count)) + bytes
}

private func bigEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
    var bigEndian = value.bigEndian
    return withUnsafeBytes(of: &bigEndian) { unsafe Array($0) }
}

/// The environment an identity records.
///
/// A variable naming the session or the account that started a build is not an
/// input to what the build produces, and hashing one means the same source
/// reuses nothing across two accounts on one machine or two machines running
/// one revision. `HOME`, `USER`, and `LOGNAME` are that, as `PATH` and `TERM`
/// are, and so is the run a command happens to belong to. A build whose output
/// genuinely varies with one of them is a defect the byte comparison across
/// checkouts catches, not something to encode here.
///
/// One definition because there were two. A task's action environment excluded
/// the account variables while the host SwiftPM command encoded beside it did
/// not, so `swift.package.dependencies` planned one identity for the builder
/// and another for the interactive account on the same machine, and the
/// difference was three strings naming who asked.
public enum IdentityEnvironment {
    public static let volatileNames: Set<String> = [
        "HOME", "LOGNAME", "NUCLEUS_RUN_DIR", "NUCLEUS_RUN_LOG", "PATH",
        "TERM", "USER",
    ]

    /// The entries to encode, in a stable order.
    public static func recorded(
        _ environment: [String: String]
    ) -> [(key: String, value: String)] {
        environment
            .filter { !volatileNames.contains($0.key) }
            .sorted { $0.key < $1.key }
    }
}
