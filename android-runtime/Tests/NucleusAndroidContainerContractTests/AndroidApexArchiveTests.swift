internal import Foundation
internal import NucleusAndroidContainerContract
import Testing

@Test func apexArchiveReadsManifestAndErofsPayloadWithoutHostTools() throws {
    let archive = FileManager.default.temporaryDirectory.appendingPathComponent(
        "nucleus-apex-\(UUID().uuidString).apex")
    defer { try? FileManager.default.removeItem(at: archive) }
    try apexArchive(payloadMagic: [0xE2, 0xE1, 0xF5, 0xE0]).write(to: archive)

    let metadata = try AndroidApexArchive.metadata(in: archive)

    #expect(metadata.name == "com.android.runtime")
    #expect(metadata.version == 37)
    #expect(metadata.payloadFileSystem == .erofs)
    #expect(metadata.payload.offset.isMultiple(of: 4_096))
}

@Test func apexArchiveRejectsUnknownPayloadFileSystem() throws {
    let archive = FileManager.default.temporaryDirectory.appendingPathComponent(
        "nucleus-apex-\(UUID().uuidString).apex")
    defer { try? FileManager.default.removeItem(at: archive) }
    try apexArchive(payloadMagic: [0, 0, 0, 0]).write(to: archive)

    #expect(throws: AndroidApexArchiveError.unsupportedPayloadFileSystem) {
        _ = try AndroidApexArchive.metadata(in: archive)
    }
}

@Test func apexArchiveRejectsMalformedManifest() throws {
    let malformedManifests = [
        Data([0x0A, 0x80]),
        Data([0x0A] + Array(repeating: 0xFF, count: 10) + [0x02]),
        Data([0x0B]),
        Data([0x0A, 0x01, 0x61]),
        Data([0x0A, 0x01, 0x61, 0x10] + Array(repeating: 0xFF, count: 9) + [0x01]),
    ]
    for manifest in malformedManifests {
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent(
            "nucleus-apex-\(UUID().uuidString).apex")
        defer { try? FileManager.default.removeItem(at: archive) }
        try apexArchive(payloadMagic: [0xE2, 0xE1, 0xF5, 0xE0], manifest: manifest).write(
            to: archive)

        #expect(throws: AndroidApexArchiveError.invalidManifest) {
            _ = try AndroidApexArchive.metadata(in: archive)
        }
    }
}

@Test func apexArchiveUsesProtobufSingularFieldSemantics() throws {
    let archive = FileManager.default.temporaryDirectory.appendingPathComponent(
        "nucleus-apex-\(UUID().uuidString).apex")
    defer { try? FileManager.default.removeItem(at: archive) }
    let manifest = Data([
        0x0A, 0x03, 0x6F, 0x6C, 0x64,
        0x10, 0x01,
        0x0A, 0x03, 0x6E, 0x65, 0x77,
        0x10, 0x25,
        0x98, 0x06, 0x01,
    ])
    try apexArchive(
        payloadMagic: [0xE2, 0xE1, 0xF5, 0xE0],
        manifest: manifest
    ).write(to: archive)

    let metadata = try AndroidApexArchive.metadata(in: archive)

    #expect(metadata.name == "new")
    #expect(metadata.version == 37)
}

@Test func apexArchiveRejectsTruncatedCentralDirectoryRecord() throws {
    let archive = FileManager.default.temporaryDirectory.appendingPathComponent(
        "nucleus-apex-\(UUID().uuidString).apex")
    defer { try? FileManager.default.removeItem(at: archive) }
    var data = apexArchive(payloadMagic: [0xE2, 0xE1, 0xF5, 0xE0])
    let endRecordOffset = data.count - 22
    let centralSize = data.littleEndianUInt32(at: endRecordOffset + 12)
    data.replaceSubrange((endRecordOffset - 1)..<endRecordOffset, with: [])
    data.replaceLittleEndian(centralSize - 1, at: endRecordOffset - 1 + 12)
    try data.write(to: archive)

    #expect(throws: AndroidApexArchiveError.invalidArchive) {
        _ = try AndroidApexArchive.metadata(in: archive)
    }
}

