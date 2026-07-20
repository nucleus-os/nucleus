import NucleusCompositorDrmC

struct ConnectorID: RawRepresentable, Hashable, Sendable, Comparable {
    let rawValue: UInt32
    init(rawValue: UInt32) { self.rawValue = rawValue }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct EncoderID: RawRepresentable, Hashable, Sendable, Comparable {
    let rawValue: UInt32
    init(rawValue: UInt32) { self.rawValue = rawValue }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct CrtcID: RawRepresentable, Hashable, Sendable, Comparable {
    let rawValue: UInt32
    init(rawValue: UInt32) { self.rawValue = rawValue }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct PlaneID: RawRepresentable, Hashable, Sendable, Comparable {
    let rawValue: UInt32
    init(rawValue: UInt32) { self.rawValue = rawValue }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct PhysicalSize: Sendable, Equatable {
    let widthMM: Int32
    let heightMM: Int32
}

struct DrmEncoderCandidate: Sendable, Equatable {
    let encoderID: EncoderID
    let currentCrtcID: CrtcID?
    let compatibleCrtcIDs: Set<CrtcID>
}

struct DrmConnectorCandidate: Sendable, Equatable {
    let connectorID: ConnectorID
    let encoderCandidates: [DrmEncoderCandidate]
    let modes: [DrmModeInfo]
    let currentCrtcID: CrtcID?
    let currentMode: DrmModeInfo?
    let physicalSizeMM: PhysicalSize
    let vrrCapable: Bool

    var compatibleCrtcIDs: Set<CrtcID> {
        encoderCandidates.reduce(into: []) { result, encoder in
            result.formUnion(encoder.compatibleCrtcIDs)
        }
    }
}

enum DrmPlaneKind: Sendable, Equatable {
    case overlay
    case primary
    case cursor
}

struct DrmPlaneCandidate: Sendable, Equatable {
    let planeID: PlaneID
    let kind: DrmPlaneKind
    let compatibleCrtcIDs: Set<CrtcID>
}

struct DrmTopologyInventory: Sendable, Equatable {
    let generation: UInt64
    let crtcIDs: [CrtcID]
    let connectors: [DrmConnectorCandidate]
    let planes: [DrmPlaneCandidate]
}

struct DrmPipelineAssignment: Sendable, Equatable {
    let connectorID: ConnectorID
    let crtcID: CrtcID
    let primaryPlaneID: PlaneID
    let cursorPlaneID: PlaneID?
    let mode: DrmModeInfo
}

struct OutputTopologySnapshot: Sendable, Equatable {
    let generation: UInt64
    let assignments: [DrmPipelineAssignment]
}

enum DrmTopologyRejectionReason: Sendable, Equatable, CustomStringConvertible {
    case noMode
    case noCompatibleCrtc
    case noCompatiblePrimaryPlane
    case allocationConflict

    var description: String {
        switch self {
        case .noMode: return "connector exposes no usable mode"
        case .noCompatibleCrtc: return "connector exposes no compatible CRTC"
        case .noCompatiblePrimaryPlane: return "compatible CRTCs have no primary plane"
        case .allocationConflict: return "all compatible pipelines are assigned to other connectors"
        }
    }
}

struct DrmTopologyRejection: Sendable, Equatable {
    let connectorID: ConnectorID
    let reason: DrmTopologyRejectionReason
}

struct DrmTopologyPlanningResult: Sendable, Equatable {
    let snapshot: OutputTopologySnapshot
    let rejections: [DrmTopologyRejection]
    let diagnostics: [String]
}

enum DrmTopologyPlanner {
    private struct PipelineOption: Equatable {
        let crtcID: CrtcID
        let primaryPlaneID: PlaneID
    }

    private struct EligibleConnector {
        let connector: DrmConnectorCandidate
        let mode: DrmModeInfo
        let options: [PipelineOption]
    }

    private struct AllocationScore {
        let assignedCount: Int
        let preservedPipelineCount: Int
        let preservedCurrentCrtcCount: Int
        let signature: [UInt32]

        func isBetter(than other: AllocationScore?) -> Bool {
            guard let other else { return true }
            if assignedCount != other.assignedCount {
                return assignedCount > other.assignedCount
            }
            if preservedPipelineCount != other.preservedPipelineCount {
                return preservedPipelineCount > other.preservedPipelineCount
            }
            if preservedCurrentCrtcCount != other.preservedCurrentCrtcCount {
                return preservedCurrentCrtcCount > other.preservedCurrentCrtcCount
            }
            return signature.lexicographicallyPrecedes(other.signature)
        }
    }

    static func plan(
        _ inventory: DrmTopologyInventory,
        preserving previous: OutputTopologySnapshot? = nil
    ) -> DrmTopologyPlanningResult {
        let previousByConnector = Dictionary(
            uniqueKeysWithValues: (previous?.assignments ?? []).map { ($0.connectorID, $0) })
        let primaryPlanes = inventory.planes
            .filter { $0.kind == .primary }
            .sorted { $0.planeID < $1.planeID }

        var immediateRejections: [DrmTopologyRejection] = []
        var eligible: [EligibleConnector] = []
        for connector in inventory.connectors.sorted(by: { $0.connectorID < $1.connectorID }) {
            guard let mode = selectMode(
                for: connector, previous: previousByConnector[connector.connectorID])
            else {
                immediateRejections.append(
                    DrmTopologyRejection(connectorID: connector.connectorID, reason: .noMode))
                continue
            }
            let compatibleCrtcs = connector.compatibleCrtcIDs
            guard !compatibleCrtcs.isEmpty else {
                immediateRejections.append(
                    DrmTopologyRejection(
                        connectorID: connector.connectorID, reason: .noCompatibleCrtc))
                continue
            }
            var options: [PipelineOption] = []
            for crtcID in compatibleCrtcs.sorted() {
                for plane in primaryPlanes where plane.compatibleCrtcIDs.contains(crtcID) {
                    options.append(PipelineOption(
                        crtcID: crtcID, primaryPlaneID: plane.planeID))
                }
            }
            guard !options.isEmpty else {
                immediateRejections.append(
                    DrmTopologyRejection(
                        connectorID: connector.connectorID,
                        reason: .noCompatiblePrimaryPlane))
                continue
            }
            let old = previousByConnector[connector.connectorID]
            options.sort {
                let lhsOld = old?.crtcID == $0.crtcID
                    && old?.primaryPlaneID == $0.primaryPlaneID
                let rhsOld = old?.crtcID == $1.crtcID
                    && old?.primaryPlaneID == $1.primaryPlaneID
                if lhsOld != rhsOld { return lhsOld }
                let lhsCurrent = connector.currentCrtcID == $0.crtcID
                let rhsCurrent = connector.currentCrtcID == $1.crtcID
                if lhsCurrent != rhsCurrent { return lhsCurrent }
                if $0.crtcID != $1.crtcID { return $0.crtcID < $1.crtcID }
                return $0.primaryPlaneID < $1.primaryPlaneID
            }
            eligible.append(EligibleConnector(
                connector: connector, mode: mode, options: options))
        }

        // Most-constrained-first reduces the search tree. Final scoring and the
        // connector-sorted signature make the result independent of discovery order.
        eligible.sort {
            if $0.options.count != $1.options.count {
                return $0.options.count < $1.options.count
            }
            return $0.connector.connectorID < $1.connector.connectorID
        }

        var selected: [ConnectorID: PipelineOption] = [:]
        var usedCrtcs: Set<CrtcID> = []
        var usedPrimaryPlanes: Set<PlaneID> = []
        var best: [ConnectorID: PipelineOption] = [:]
        var bestScore: AllocationScore?

        func score(_ allocation: [ConnectorID: PipelineOption]) -> AllocationScore {
            var preservedPipelineCount = 0
            var preservedCurrentCrtcCount = 0
            var signature: [UInt32] = []
            for item in eligible.sorted(by: {
                $0.connector.connectorID < $1.connector.connectorID
            }) {
                let connectorID = item.connector.connectorID
                if let option = allocation[connectorID] {
                    if let old = previousByConnector[connectorID],
                        old.crtcID == option.crtcID,
                        old.primaryPlaneID == option.primaryPlaneID
                    {
                        preservedPipelineCount += 1
                    }
                    if item.connector.currentCrtcID == option.crtcID {
                        preservedCurrentCrtcCount += 1
                    }
                    signature.append(option.crtcID.rawValue)
                    signature.append(option.primaryPlaneID.rawValue)
                } else {
                    signature.append(UInt32.max)
                    signature.append(UInt32.max)
                }
            }
            return AllocationScore(
                assignedCount: allocation.count,
                preservedPipelineCount: preservedPipelineCount,
                preservedCurrentCrtcCount: preservedCurrentCrtcCount,
                signature: signature)
        }

        func search(_ index: Int) {
            if index == eligible.count {
                let candidateScore = score(selected)
                if candidateScore.isBetter(than: bestScore) {
                    best = selected
                    bestScore = candidateScore
                }
                return
            }
            if selected.count + eligible.count - index < (bestScore?.assignedCount ?? 0) {
                return
            }
            let item = eligible[index]
            for option in item.options
            where !usedCrtcs.contains(option.crtcID)
                && !usedPrimaryPlanes.contains(option.primaryPlaneID)
            {
                selected[item.connector.connectorID] = option
                usedCrtcs.insert(option.crtcID)
                usedPrimaryPlanes.insert(option.primaryPlaneID)
                search(index + 1)
                usedPrimaryPlanes.remove(option.primaryPlaneID)
                usedCrtcs.remove(option.crtcID)
                selected[item.connector.connectorID] = nil
            }
            search(index + 1)
        }
        search(0)

        let cursorPlanes = inventory.planes
            .filter { $0.kind == .cursor }
            .sorted { $0.planeID < $1.planeID }
        var usedCursorPlanes: Set<PlaneID> = []
        var assignments: [DrmPipelineAssignment] = []
        for item in eligible.sorted(by: {
            $0.connector.connectorID < $1.connector.connectorID
        }) {
            let connectorID = item.connector.connectorID
            guard let pipeline = best[connectorID] else { continue }
            let compatibleCursorPlanes = cursorPlanes.filter {
                $0.compatibleCrtcIDs.contains(pipeline.crtcID)
                    && !usedCursorPlanes.contains($0.planeID)
            }
            let previousCursor = previousByConnector[connectorID]?.cursorPlaneID
            let cursor = compatibleCursorPlanes.first {
                $0.planeID == previousCursor
            } ?? compatibleCursorPlanes.first
            if let cursor { usedCursorPlanes.insert(cursor.planeID) }
            assignments.append(DrmPipelineAssignment(
                connectorID: connectorID,
                crtcID: pipeline.crtcID,
                primaryPlaneID: pipeline.primaryPlaneID,
                cursorPlaneID: cursor?.planeID,
                mode: item.mode))
        }

        var rejections = immediateRejections
        for item in eligible where best[item.connector.connectorID] == nil {
            rejections.append(DrmTopologyRejection(
                connectorID: item.connector.connectorID, reason: .allocationConflict))
        }
        rejections.sort { $0.connectorID < $1.connectorID }

        var diagnostics: [String] = []
        for connector in inventory.connectors.sorted(by: { $0.connectorID < $1.connectorID }) {
            let crtcs = connector.compatibleCrtcIDs.sorted()
                .map { String($0.rawValue) }.joined(separator: ",")
            let primary = primaryPlanes.filter {
                !$0.compatibleCrtcIDs.isDisjoint(with: connector.compatibleCrtcIDs)
            }.map { String($0.planeID.rawValue) }.joined(separator: ",")
            diagnostics.append(
                "connector \(connector.connectorID.rawValue): crtcs=[\(crtcs)] primary_planes=[\(primary)]")
        }
        for rejection in rejections {
            diagnostics.append(
                "connector \(rejection.connectorID.rawValue): rejected: \(rejection.reason)")
        }

        return DrmTopologyPlanningResult(
            snapshot: OutputTopologySnapshot(
                generation: inventory.generation, assignments: assignments),
            rejections: rejections,
            diagnostics: diagnostics)
    }

    static func selectMode(
        for connector: DrmConnectorCandidate,
        previous: DrmPipelineAssignment? = nil
    ) -> DrmModeInfo? {
        if let current = connector.currentMode,
            let exact = connector.modes.first(where: { $0 == current })
        {
            return exact
        }
        if let previous,
            let exact = connector.modes.first(where: { $0 == previous.mode })
        {
            return exact
        }
        guard let preferred = connector.modes.first(where: \.isPreferred)
            ?? connector.modes.first
        else { return nil }
        return connector.modes
            .filter {
                $0.hdisplay == preferred.hdisplay
                    && $0.vdisplay == preferred.vdisplay
            }
            .max {
                if $0.refreshMilliHz != $1.refreshMilliHz {
                    return $0.refreshMilliHz < $1.refreshMilliHz
                }
                return $0.name < $1.name
            }
    }
}

enum DrmTopologyDiscovery {
    private static let planeTypePrimary: UInt64 = 1
    private static let planeTypeCursor: UInt64 = 2

    static func scan(fd: Int32, generation: UInt64) -> DrmTopologyInventory? {
        guard let resources = DrmResources(fd: fd) else { return nil }
        let rawCrtcIDs = resources.crtcIds
        let crtcIDs = rawCrtcIDs.map { CrtcID(rawValue: $0) }

        var encoders: [EncoderID: DrmEncoderCandidate] = [:]
        for rawEncoderID in resources.encoderIds {
            guard let encoder = DrmEncoder(fd: fd, encoderId: rawEncoderID) else { continue }
            var compatible: Set<CrtcID> = []
            for (index, crtcID) in crtcIDs.enumerated()
            where index < 32
                && (encoder.possibleCrtcs & (UInt32(1) << UInt32(index))) != 0
            {
                compatible.insert(crtcID)
            }
            let encoderID = EncoderID(rawValue: encoder.encoderId)
            encoders[encoderID] = DrmEncoderCandidate(
                encoderID: encoderID,
                currentCrtcID: encoder.crtcId == 0
                    ? nil : CrtcID(rawValue: encoder.crtcId),
                compatibleCrtcIDs: compatible)
        }

        var currentModes: [CrtcID: DrmModeInfo] = [:]
        for crtcID in crtcIDs {
            guard let crtc = DrmCrtc(fd: fd, crtcId: crtcID.rawValue),
                crtc.modeValid
            else { continue }
            currentModes[crtcID] = crtc.mode
        }

        var planes: [DrmPlaneCandidate] = []
        if let planeResources = DrmPlaneResources(fd: fd) {
            for rawPlaneID in planeResources.planeIds {
                guard let plane = DrmPlane(fd: fd, planeId: rawPlaneID) else { continue }
                var compatible: Set<CrtcID> = []
                for (index, crtcID) in crtcIDs.enumerated()
                where index < 32
                    && (plane.possibleCrtcs & (UInt32(1) << UInt32(index))) != 0
                {
                    compatible.insert(crtcID)
                }
                let rawKind = DrmProperties.findValue(
                    fd: fd, objectId: rawPlaneID, kind: .plane, name: "type") ?? 0
                let kind: DrmPlaneKind
                switch rawKind {
                case planeTypePrimary: kind = .primary
                case planeTypeCursor: kind = .cursor
                default: kind = .overlay
                }
                planes.append(DrmPlaneCandidate(
                    planeID: PlaneID(rawValue: plane.planeId),
                    kind: kind,
                    compatibleCrtcIDs: compatible))
            }
        }

        var connectors: [DrmConnectorCandidate] = []
        for rawConnectorID in resources.connectorIds {
            guard let connector = DrmConnector(fd: fd, connectorId: rawConnectorID),
                connector.isConnected
            else { continue }
            var encoderIDs = connector.encoderIds.map { EncoderID(rawValue: $0) }
            let currentEncoderID = EncoderID(rawValue: connector.encoderId)
            if connector.encoderId != 0, !encoderIDs.contains(currentEncoderID) {
                encoderIDs.append(currentEncoderID)
            }
            let encoderCandidates = encoderIDs.compactMap { encoders[$0] }
            let currentCrtcID = encoders[currentEncoderID]?.currentCrtcID
            let properties = DrmProperties.enumerate(
                fd: fd, objectId: rawConnectorID, kind: .connector)
            connectors.append(DrmConnectorCandidate(
                connectorID: ConnectorID(rawValue: connector.connectorId),
                encoderCandidates: encoderCandidates,
                modes: connector.modes,
                currentCrtcID: currentCrtcID,
                currentMode: currentCrtcID.flatMap { currentModes[$0] },
                physicalSizeMM: PhysicalSize(
                    widthMM: Int32(clamping: connector.mmWidth),
                    heightMM: Int32(clamping: connector.mmHeight)),
                vrrCapable: (DrmProperties.findValue(
                    in: properties, name: "vrr_capable") ?? 0) != 0))
        }

        return DrmTopologyInventory(
            generation: generation,
            crtcIDs: crtcIDs.sorted(),
            connectors: connectors.sorted { $0.connectorID < $1.connectorID },
            planes: planes.sorted { $0.planeID < $1.planeID })
    }
}
