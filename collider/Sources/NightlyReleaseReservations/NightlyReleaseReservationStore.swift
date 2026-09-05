import Foundation
import NightlyReleaseContracts
import NightlyReservationStorageC

/// Irreplaceable authority state, outside every build cache and retention root.
/// The owning protected identity is the only writer. Readers consume exported
/// reservations, never an allocation credential or this mutable ledger.
package struct NightlyReleaseReservationStore: Sendable {
    private let root: URL

    package init(root: URL) {
        self.root = root
    }

    /// Provision once. Normal allocation never creates a missing ledger or lock.
    package func initialize() throws {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let error = unsafe nucleus_reservation_sync_directory(root.deletingLastPathComponent().path)
        guard error == 0 else {
            throw NightlyReleaseFailure(
                "could not synchronize authority directory creation (errno \(error))")
        }
        try withLock(initialize: true) {
            guard !FileManager.default.fileExists(atPath: ledgerURL.path) else {
                throw NightlyReleaseFailure("reservation ledger already exists")
            }
            try write([])
        }
    }

    package func reserve(
        requestID: UUID,
        selection: NightlyReleaseSelection,
        now: Date? = nil
    ) throws -> NightlyReleaseReservation {
        try selection.validate()
        return try withLock {
            var reservations = try read()
            if let existing = reservations.first(where: { $0.requestID == requestID }) {
                guard existing.selection == selection else {
                    throw NightlyReleaseFailure(
                        "reservation request ID is already bound to different inputs")
                }
                // Retry after midnight or an uncertain commit still returns the
                // original version. An abandoned reservation remains allocated.
                // Re-establish durability if the earlier rename succeeded but
                // its directory/device synchronization failed.
                try write(reservations)
                return existing
            }
            let day = NightlyReleaseVersion.utcDay(at: now ?? Date())
            var sequence: UInt64 = 1
            if let latest = reservations.last?.version {
                guard day >= latest.day else {
                    throw NightlyReleaseFailure("UTC clock moved behind the last reserved date")
                }
                if day == latest.day {
                    guard latest.sequence < UInt64.max else {
                        throw NightlyReleaseFailure("nightly sequence exhausted")
                    }
                    sequence = latest.sequence + 1
                }
            }
            let reservation = NightlyReleaseReservation(
                requestID: requestID, selection: selection,
                version: try NightlyReleaseVersion(day: day, sequence: sequence))
            reservations.append(reservation)
            try write(reservations)
            return reservation
        }
    }

    private var ledgerURL: URL { root.appendingPathComponent("reservations.json") }

    private func withLock<T>(initialize: Bool = false, _ body: () throws -> T) throws -> T {
        let path = root.appendingPathComponent("reservations.lock").path
        let descriptor = unsafe nucleus_reservation_lock(path, initialize ? 1 : 0)
        guard descriptor >= 0 else {
            throw NightlyReleaseFailure(
                "could not lock reservation authority state (errno \(-descriptor))")
        }
        defer { nucleus_reservation_unlock(descriptor) }
        return try body()
    }

    private func read() throws -> [NightlyReleaseReservation] {
        let values = try JSONDecoder().decode(
            [NightlyReleaseReservation].self, from: Data(contentsOf: ledgerURL))
        var requests = Set<UUID>()
        var previous: NightlyReleaseVersion?
        for value in values {
            try value.selection.validate()
            guard requests.insert(value.requestID).inserted else {
                throw NightlyReleaseFailure("reservation ledger contains a duplicate request")
            }
            if let previous {
                guard value.version > previous,
                    value.version.day == previous.day
                        ? previous.sequence < UInt64.max
                            && value.version.sequence == previous.sequence + 1
                        : value.version.sequence == 1
                else { throw NightlyReleaseFailure("reservation ledger sequence is inconsistent") }
            } else if value.version.sequence != 1 {
                throw NightlyReleaseFailure("reservation ledger does not begin at sequence one")
            }
            previous = value.version
        }
        return values
    }

    private func write(_ values: [NightlyReleaseReservation]) throws {
        let candidate = root.appendingPathComponent(".reservation-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: candidate) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(values)
        try data.write(to: candidate, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: candidate.path)
        let error = unsafe nucleus_reservation_commit(candidate.path, ledgerURL.path, root.path)
        guard error == 0 else {
            throw NightlyReleaseFailure(
                "reservation commit outcome is uncertain (errno \(error)); retry the same request ID"
            )
        }
    }
}
