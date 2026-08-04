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

private func apexArchive(payloadMagic: [UInt8]) -> Data {
    var manifest = Data([0x0A])
    let name = Array("com.android.runtime".utf8)
    manifest.append(UInt8(name.count))
    manifest.append(contentsOf: name)
    manifest.append(contentsOf: [0x10, 37])

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
}
