struct OutputPresentationLedger {
    struct Entry: Equatable {
        var treeRevision: UInt64 = 0
        var lockGeneration: UInt64 = 0
    }

    private(set) var entries: [UInt64: Entry] = [:]

    mutating func attach(_ outputID: UInt64) {
        entries[outputID] = Entry()
    }

    mutating func detach(_ outputID: UInt64) {
        entries[outputID] = nil
    }

    func needsTreeRevision(_ revision: UInt64, outputID: UInt64) -> Bool {
        entries[outputID, default: Entry()].treeRevision < revision
    }

    func needsLockGeneration(_ generation: UInt64, outputID: UInt64) -> Bool {
        entries[outputID, default: Entry()].lockGeneration < generation
    }

    mutating func acknowledge(
        _ outputID: UInt64,
        treeRevision: UInt64,
        lockGeneration: UInt64
    ) {
        entries[outputID] = Entry(
            treeRevision: treeRevision,
            lockGeneration: lockGeneration)
    }

    func allPresented(_ outputIDs: [UInt64], treeRevision: UInt64) -> Bool {
        outputIDs.allSatisfy {
            !needsTreeRevision(treeRevision, outputID: $0)
        }
    }

    mutating func removeAll() {
        entries.removeAll()
    }
}
