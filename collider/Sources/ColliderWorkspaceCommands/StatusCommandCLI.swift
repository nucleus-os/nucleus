import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

struct Status: AsyncParsableCommand {
    @OptionGroup var reportOptions: ReportOptions
    mutating func run() async throws {
        let workspace = try context()
        try RepositoryState(context: workspace).printStatus(
            json: reportOptions.json)
    }
}
