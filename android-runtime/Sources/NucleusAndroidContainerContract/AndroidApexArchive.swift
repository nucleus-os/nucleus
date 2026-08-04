import Foundation

package struct AndroidApexPayload: Equatable, Sendable {
    package let offset: UInt64
    package let size: UInt64

    package init(offset: UInt64, size: UInt64) {
        self.offset = offset
        self.size = size
    }
}

package enum AndroidApexPayloadFileSystem: Equatable, Sendable {
    case erofs
    case ext4
}

package struct AndroidApexArchiveMetadata: Equatable, Sendable {
    package let name: String
    package let version: UInt64
    package let payloadFileSystem: AndroidApexPayloadFileSystem
    package let payload: AndroidApexPayload
}

package enum AndroidApexArchiveError: Error, Equatable {
    case invalidArchive
    case zip64Unsupported
    case missingPayload
    case compressedPayload
    case duplicatePayload
    case unalignedPayload(UInt64)
    case missingManifest
    case duplicateManifest
    case compressedManifest
    case invalidManifest
    case unsupportedPayloadFileSystem
}

package enum AndroidApexArchive {
    package static func metadata(
        in archive: URL
    ) throws -> AndroidApexArchiveMetadata {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        let endRecordMinimumSize: UInt64 = 22
        guard fileSize >= endRecordMinimumSize else {
            throw AndroidApexArchiveError.invalidArchive
        }

        // The EOCD is at most one maximum-length ZIP comment from EOF.
        let tailLength = min(fileSize, UInt64(UInt16.max) + 22)
        try handle.seek(toOffset: fileSize - tailLength)
        guard let tail = try handle.read(upToCount: Int(tailLength)),
            let endOffset = lastSignature(
                0x0605_4B50,
                in: tail)
        else {
            throw AndroidApexArchiveError.invalidArchive
        }
        guard endOffset + 22 <= tail.count else {
            throw AndroidApexArchiveError.invalidArchive
        }

        let disk = try tail.littleEndianUInt16(at: endOffset + 4)
        let centralDirectoryDisk =
            try tail.littleEndianUInt16(at: endOffset + 6)
        let entriesOnDisk = try tail.littleEndianUInt16(at: endOffset + 8)
        let entryCount = try tail.littleEndianUInt16(at: endOffset + 10)
        let centralDirectorySize =
            try tail.littleEndianUInt32(at: endOffset + 12)
        let centralDirectoryOffset =
            try tail.littleEndianUInt32(at: endOffset + 16)
        let commentLength =
            try tail.littleEndianUInt16(at: endOffset + 20)
        guard disk == 0,
            centralDirectoryDisk == 0,
            entriesOnDisk == entryCount,
            endOffset + 22 + Int(commentLength) == tail.count
        else {
            throw AndroidApexArchiveError.invalidArchive
        }
        guard entriesOnDisk != UInt16.max,
            centralDirectorySize != UInt32.max,
            centralDirectoryOffset != UInt32.max
        else {
            throw AndroidApexArchiveError.zip64Unsupported
        }
        let directoryEnd =
            UInt64(centralDirectoryOffset) + UInt64(centralDirectorySize)
        guard directoryEnd <= fileSize else {
            throw AndroidApexArchiveError.invalidArchive
        }

        try handle.seek(toOffset: UInt64(centralDirectoryOffset))
        guard
            let centralDirectory = try handle.read(
                upToCount: Int(centralDirectorySize)),
            centralDirectory.count == Int(centralDirectorySize)
        else {
            throw AndroidApexArchiveError.invalidArchive
        }

        var cursor = 0
        var payload: AndroidApexPayload?
        var manifest: Data?
        for _ in 0..<entryCount {
            guard cursor + 46 <= centralDirectory.count,
                try centralDirectory.littleEndianUInt32(at: cursor)
                    == 0x0201_4B50
            else {
                throw AndroidApexArchiveError.invalidArchive
            }
            let compression =
                try centralDirectory.littleEndianUInt16(at: cursor + 10)
            let compressedSize =
                try centralDirectory.littleEndianUInt32(at: cursor + 20)
            let uncompressedSize =
                try centralDirectory.littleEndianUInt32(at: cursor + 24)
            let nameLength = Int(
                try centralDirectory.littleEndianUInt16(at: cursor + 28))
            let extraLength = Int(
                try centralDirectory.littleEndianUInt16(at: cursor + 30))
            let commentLength = Int(
                try centralDirectory.littleEndianUInt16(at: cursor + 32))
            let diskStart =
                try centralDirectory.littleEndianUInt16(at: cursor + 34)
            let localOffset =
                try centralDirectory.littleEndianUInt32(at: cursor + 42)
            let end = cursor + 46 + nameLength + extraLength + commentLength
            guard end <= centralDirectory.count,
                diskStart == 0
            else {
                throw AndroidApexArchiveError.invalidArchive
            }
            let nameBytes = centralDirectory[
                (cursor + 46)..<(cursor + 46 + nameLength)]
            guard let name = String(bytes: nameBytes, encoding: .utf8) else {
                throw AndroidApexArchiveError.invalidArchive
            }

            if name == "apex_payload.img" {
                guard payload == nil else {
                    throw AndroidApexArchiveError.duplicatePayload
                }
                guard compression == 0,
                    compressedSize == uncompressedSize
                else {
                    throw AndroidApexArchiveError.compressedPayload
                }
                guard compressedSize != UInt32.max,
                    localOffset != UInt32.max
                else {
                    throw AndroidApexArchiveError.zip64Unsupported
                }
                payload = try readPayload(
                    handle: handle,
                    fileSize: fileSize,
                    localOffset: UInt64(localOffset),
                    expectedName: name,
                    expectedSize: UInt64(uncompressedSize))
            } else if name == "apex_manifest.pb" {
                guard manifest == nil else {
                    throw AndroidApexArchiveError.duplicateManifest
                }
                guard compression == 0,
                    compressedSize == uncompressedSize
                else {
                    throw AndroidApexArchiveError.compressedManifest
                }
                guard compressedSize != UInt32.max,
                    localOffset != UInt32.max,
                    uncompressedSize <= 64 * 1_024
                else {
                    throw AndroidApexArchiveError.invalidManifest
                }
                manifest = try readStoredEntry(
                    handle: handle,
                    fileSize: fileSize,
                    localOffset: UInt64(localOffset),
                    expectedName: name,
                    expectedSize: UInt64(uncompressedSize))
            }
            cursor = end
        }
        guard cursor == centralDirectory.count else {
            throw AndroidApexArchiveError.invalidArchive
        }
        guard let payload else {
            throw AndroidApexArchiveError.missingPayload
        }
        guard let manifest else {
            throw AndroidApexArchiveError.missingManifest
        }
        guard payload.offset.isMultiple(of: 4096) else {
            throw AndroidApexArchiveError.unalignedPayload(payload.offset)
        }
        let identity = try parseManifest(manifest)
        return AndroidApexArchiveMetadata(
            name: identity.name,
            version: identity.version,
            payloadFileSystem: try payloadFileSystem(
                handle: handle,
                fileSize: fileSize,
                payload: payload),
            payload: payload)
    }

    private static func readPayload(
        handle: FileHandle,
        fileSize: UInt64,
        localOffset: UInt64,
        expectedName: String,
        expectedSize: UInt64
    ) throws -> AndroidApexPayload {
        guard localOffset + 30 <= fileSize else {
            throw AndroidApexArchiveError.invalidArchive
        }
        try handle.seek(toOffset: localOffset)
        guard let header = try handle.read(upToCount: 30),
            header.count == 30,
            try header.littleEndianUInt32(at: 0) == 0x0403_4B50
        else {
            throw AndroidApexArchiveError.invalidArchive
        }
        let compression = try header.littleEndianUInt16(at: 8)
        let nameLength = Int(try header.littleEndianUInt16(at: 26))
        let extraLength = Int(try header.littleEndianUInt16(at: 28))
        guard compression == 0 else {
            throw AndroidApexArchiveError.compressedPayload
        }
        guard let nameData = try handle.read(upToCount: nameLength),
            nameData.count == nameLength,
            String(bytes: nameData, encoding: .utf8) == expectedName
        else {
            throw AndroidApexArchiveError.invalidArchive
        }
        let offset =
            localOffset + 30 + UInt64(nameLength) + UInt64(extraLength)
        guard offset <= fileSize,
            expectedSize <= fileSize - offset
        else {
            throw AndroidApexArchiveError.invalidArchive
        }
        return AndroidApexPayload(offset: offset, size: expectedSize)
    }

    private static func readStoredEntry(
        handle: FileHandle,
        fileSize: UInt64,
        localOffset: UInt64,
        expectedName: String,
        expectedSize: UInt64
    ) throws -> Data {
        guard localOffset + 30 <= fileSize else {
            throw AndroidApexArchiveError.invalidArchive
        }
        try handle.seek(toOffset: localOffset)
        guard let header = try handle.read(upToCount: 30),
            header.count == 30,
            try header.littleEndianUInt32(at: 0) == 0x0403_4B50,
            try header.littleEndianUInt16(at: 8) == 0
        else {
            throw AndroidApexArchiveError.invalidArchive
        }
        let nameLength = Int(try header.littleEndianUInt16(at: 26))
        let extraLength = Int(try header.littleEndianUInt16(at: 28))
        guard let nameData = try handle.read(upToCount: nameLength),
            nameData.count == nameLength,
            String(bytes: nameData, encoding: .utf8) == expectedName
        else {
            throw AndroidApexArchiveError.invalidArchive
        }
        let offset = localOffset + 30 + UInt64(nameLength) + UInt64(extraLength)
        guard offset <= fileSize,
            expectedSize <= fileSize - offset,
            expectedSize <= UInt64(Int.max)
        else {
            throw AndroidApexArchiveError.invalidArchive
        }
        try handle.seek(toOffset: offset)
        guard let contents = try handle.read(upToCount: Int(expectedSize)),
            contents.count == Int(expectedSize)
        else {
            throw AndroidApexArchiveError.invalidArchive
        }
        return contents
    }

    private static func parseManifest(
        _ data: Data
    ) throws -> (name: String, version: UInt64) {
        var cursor = 0
        var name: String?
        var version: UInt64?
        while cursor < data.count {
            let tag = try data.protobufVarint(at: &cursor)
            let field = tag >> 3
            let wire = tag & 0x7
            guard field != 0 else {
                throw AndroidApexArchiveError.invalidManifest
            }
            switch (field, wire) {
            case (1, 2):
                guard name == nil else {
                    throw AndroidApexArchiveError.invalidManifest
                }
                let length = try data.protobufVarint(at: &cursor)
                guard length <= UInt64(data.count - cursor),
                    length <= UInt64(Int.max)
                else {
                    throw AndroidApexArchiveError.invalidManifest
                }
                let end = cursor + Int(length)
                guard
                    let value = String(
                        data: data[cursor..<end], encoding: .utf8),
                    !value.isEmpty
                else {
                    throw AndroidApexArchiveError.invalidManifest
                }
                name = value
                cursor = end
            case (2, 0):
                guard version == nil else {
                    throw AndroidApexArchiveError.invalidManifest
                }
                version = try data.protobufVarint(at: &cursor)
            default:
                try data.skipProtobufField(wire: wire, cursor: &cursor)
            }
        }
        guard let name, let version, version > 0 else {
            throw AndroidApexArchiveError.invalidManifest
        }
        return (name, version)
    }

    private static func payloadFileSystem(
        handle: FileHandle,
        fileSize: UInt64,
        payload: AndroidApexPayload
    ) throws -> AndroidApexPayloadFileSystem {
        guard payload.size >= 1_082,
            payload.offset <= fileSize,
            payload.size <= fileSize - payload.offset
        else {
            throw AndroidApexArchiveError.unsupportedPayloadFileSystem
        }
        try handle.seek(toOffset: payload.offset + 1_024)
        guard let superblock = try handle.read(upToCount: 58),
            superblock.count == 58
        else {
            throw AndroidApexArchiveError.invalidArchive
        }
        if try superblock.littleEndianUInt32(at: 0) == 0xE0F5_E1E2 {
            return .erofs
        }
        if try superblock.littleEndianUInt16(at: 56) == 0xEF53 {
            return .ext4
        }
        throw AndroidApexArchiveError.unsupportedPayloadFileSystem
    }
}

