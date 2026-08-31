import Foundation
import SystemPackage
import Testing

@testable import ColliderPersistence

private func temporaryRoot() -> FilePath {
    FilePath(
        FileManager.default.temporaryDirectory
            .appendingPathComponent("allocation-ledger-\(UUID().uuidString)").path)
}

@Test func aLedgerMergesWhatOneCallerMeasuredIntoWhatOthersDid() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(atPath: root.string) }
    let ledger = StorageAllocationLedger(root: root)

    #expect(ledger.load().isEmpty)
    #expect(ledger.record(["skia": 100, "aosp": 200]))
    #expect(ledger.load()["skia"]?.allocatedBytes == 100)

    // A prune measures the roots it collected from and nothing else. Replacing
    // the record with only those would erase every other root's last known
    // allocation and send the next report back to walking the store.
    #expect(ledger.record(["aosp": 50]))
    let merged = ledger.load()
    #expect(merged["aosp"]?.allocatedBytes == 50)
    #expect(merged["skia"]?.allocatedBytes == 100)
    #expect(merged.count == 2)
}

@Test func aLedgerDropsRootsTheCatalogNoLongerDeclares() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(atPath: root.string) }
    let ledger = StorageAllocationLedger(root: root)
    #expect(ledger.record(["kept": 1, "removed": 2]))

    // A declaration that goes away must stop reporting bytes, or the store's
    // total keeps counting storage nothing owns.
    #expect(ledger.retaining(["kept"]))
    #expect(Set(ledger.load().keys) == ["kept"])
}

@Test func recordingNothingLeavesTheRecordUntouched() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(atPath: root.string) }
    let ledger = StorageAllocationLedger(root: root)
    #expect(ledger.record(["kept": 1]))
    // A run that changed no declared root has nothing to say about any of
    // them, which is different from saying they are empty.
    #expect(ledger.record([:]))
    #expect(ledger.load()["kept"]?.allocatedBytes == 1)
}
