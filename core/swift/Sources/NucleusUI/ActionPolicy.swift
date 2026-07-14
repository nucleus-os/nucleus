import NucleusLayers

public enum ActionPolicy: Sendable, Equatable {
    case none
    case `default`
    case explicit

    package var layersPolicy: NucleusLayers.ActionPolicy {
        switch self {
        case .none:
            .none
        case .default:
            .default
        case .explicit:
            .explicit
        }
    }
}
