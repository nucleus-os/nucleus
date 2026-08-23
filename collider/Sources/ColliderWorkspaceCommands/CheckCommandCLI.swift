import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

enum CheckTarget: String, CaseIterable, ExpressibleByArgument {
    case sanitizers
    case addressSanitizer = "address-sanitizer"
    case undefinedBehaviorSanitizer = "undefined-behavior-sanitizer"
    case threadSanitizer = "thread-sanitizer"
    case androidSourceLock = "android-source-lock"
    case protectedMainSource = "protected-main-source"
}

struct Check: TaskControlledCommand {
    @OptionGroup var taskOptions: TaskControlOptions
    @Argument var target: CheckTarget

    mutating func run(in context: WorkspaceContext) async throws {
        try await context.withExclusiveVerification {
            switch target {
            case .sanitizers:
                try await SanitizerCommand(context: context).run(
                    .all, controls: taskOptions.controls)
            case .addressSanitizer:
                try await SanitizerCommand(context: context).run(
                    .address, controls: taskOptions.controls)
            case .undefinedBehaviorSanitizer:
                try await SanitizerCommand(context: context).run(
                    .undefined, controls: taskOptions.controls)
            case .threadSanitizer:
                try await SanitizerCommand(context: context).run(
                    .thread, controls: taskOptions.controls)
            case .androidSourceLock:
                try await ComponentRegistry(context: context)
                    .verifyAndroidRuntimeSourceLock(controls: taskOptions.controls)
            case .protectedMainSource:
                try await ProtectedMainSourceAssertion(
                    environment: context.environment
                ).validate(
                    repositoryRoot: context.root,
                    observe: context.sourceCaptureReporter())
            }
        }
    }
}