private func lastSignature(
    _ signature: UInt32,
    in data: Data
) -> Int? {
    guard data.count >= 4 else { return nil }
    for index in stride(from: data.count - 4, through: 0, by: -1) {
        if (try? data.littleEndianUInt32(at: index)) == signature {
            return index
        }
    }
    return nil
}

extension Data {
    fileprivate func protobufVarint(at cursor: inout Int) throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard cursor < count else {
                throw AndroidApexArchiveError.invalidManifest
            }
            let byte = self[cursor]
            cursor += 1
            if shift == 63, byte > 1 {
                throw AndroidApexArchiveError.invalidManifest
            }
            value |= UInt64(byte & 0x7f) << UInt64(shift)
            if byte & 0x80 == 0 {
                return value
            }
        }
        throw AndroidApexArchiveError.invalidManifest
    }

    fileprivate func skipProtobufField(wire: UInt64, cursor: inout Int) throws {
        let length: UInt64
        switch wire {
        case 0:
            _ = try protobufVarint(at: &cursor)
            return
        case 1:
            length = 8
        case 2:
            length = try protobufVarint(at: &cursor)
        case 5:
            length = 4
        default:
            throw AndroidApexArchiveError.invalidManifest
        }
        guard length <= UInt64(count - cursor), length <= UInt64(Int.max) else {
            throw AndroidApexArchiveError.invalidManifest
        }
        cursor += Int(length)
    }

    fileprivate func littleEndianUInt16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else {
            throw AndroidApexArchiveError.invalidArchive
        }
        return UInt16(self[offset])
            | (UInt16(self[offset + 1]) << 8)
    }

    fileprivate func littleEndianUInt32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else {
            throw AndroidApexArchiveError.invalidArchive
        }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
