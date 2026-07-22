import Glibc

public enum SessionPresentMode: UInt8, Sendable, Equatable {
    case vsync = 0
    case mailboxLatestWins = 1
}

public enum SessionConfigurationFailure: Error, CustomStringConvertible {
    case invalidScale
    case invalidDevicePath
    case encodingTooLarge
    case invalidEncoding
    case invalidDescriptor(String)
    case readFailed(Int32)

    public var description: String {
        switch self {
        case .invalidScale:
            "output scale must be positive and finite"
        case .invalidDevicePath:
            "DRM device path must be absolute"
        case .encodingTooLarge:
            "session configuration exceeds the wire limit"
        case .invalidEncoding:
            "invalid session configuration encoding"
        case .invalidDescriptor(let value):
            "invalid session configuration descriptor '\(value)'"
        case .readFailed(let error):
            "session configuration read failed: errno \(error)"
        }
    }
}

/// Immutable launch configuration created once by the session entry point and
/// inherited by both native children over a private descriptor.
public struct SessionConfiguration: Sendable, Equatable {
    public static let descriptorArgument =
        "--nucleus-session-configuration-fd"
    public static let defaults = try! SessionConfiguration()

    private static let magic: UInt32 = 0x4E_55_43_46
    private static let version: UInt16 = 1
    private static let fixedSize = 28
    private static let maximumEncodedSize = 64 * 1024

    public let outputScale: Double
    public let presentMode: SessionPresentMode
    public let enableVulkanValidation: Bool
    public let traceProtocol: Bool
    public let traceDrmDemand: Bool
    public let drmDevicePath: String?
    public let wallpaperPath: String?

    public init(
        outputScale: Double = 1,
        presentMode: SessionPresentMode = .vsync,
        enableVulkanValidation: Bool = false,
        traceProtocol: Bool = false,
        traceDrmDemand: Bool = false,
        drmDevicePath: String? = nil,
        wallpaperPath: String? = nil
    ) throws {
        guard outputScale.isFinite, outputScale > 0 else {
            throw SessionConfigurationFailure.invalidScale
        }
        if let drmDevicePath, !drmDevicePath.hasPrefix("/") {
            throw SessionConfigurationFailure.invalidDevicePath
        }
        let stringBytes = (drmDevicePath?.utf8.count ?? 0)
            + (wallpaperPath?.utf8.count ?? 0)
        guard Self.fixedSize + stringBytes <= Self.maximumEncodedSize else {
            throw SessionConfigurationFailure.encodingTooLarge
        }
        self.outputScale = outputScale
        self.presentMode = presentMode
        self.enableVulkanValidation = enableVulkanValidation
        self.traceProtocol = traceProtocol
        self.traceDrmDemand = traceDrmDemand
        self.drmDevicePath = drmDevicePath.flatMap { $0.isEmpty ? nil : $0 }
        self.wallpaperPath = wallpaperPath.flatMap { $0.isEmpty ? nil : $0 }
    }

    public var encoded: [UInt8] {
        let drm = Array((drmDevicePath ?? "").utf8)
        let wallpaper = Array((wallpaperPath ?? "").utf8)
        precondition(Self.fixedSize + drm.count + wallpaper.count
            <= Self.maximumEncodedSize)
        var bytes = [UInt8](
            repeating: 0,
            count: Self.fixedSize + drm.count + wallpaper.count)
        Self.store(Self.magic, in: &bytes, at: 0)
        Self.store(Self.version, in: &bytes, at: 4)
        var flags: UInt16 = 0
        if enableVulkanValidation { flags |= 1 << 0 }
        if traceProtocol { flags |= 1 << 1 }
        if traceDrmDemand { flags |= 1 << 2 }
        Self.store(flags, in: &bytes, at: 6)
        Self.store(outputScale.bitPattern, in: &bytes, at: 8)
        bytes[16] = presentMode.rawValue
        // Byte 17 is reserved and must remain zero.
        Self.store(UInt32(drm.count), in: &bytes, at: 20)
        Self.store(UInt32(wallpaper.count), in: &bytes, at: 24)
        bytes.replaceSubrange(28..<(28 + drm.count), with: drm)
        bytes.replaceSubrange((28 + drm.count)..<bytes.count, with: wallpaper)
        return bytes
    }

