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

    public mutating func append(path: FilePath) {
        append(.path, payload: Array(identityPathMap.canonicalize(path.string).utf8))
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
