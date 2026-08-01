import Foundation

package struct AndroidApexPayload: Equatable, Sendable {
    package let offset: UInt64
    package let size: UInt64

    package init(offset: UInt64, size: UInt64) {
        self.offset = offset
        self.size = size
    }
}

package enum AndroidApexArchiveError: Error, Equatable {
    case invalidArchive
    case zip64Unsupported
    case missingPayload
    case compressedPayload
    case duplicatePayload
    case unalignedPayload(UInt64)
}

package enum AndroidApexArchive {
    package static func payload(
        in archive: URL
    ) throws -> AndroidApexPayload {
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
        guard let centralDirectory = try handle.read(
            upToCount: Int(centralDirectorySize)),
            centralDirectory.count == Int(centralDirectorySize)
        else {
            throw AndroidApexArchiveError.invalidArchive
        }

        var cursor = 0
        var payload: AndroidApexPayload?
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
            }
            cursor = end
        }
        guard cursor == centralDirectory.count,
            let payload
        else {
            throw payload == nil
                ? AndroidApexArchiveError.missingPayload
                : AndroidApexArchiveError.invalidArchive
        }
        guard payload.offset.isMultiple(of: 4096) else {
            throw AndroidApexArchiveError.unalignedPayload(payload.offset)
        }
        return payload
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

private extension Data {
    func littleEndianUInt16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else {
            throw AndroidApexArchiveError.invalidArchive
        }
        return UInt16(self[offset])
            | (UInt16(self[offset + 1]) << 8)
    }

    func littleEndianUInt32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else {
            throw AndroidApexArchiveError.invalidArchive
        }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