    public init(encoded bytes: [UInt8]) throws {
        guard bytes.count >= Self.fixedSize,
              bytes.count <= Self.maximumEncodedSize,
              Self.loadUInt32(bytes, at: 0) == Self.magic,
              Self.loadUInt16(bytes, at: 4) == Self.version,
              let presentMode = SessionPresentMode(rawValue: bytes[16]),
              bytes[17] == 0,
              bytes[18] == 0,
              bytes[19] == 0,
              Self.loadUInt16(bytes, at: 6) & ~UInt16(0b111) == 0
        else { throw SessionConfigurationFailure.invalidEncoding }
        let drmCount = Int(Self.loadUInt32(bytes, at: 20))
        let wallpaperCount = Int(Self.loadUInt32(bytes, at: 24))
        guard Self.fixedSize + drmCount + wallpaperCount == bytes.count,
              let drm = String(
                validating: bytes[28..<(28 + drmCount)],
                as: UTF8.self),
              let wallpaper = String(
                validating: bytes[(28 + drmCount)..<bytes.count],
                as: UTF8.self)
        else { throw SessionConfigurationFailure.invalidEncoding }
        let flags = Self.loadUInt16(bytes, at: 6)
        try self.init(
            outputScale: Double(bitPattern: Self.loadUInt64(bytes, at: 8)),
            presentMode: presentMode,
            enableVulkanValidation: flags & (1 << 0) != 0,
            traceProtocol: flags & (1 << 1) != 0,
            traceDrmDemand: flags & (1 << 2) != 0,
            drmDevicePath: drm.isEmpty ? nil : drm,
            wallpaperPath: wallpaper.isEmpty ? nil : wallpaper)
    }

    public var hexEncoded: String {
        encoded.map {
            let value = String($0, radix: 16)
            return value.count == 1 ? "0" + value : value
        }.joined()
    }

    public init(hexEncoded value: String) throws {
        guard value.utf8.count.isMultiple(of: 2),
              value.utf8.count <= Self.maximumEncodedSize * 2
        else {
            throw SessionConfigurationFailure.invalidEncoding
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.utf8.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else {
                throw SessionConfigurationFailure.invalidEncoding
            }
            bytes.append(byte)
            index = next
        }
        try self.init(encoded: bytes)
    }

    public static func inherited(
        arguments: [String] = CommandLine.arguments
    ) throws -> SessionConfiguration {
        let indices = arguments.indices.filter {
            arguments[$0] == descriptorArgument
        }
        guard !indices.isEmpty else {
            return .defaults
        }
        guard indices.count == 1, let index = indices.first else {
            throw SessionConfigurationFailure.invalidDescriptor("<duplicate>")
        }
        guard
              arguments.indices.contains(index + 1),
              let descriptor = Int32(arguments[index + 1]),
              descriptor >= 3
        else {
            let value = arguments.indices.contains(index + 1)
                ? arguments[index + 1]
                : "<missing>"
            throw SessionConfigurationFailure.invalidDescriptor(value)
        }
        defer { _ = close(descriptor) }
        var encoded: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &chunk, chunk.count)
            if count > 0 {
                guard encoded.count + count <= maximumEncodedSize else {
                    throw SessionConfigurationFailure.invalidEncoding
                }
                encoded.append(contentsOf: chunk.prefix(count))
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            throw SessionConfigurationFailure.readFailed(errno)
        }
        return try SessionConfiguration(encoded: encoded)
    }

    private static func store(
        _ value: UInt16,
        in bytes: inout [UInt8],
        at offset: Int
    ) {
        let littleEndian = value.littleEndian
        withUnsafeBytes(of: littleEndian) {
            bytes.replaceSubrange(offset..<(offset + $0.count), with: $0)
        }
    }

    private static func store(
        _ value: UInt32,
        in bytes: inout [UInt8],
        at offset: Int
    ) {
        let littleEndian = value.littleEndian
        withUnsafeBytes(of: littleEndian) {
            bytes.replaceSubrange(offset..<(offset + $0.count), with: $0)
        }
    }

    private static func store(
        _ value: UInt64,
        in bytes: inout [UInt8],
        at offset: Int
    ) {
        let littleEndian = value.littleEndian
        withUnsafeBytes(of: littleEndian) {
            bytes.replaceSubrange(offset..<(offset + $0.count), with: $0)
        }
    }

    private static func loadUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func loadUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private static func loadUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for byte in bytes[offset..<(offset + 8)].reversed() {
            value = value << 8 | UInt64(byte)
        }
        return value
    }
}
