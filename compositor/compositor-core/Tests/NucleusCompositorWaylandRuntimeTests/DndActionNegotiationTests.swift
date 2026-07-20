import Testing
@testable import NucleusCompositorWaylandRuntime

@Suite
struct DndActionNegotiationTests {
    @Test func preferredCommonActionWins() throws {
        let result = try DndActionNegotiation.resolve(
            sourceActions: 1 | 2,
            destinationActions: 1 | 2,
            preferredAction: 2)
        #expect(result.selectedAction == 2)
    }

    @Test func deterministicFallbackAndNoIntersection() throws {
        let copy = try DndActionNegotiation.resolve(
            sourceActions: 1 | 2,
            destinationActions: 1 | 2,
            preferredAction: 0)
        #expect(copy.selectedAction == 1)

        let none = try DndActionNegotiation.resolve(
            sourceActions: 2,
            destinationActions: 1,
            preferredAction: 1)
        #expect(none.selectedAction == 0)
    }

    @Test func rejectsInvalidMasksAndPreferredActions() {
        #expect(throws: DndActionNegotiation.ValidationError.invalidMask) {
            try DndActionNegotiation.resolve(
                sourceActions: 1,
                destinationActions: 8,
                preferredAction: 0)
        }
        #expect(
            throws:
                DndActionNegotiation.ValidationError.invalidPreferredAction
        ) {
            try DndActionNegotiation.resolve(
                sourceActions: 1 | 2,
                destinationActions: 1 | 2,
                preferredAction: 1 | 2)
        }
    }
}
