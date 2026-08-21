import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

struct Build: TaskControlledCommand {
    @OptionGroup var taskOptions: TaskControlOptions
    @Argument(help: "all, runtime, swift-sdk, android, browser, or a component name.")
    var component: String?

    mutating func run(in context: WorkspaceContext) async throws {
        guard taskOptions.verifyReproduction else {
            try await ComponentRegistry(context: context).build(
                selection: component, controls: taskOptions.controls)
            return
        }
        var verifying = context
        verifying.producesIntoVerificationScratch = true
        try await ComponentRegistry(context: verifying).build(
            selection: component, controls: taskOptions.controls)
        let comparison = try compareVerificationProductions(under: [
            verifying.hostBuildRoot.appending("swiftpm"),
            verifying.cacheRoot.appending("swiftpm"),
        ])
        try context.console.report(
            comparison,
            text: reproductionReport(comparison),
            humanDestination: .standardError)
        guard comparison.reproduced else {
            // Kept on divergence: the two productions are the evidence, and
            // discarding one leaves nothing to compare.
            throw WorkspaceFailure.message(
                "a second production of this source did not reproduce it")
        }
        try discardVerificationProductions(under: [
            verifying.hostBuildRoot.appending("swiftpm"),
            verifying.cacheRoot.appending("swiftpm"),
        ])
    }
}

private func reproductionReport(_ comparison: ReproductionComparison) -> String {
    guard !comparison.products.isEmpty else {
        return "reproduction  nothing was produced a second time"
    }
    var lines: [String] = []
    for product in comparison.products {
        let verdict =
            product.differing.isEmpty && product.missing.isEmpty
            ? "reproduced" : "diverged"
        lines.append(
            "reproduction  \(verdict)  \(product.matched) identical  \(product.scratch)")
        for path in product.differing { lines.append("  differs  \(path)") }
        for path in product.missing { lines.append("  absent from the retained result  \(path)") }
    }
    return lines.joined(separator: "\n")
}
