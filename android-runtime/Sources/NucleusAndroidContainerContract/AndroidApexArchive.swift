import BinaryParsing
import Foundation
import SwiftProtobuf

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
        let endRecord: ZipEndRecord
        do {
            endRecord = try tail.withParserSpan { input in
                try input.seek(toAbsoluteOffset: endOffset)
                return try ZipEndRecord(parsing: &input)
            }
        } catch {
            throw AndroidApexArchiveError.invalidArchive
        }
        guard endRecord.disk == 0,
            endRecord.centralDirectoryDisk == 0,
            endRecord.entriesOnDisk == endRecord.entryCount,
            endOffset + 22 + Int(endRecord.commentLength) == tail.count
        else {
            throw AndroidApexArchiveError.invalidArchive
        }
        guard endRecord.entriesOnDisk != UInt16.max,
            endRecord.centralDirectorySize != UInt32.max,
            endRecord.centralDirectoryOffset != UInt32.max
        else {
            throw AndroidApexArchiveError.zip64Unsupported
        }
        let directoryEnd =
            UInt64(endRecord.centralDirectoryOffset) + UInt64(endRecord.centralDirectorySize)
        guard directoryEnd <= fileSize else {
            throw AndroidApexArchiveError.invalidArchive
        }

        try handle.seek(toOffset: UInt64(endRecord.centralDirectoryOffset))
        guard
            let centralDirectory = try handle.read(
                upToCount: Int(endRecord.centralDirectorySize)),
            centralDirectory.count == Int(endRecord.centralDirectorySize)
        else {
            throw AndroidApexArchiveError.invalidArchive
        }

        var payload: AndroidApexPayload?
        var manifest: Data?
        do {
            try centralDirectory.withParserSpan { input in
                for _ in 0..<endRecord.entryCount {
                    let entry = try ZipCentralDirectoryEntry(parsing: &input)
                    guard entry.diskStart == 0 else {
                        throw AndroidApexArchiveError.invalidArchive
                    }
                    if entry.name == "apex_payload.img" {
                        guard payload == nil else {
                            throw AndroidApexArchiveError.duplicatePayload
                        }
                        guard entry.compression == 0,
                            entry.compressedSize == entry.uncompressedSize
                        else {
                            throw AndroidApexArchiveError.compressedPayload
                        }
                        guard entry.compressedSize != UInt32.max,
                            entry.localOffset != UInt32.max
                        else {
                            throw AndroidApexArchiveError.zip64Unsupported
                        }
                        payload = try readPayload(
                            handle: handle,
                            fileSize: fileSize,
                            localOffset: UInt64(entry.localOffset),
                            expectedName: entry.name,
                            expectedSize: UInt64(entry.uncompressedSize))
                    } else if entry.name == "apex_manifest.pb" {
                        guard manifest == nil else {
                            throw AndroidApexArchiveError.duplicateManifest
                        }
                        guard entry.compression == 0,
                            entry.compressedSize == entry.uncompressedSize
                        else {
                            throw AndroidApexArchiveError.compressedManifest
                        }
                        guard entry.compressedSize != UInt32.max,
                            entry.localOffset != UInt32.max,
                            entry.uncompressedSize <= 64 * 1_024
                        else {
                            throw AndroidApexArchiveError.invalidManifest
                        }
                        manifest = try readStoredEntry(
                            handle: handle,
                            fileSize: fileSize,
                            localOffset: UInt64(entry.localOffset),
                            expectedName: entry.name,
                            expectedSize: UInt64(entry.uncompressedSize))
                    }
                }
                guard input.isEmpty else {
                    throw AndroidApexArchiveError.invalidArchive
                }
            }
        } catch let error as AndroidApexArchiveError {
            throw error
        } catch {
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
        guard let headerData = try handle.read(upToCount: 30),
            headerData.count == 30
        else {
            throw AndroidApexArchiveError.invalidArchive
        }
        let header: ZipLocalFileHeader
        do {
            header = try headerData.withParserSpan { input in
                try ZipLocalFileHeader(parsing: &input)
            }
        } catch {
            throw AndroidApexArchiveError.invalidArchive
        }
        guard header.compression == 0 else {
            throw AndroidApexArchiveError.compressedPayload
        }
        guard let nameData = try handle.read(upToCount: header.nameLength),
            nameData.count == header.nameLength,
            String(bytes: nameData, encoding: .utf8) == expectedName
        else {
            throw AndroidApexArchiveError.invalidArchive
        }
        let offset = localOffset + 30 + UInt64(header.nameLength) + UInt64(header.extraLength)
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
        guard let headerData = try handle.read(upToCount: 30),
            headerData.count == 30
        else {
            throw AndroidApexArchiveError.invalidArchive
        }
        let header: ZipLocalFileHeader
        do {
            header = try headerData.withParserSpan { input in
                try ZipLocalFileHeader(parsing: &input)
            }
        } catch {
            throw AndroidApexArchiveError.invalidArchive
        }
        guard header.compression == 0,
            let nameData = try handle.read(upToCount: header.nameLength),
            nameData.count == header.nameLength,
            String(bytes: nameData, encoding: .utf8) == expectedName
        else {
            throw AndroidApexArchiveError.invalidArchive
        }
        let offset = localOffset + 30 + UInt64(header.nameLength) + UInt64(header.extraLength)
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
        do {
            let manifest = try Apex_Proto_ApexManifest(serializedBytes: data)
            guard !manifest.name.isEmpty, manifest.version > 0 else {
                throw AndroidApexArchiveError.invalidManifest
            }
            return (manifest.name, UInt64(manifest.version))
        } catch let error as AndroidApexArchiveError {
            throw error
        } catch {
            throw AndroidApexArchiveError.invalidManifest
        }
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
        do {
            return try superblock.withParserSpan { input in
                if try UInt32(parsingLittleEndian: &input) == 0xE0F5_E1E2 {
                    return .erofs
                }
                try input.seek(toAbsoluteOffset: 56)
                if try UInt16(parsingLittleEndian: &input) == 0xEF53 {
                    return .ext4
                }
                throw AndroidApexArchiveError.unsupportedPayloadFileSystem
            }
        } catch let error as AndroidApexArchiveError {
            throw error
        } catch {
            throw AndroidApexArchiveError.invalidArchive
        }
    }
}

