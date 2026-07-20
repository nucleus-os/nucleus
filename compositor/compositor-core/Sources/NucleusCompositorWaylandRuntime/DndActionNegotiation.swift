struct DndActionNegotiation: Sendable, Equatable {
    static let allowedMask: UInt32 = 1 | 2 | 4

    let destinationActions: UInt32
    let preferredAction: UInt32
    let selectedAction: UInt32

    enum ValidationError: Error, Equatable {
        case invalidMask
        case invalidPreferredAction
    }

    static func resolve(
        sourceActions: UInt32,
        destinationActions: UInt32,
        preferredAction: UInt32
    ) throws -> Self {
        guard destinationActions & ~allowedMask == 0 else {
            throw ValidationError.invalidMask
        }
        guard preferredAction & ~allowedMask == 0,
            preferredAction.nonzeroBitCount <= 1,
            preferredAction == 0
                || destinationActions & preferredAction != 0
        else {
            throw ValidationError.invalidPreferredAction
        }

        let common = sourceActions & destinationActions & allowedMask
        let selected: UInt32
        if preferredAction != 0, common & preferredAction != 0 {
            selected = preferredAction
        } else if common & 1 != 0 {
            selected = 1
        } else if common & 2 != 0 {
            selected = 2
        } else if common & 4 != 0 {
            selected = 4
        } else {
            selected = 0
        }
        return Self(
            destinationActions: destinationActions,
            preferredAction: preferredAction,
            selectedAction: selected)
    }
}
