import NucleusTypes
public import NucleusCompositorServer

public typealias LayerSurfaceID = UInt64

public struct LayerMargin: Sendable, Equatable {
    public var top: Int32
    public var right: Int32
    public var bottom: Int32
    public var left: Int32

    public init(top: Int32, right: Int32, bottom: Int32, left: Int32) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
    }
}

public struct LayerSurfaceRecord: Sendable, Equatable {
    public var id: LayerSurfaceID
    public var layer: UInt32
    public var anchor: UInt32
    public var exclusiveZone: Int32
    public var margin: LayerMargin
    public var outputID: DisplayID
    public var namespace: String
    public var keyboardInteractivity: Int32
    public var mapped: Bool

    public init(
        id: LayerSurfaceID,
        layer: UInt32,
        anchor: UInt32,
        exclusiveZone: Int32,
        margin: LayerMargin,
        outputID: DisplayID,
        namespace: String,
        keyboardInteractivity: Int32,
        mapped: Bool
    ) {
        self.id = id
        self.layer = layer
        self.anchor = anchor
        self.exclusiveZone = exclusiveZone
        self.margin = margin
        self.outputID = outputID
        self.namespace = namespace
        self.keyboardInteractivity = keyboardInteractivity
        self.mapped = mapped
    }
}

public struct LayerExclusiveZones: Sendable, Equatable {
    public var top: Int32 = 0
    public var bottom: Int32 = 0
    public var left: Int32 = 0
    public var right: Int32 = 0

    public init() {}
}

@MainActor
public struct LayerShellPolicy {
    private var records: [LayerSurfaceID: LayerSurfaceRecord] = [:]

    public init() {}

    public mutating func reset() {
        records.removeAll(keepingCapacity: true)
    }

    @discardableResult
    public mutating func register(_ record: LayerSurfaceRecord) -> Bool {
        records[record.id] = record
        return true
    }

    public mutating func unregister(id: LayerSurfaceID) {
        records[id] = nil
    }

    public mutating func update(_ record: LayerSurfaceRecord) {
        records[record.id] = record
    }

    /// Whether any mapped layer surface occupies `outputID` — the render-side
    /// scanout gate (a mapped overlay forbids direct plane scanout).
    public func hasMappedSurface(outputID: DisplayID) -> Bool {
        for record in records.values where record.outputID == outputID && record.mapped {
            return true
        }
        return false
    }

    public func recalcZones(outputID: DisplayID) -> LayerExclusiveZones? {
        var zones = LayerExclusiveZones()
        for record in records.values where record.outputID == outputID && record.mapped && record.exclusiveZone > 0 {
            guard let edge = exclusiveEdge(anchor: record.anchor) else { continue }
            let value = record.exclusiveZone + marginForEdge(record.margin, edge: edge)
            switch edge {
            case 0: zones.top = max(zones.top, value)
            case 1: zones.bottom = max(zones.bottom, value)
            case 2: zones.left = max(zones.left, value)
            case 3: zones.right = max(zones.right, value)
            default: break
            }
        }
        return zones
    }

    public func resolveOutput(requestedID: DisplayID, namespace: String, server: NucleusCompositorServer) -> DisplayID? {
        _ = namespace
        if requestedID != 0, server.layout.display(id: requestedID) != nil {
            return requestedID
        }
        if let primary = server.layout.primaryOutputID, server.layout.display(id: primary) != nil {
            return primary
        }
        return server.layout.displays.first?.id
    }

    private func exclusiveEdge(anchor: UInt32) -> Int? {
        let top = (anchor & 1) != 0
        let bottom = (anchor & 2) != 0
        let left = (anchor & 4) != 0
        let right = (anchor & 8) != 0
        if top && left && right && !bottom { return 0 }
        if bottom && left && right && !top { return 1 }
        if left && top && bottom && !right { return 2 }
        if right && top && bottom && !left { return 3 }
        return nil
    }

    private func marginForEdge(_ margin: LayerMargin, edge: Int) -> Int32 {
        switch edge {
        case 0: return margin.top
        case 1: return margin.bottom
        case 2: return margin.left
        case 3: return margin.right
        default: return 0
        }
    }
}
