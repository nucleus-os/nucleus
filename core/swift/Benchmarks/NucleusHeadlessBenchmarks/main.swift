import Foundation
import NucleusBenchmarkSupport

@main
struct NucleusHeadlessBenchmarks {
    @MainActor
    static func main() async {
        do {
            let workloads = publicationBenchmarks()
                + textAndCollectionBenchmarks()
                + resourceBenchmarks()
                + renderModelBenchmarks()
            try await BenchmarkProgram.run(
                workloads: workloads,
                arguments: Array(CommandLine.arguments.dropFirst()),
                productName: "NucleusHeadlessBenchmarks")
        } catch {
            FileHandle.standardError.write(Data("benchmark error: \(error)\n".utf8))
            exit(1)
        }
    }

}
