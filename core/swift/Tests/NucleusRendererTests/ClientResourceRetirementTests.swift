import Testing
@testable import NucleusRenderer

@Suite
struct ClientResourceRetirementTests {
    @Test func replacementRetiresAtLastPossibleSubmissionWithoutFutureFrame() {
        let retirement = ClientResourceRetirement.atMutation(
            lastSubmittedSerial: 41)

        #expect(retirement.submissionSerial == 41)
        #expect(!retirement.isComplete(completedSubmissionSerial: 40))
        #expect(retirement.isComplete(completedSubmissionSerial: 41))
    }

    @Test func laterSubmissionDoesNotMoveExistingRetirementForward() {
        let retirement = ClientResourceRetirement.atMutation(
            lastSubmittedSerial: 41)
        let laterSubmittedSerial: UInt64 = 42

        #expect(laterSubmittedSerial > retirement.submissionSerial)
        #expect(retirement.isComplete(completedSubmissionSerial: 41))
    }
}