private func apexArchive(payloadMagic: [UInt8], manifest suppliedManifest: Data? = nil) -> Data {
    let manifest: Data
    if let suppliedManifest {
        manifest = suppliedManifest
    } else {
        var generated = Data([0x0A])
        let name = Array("com.android.runtime".utf8)
        generated.append(UInt8(name.count))
        generated.append(contentsOf: name)
        generated.append(contentsOf: [0x10, 37])
        manifest = generated
    }

    var payload = Data(repeating: 0, count: 2_048)
    payload.replaceSubrange(1_024..<1_028, with: payloadMagic)

    var archive = Data()
    var entries: [(name: String, size: UInt32, offset: UInt32)] = []
    appendStoredEntry(
        name: "apex_manifest.pb",
        contents: manifest,
        alignedContents: false,
        archive: &archive,
        entries: &entries)
    appendStoredEntry(
        name: "apex_payload.img",
        contents: payload,
        alignedContents: true,
        archive: &archive,
        entries: &entries)

    let centralOffset = UInt32(archive.count)
    for entry in entries {
        archive.appendLittleEndian(UInt32(0x0201_4B50))
        archive.appendLittleEndian(UInt16(20))
        archive.appendLittleEndian(UInt16(20))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(UInt32(0))
        archive.appendLittleEndian(entry.size)
        archive.appendLittleEndian(entry.size)
        archive.appendLittleEndian(UInt16(entry.name.utf8.count))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(UInt32(0))
        archive.appendLittleEndian(entry.offset)
        archive.append(contentsOf: entry.name.utf8)
    }
    let centralSize = UInt32(archive.count) - centralOffset
    archive.appendLittleEndian(UInt32(0x0605_4B50))
    archive.appendLittleEndian(UInt16(0))
    archive.appendLittleEndian(UInt16(0))
    archive.appendLittleEndian(UInt16(entries.count))
    archive.appendLittleEndian(UInt16(entries.count))
    archive.appendLittleEndian(centralSize)
    archive.appendLittleEndian(centralOffset)
    archive.appendLittleEndian(UInt16(0))
    return archive
}

private func appendStoredEntry(
    name: String,
    contents: Data,
    alignedContents: Bool,
    archive: inout Data,
    entries: inout [(name: String, size: UInt32, offset: UInt32)]
) {
    let localOffset = UInt32(archive.count)
    let baseOffset = archive.count + 30 + name.utf8.count
    let extraLength = alignedContents ? (4_096 - baseOffset % 4_096) % 4_096 : 0
    archive.appendLittleEndian(UInt32(0x0403_4B50))
    archive.appendLittleEndian(UInt16(20))
    archive.appendLittleEndian(UInt16(0))
    archive.appendLittleEndian(UInt16(0))
    archive.appendLittleEndian(UInt16(0))
    archive.appendLittleEndian(UInt16(0))
    archive.appendLittleEndian(UInt32(0))
    archive.appendLittleEndian(UInt32(contents.count))
    archive.appendLittleEndian(UInt32(contents.count))
    archive.appendLittleEndian(UInt16(name.utf8.count))
    archive.appendLittleEndian(UInt16(extraLength))
    archive.append(contentsOf: name.utf8)
    archive.append(Data(repeating: 0, count: extraLength))
    archive.append(contents)
    entries.append((name, UInt32(contents.count), localOffset))
}

extension Data {
    fileprivate mutating func appendLittleEndian(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    fileprivate mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }

    fileprivate mutating func replaceLittleEndian(_ value: UInt32, at offset: Int) {
        self[offset] = UInt8(truncatingIfNeeded: value)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        self[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        self[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    fileprivate func littleEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16) | (UInt32(self[offset + 3]) << 24)
    }
}
