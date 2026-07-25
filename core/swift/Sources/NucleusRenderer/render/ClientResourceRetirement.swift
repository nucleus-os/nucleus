struct ClientResourceRetirement: Sendable, Equatable {
    let submissionSerial: UInt64

    static func atMutation(
        lastSubmittedSerial: UInt64
    ) -> ClientResourceRetirement {
        ClientResourceRetirement(submissionSerial: lastSubmittedSerial)
    }

    func isComplete(completedSubmissionSerial: UInt64) -> Bool {
        submissionSerial <= completedSubmissionSerial
    }
}
