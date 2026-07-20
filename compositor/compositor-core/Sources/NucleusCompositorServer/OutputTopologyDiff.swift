public struct OutputTopologyFingerprint: Sendable, Equatable {
    public let outputID: DisplayID
    public let pixelWidth: UInt32
    public let pixelHeight: UInt32
    public let refreshMilliHz: Int32
    public let crtcID: UInt32
    public let primaryPlaneID: UInt32
    public let cursorPlaneID: UInt32

    public init(
        outputID: DisplayID,
        pixelWidth: UInt32,
        pixelHeight: UInt32,
        refreshMilliHz: Int32,
        crtcID: UInt32,
        primaryPlaneID: UInt32,
        cursorPlaneID: UInt32
    ) {
        self.outputID = outputID
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshMilliHz = refreshMilliHz
        self.crtcID = crtcID
        self.primaryPlaneID = primaryPlaneID
        self.cursorPlaneID = cursorPlaneID
    }
}

public struct OutputTopologyDiff: Sendable, Equatable {
    public let removed: [DisplayID]
    public let changed: [DisplayID]
    public let added: [DisplayID]
    public let unchanged: [DisplayID]

    public static func compute(
        current: [OutputTopologyFingerprint],
        proposed: [OutputTopologyFingerprint],
        forceChanged: Bool = false
    ) -> Self {
        let old = Dictionary(
            uniqueKeysWithValues: current.map { ($0.outputID, $0) })
        let new = Dictionary(
            uniqueKeysWithValues: proposed.map { ($0.outputID, $0) })
        let removed = old.keys.filter { new[$0] == nil }.sorted()
        var changed: [DisplayID] = []
        var added: [DisplayID] = []
        var unchanged: [DisplayID] = []
        for id in new.keys.sorted() {
            guard let prior = old[id] else {
                added.append(id)
                continue
            }
            if forceChanged || prior != new[id] {
                changed.append(id)
            } else {
                unchanged.append(id)
            }
        }
        return Self(
            removed: removed,
            changed: changed,
            added: added,
            unchanged: unchanged)
    }
}
