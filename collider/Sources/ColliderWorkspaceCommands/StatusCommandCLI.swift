import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

enum StatusTarget: String, CaseIterable, ExpressibleByArgument {
    case repository
    case swiftSDK = "swift-sdk"
}

struct Status: ColliderInspectionCommand {
    @OptionGroup var outputOptions: CommandOutputOptions
    @Argument var target: StatusTarget = .repository

    mutating func run(in context: WorkspaceContext) async throws {
        switch target {
        case .repository:
            try await RepositoryState(context: context).status()
        case .swiftSDK:
            try await SwiftSDKStatus(context: context).run()
        }
    }
}
