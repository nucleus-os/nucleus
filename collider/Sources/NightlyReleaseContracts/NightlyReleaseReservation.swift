import ColliderCore
import Foundation

/// The reservation authority's admitted input. Shape validation is not proof
/// of successful CI: the protected admission boundary must authenticate the
/// run and the immutable input manifest before calling the allocator.
package struct NightlyReleaseSelection: Codable, Equatable, Sendable {
    package let sourceCommit: String
    package let verificationRunID: UInt64
    package let inputManifestDigest: ArtifactDigest

    package init(
        sourceCommit: String,
        verificationRunID: UInt64,
        inputManifestDigest: ArtifactDigest
    ) throws {
        self.sourceCommit = sourceCommit
        self.verificationRunID = verificationRunID
        self.inputManifestDigest = inputManifestDigest
        try validate()
    }

    package func validate() throws {
        guard sourceCommit.utf8.count == 40,
            sourceCommit.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
            verificationRunID > 0,
            inputManifestDigest.algorithm == .sha256,
            inputManifestDigest.bytes.count == 32
        else {
            throw NightlyReleaseFailure(
                "selection requires an exact commit, verification run, and SHA-256 input manifest")
        }
    }
}

package struct NightlyReleaseVersion: Codable, Hashable, Comparable, Sendable,
    CustomStringConvertible
{
    package let day: String
    package let sequence: UInt64

    package init(day: String, sequence: UInt64) throws {
        let fields = day.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[0].count == 4,
            fields[1].count == 2, fields[2].count == 2,
            day.utf8.allSatisfy({ $0 == 46 || (48...57).contains($0) }),
            let year = Int(fields[0]), (1...9999).contains(year),
            let month = Int(fields[1]), (1...12).contains(month),
            let date = Int(fields[2]), sequence > 0
        else { throw NightlyReleaseFailure("invalid nightly version date or sequence") }
        let leap = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...days[month - 1]).contains(date) else {
            throw NightlyReleaseFailure("invalid nightly calendar date")
        }
        self.day = day
        self.sequence = sequence
    }

    package init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 4, let sequence = UInt64(fields[3]),
            String(sequence) == fields[3]
        else { throw NightlyReleaseFailure("nightly version must be YYYY.MM.DD.N") }
        try self.init(day: fields.prefix(3).joined(separator: "."), sequence: sequence)
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    package var description: String { "\(day).\(sequence)" }

    package static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.day == rhs.day ? lhs.sequence < rhs.sequence : lhs.day < rhs.day
    }

    package static func utcDay(at date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        func padded(_ value: Int, to width: Int) -> String {
            let digits = String(value)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        return [
            padded(components.year!, to: 4), padded(components.month!, to: 2),
            padded(components.day!, to: 2),
        ].joined(separator: ".")
    }
}

package struct NightlyReleaseReservation: Codable, Equatable, Sendable {
    package let requestID: UUID
    package let selection: NightlyReleaseSelection
    package let version: NightlyReleaseVersion

    package init(
        requestID: UUID, selection: NightlyReleaseSelection, version: NightlyReleaseVersion
    ) {
        self.requestID = requestID
        self.selection = selection
        self.version = version
    }
}

package struct NightlyReleaseFailure: Error, CustomStringConvertible, Sendable {
    package let description: String

    package init(_ description: String) { self.description = description }
}
