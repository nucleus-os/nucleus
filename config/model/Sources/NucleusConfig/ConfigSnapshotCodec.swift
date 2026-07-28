import FoundationEssentials

public enum NucleusConfigSnapshotCodec {
    public static func encode(
        _ configuration: NucleusConfiguration
    ) throws -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return [UInt8](try encoder.encode(configuration))
    }

    public static func decode(
        _ bytes: some Collection<UInt8>
    ) throws -> NucleusConfiguration {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(
            NucleusConfiguration.self,
            from: Data(bytes))
    }
}

/// Stable deterministic codec for owner-specific resolved projections.
public enum NucleusConfigProjectionCodec {
    public static func encode<Value: Encodable>(
        _ projection: Value
    ) throws -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return [UInt8](try encoder.encode(projection))
    }

    public static func decode<Value: Decodable>(
        _ type: Value.Type,
        from bytes: some Collection<UInt8>
    ) throws -> Value {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: Data(bytes))
    }
}