private func lastSignature(
    _ signature: UInt32,
    in data: Data
) -> Int? {
    guard data.count >= 4 else { return nil }
    let bytes = [
        UInt8(truncatingIfNeeded: signature),
        UInt8(truncatingIfNeeded: signature >> 8),
        UInt8(truncatingIfNeeded: signature >> 16),
        UInt8(truncatingIfNeeded: signature >> 24),
    ]
    for index in stride(from: data.count - 4, through: 0, by: -1) {
        if data[index] == bytes[0], data[index + 1] == bytes[1],
            data[index + 2] == bytes[2], data[index + 3] == bytes[3]
        {
            return index
        }
    }
    return nil
}

private struct ZipEndRecord {
    let disk: UInt16
    let centralDirectoryDisk: UInt16
    let entriesOnDisk: UInt16
    let entryCount: UInt16
    let centralDirectorySize: UInt32
    let centralDirectoryOffset: UInt32
    let commentLength: UInt16

    init(parsing input: inout ParserSpan) throws {
        guard try UInt32(parsingLittleEndian: &input) == 0x0605_4B50 else {
            throw AndroidApexArchiveError.invalidArchive
        }
        disk = try UInt16(parsingLittleEndian: &input)
        centralDirectoryDisk = try UInt16(parsingLittleEndian: &input)
        entriesOnDisk = try UInt16(parsingLittleEndian: &input)
        entryCount = try UInt16(parsingLittleEndian: &input)
        centralDirectorySize = try UInt32(parsingLittleEndian: &input)
        centralDirectoryOffset = try UInt32(parsingLittleEndian: &input)
        commentLength = try UInt16(parsingLittleEndian: &input)
    }
}

private struct ZipCentralDirectoryEntry {
    let compression: UInt16
    let compressedSize: UInt32
    let uncompressedSize: UInt32
    let diskStart: UInt16
    let localOffset: UInt32
    let name: String

    init(parsing input: inout ParserSpan) throws {
        guard try UInt32(parsingLittleEndian: &input) == 0x0201_4B50 else {
            throw AndroidApexArchiveError.invalidArchive
        }
        try input.seek(toRelativeOffset: 6)
        compression = try UInt16(parsingLittleEndian: &input)
        try input.seek(toRelativeOffset: 8)
        compressedSize = try UInt32(parsingLittleEndian: &input)
        uncompressedSize = try UInt32(parsingLittleEndian: &input)
        let nameLength = try UInt16(parsingLittleEndian: &input)
        let extraLength = try UInt16(parsingLittleEndian: &input)
        let commentLength = try UInt16(parsingLittleEndian: &input)
        diskStart = try UInt16(parsingLittleEndian: &input)
        try input.seek(toRelativeOffset: 6)
        localOffset = try UInt32(parsingLittleEndian: &input)

        let nameData = try Data(parsing: &input, byteCount: Int(nameLength))
        guard let parsedName = String(data: nameData, encoding: .utf8) else {
            throw AndroidApexArchiveError.invalidArchive
        }
        name = parsedName
        _ = try input.extract(byteCount: extraLength)
        _ = try input.extract(byteCount: commentLength)
    }
}

private struct ZipLocalFileHeader {
    let compression: UInt16
    let nameLength: Int
    let extraLength: Int

    init(parsing input: inout ParserSpan) throws {
        guard try UInt32(parsingLittleEndian: &input) == 0x0403_4B50 else {
            throw AndroidApexArchiveError.invalidArchive
        }
        try input.seek(toRelativeOffset: 4)
        compression = try UInt16(parsingLittleEndian: &input)
        try input.seek(toRelativeOffset: 16)
        nameLength = Int(try UInt16(parsingLittleEndian: &input))
        extraLength = Int(try UInt16(parsingLittleEndian: &input))
    }
}
