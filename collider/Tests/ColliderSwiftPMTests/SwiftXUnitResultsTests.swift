import ColliderCore
import Foundation
import Testing

@testable import ColliderSwiftPM

@Test func swiftXUnitResultsRetainPerTestDurationsAndOutcomes() throws {
    let observations = try SwiftXUnitResults.decode(
        Array(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <testsuites>
              <testsuite name="FixtureTests">
                <testcase classname="FixtureTests" name="passes" time="1.25"/>
                <testcase classname="FixtureTests" name="fails" time="0.5">
                  <failure message="injected"/>
                </testcase>
                <testcase classname="FixtureTests" name="skips" time="0">
                  <skipped/>
                </testcase>
              </testsuite>
            </testsuites>
            """.utf8))

    #expect(
        observations == [
            TestCaseObservation(
                suite: "FixtureTests",
                name: "passes",
                durationNanoseconds: 1_250_000_000,
                outcome: .passed),
            TestCaseObservation(
                suite: "FixtureTests",
                name: "fails",
                durationNanoseconds: 500_000_000,
                outcome: .failed),
            TestCaseObservation(
                suite: "FixtureTests",
                name: "skips",
                durationNanoseconds: 0,
                outcome: .skipped),
        ])
}
