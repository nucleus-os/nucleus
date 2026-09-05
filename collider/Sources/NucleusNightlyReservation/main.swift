import Foundation
import NightlyReleaseContracts
import NightlyReleaseReservations

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// A standalone authority tool, never a Collider build-graph operation.
/// Its caller must be the protected reservation identity and must authenticate
/// the selection before allocation. No remote workflow exposes it yet.
@main
struct NucleusNightlyReservation {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let operation = arguments.first else { throw usage }
            switch operation {
            case "initialize":
                guard arguments.count == 2 else { throw usage }
                try NightlyReleaseReservationStore(root: URL(fileURLWithPath: arguments[1]))
                    .initialize()
            case "reserve":
                guard arguments.count == 4, let requestID = UUID(uuidString: arguments[2]) else {
                    throw usage
                }
                let selection = try JSONDecoder().decode(
                    NightlyReleaseSelection.self,
                    from: Data(contentsOf: URL(fileURLWithPath: arguments[3])))
                let reservation = try NightlyReleaseReservationStore(
                    root: URL(fileURLWithPath: arguments[1])
                ).reserve(requestID: requestID, selection: selection)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                var data = try encoder.encode(reservation)
                data.append(0x0a)
                try FileHandle.standardOutput.write(contentsOf: data)
            default: throw usage
            }
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    private static var usage: NightlyReleaseFailure {
        NightlyReleaseFailure(
            "usage: nucleus-nightly-reservation initialize <authority-directory> | reserve <authority-directory> <request-uuid> <admitted-selection.json>"
        )
    }
}
