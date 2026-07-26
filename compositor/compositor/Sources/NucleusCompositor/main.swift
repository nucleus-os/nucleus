import Glibc
import NucleusCompositorRuntime
import NucleusDiagnostics
import NucleusSessionProtocol

let status: Int32
do {
    let configuration = try SessionConfiguration.inherited()
    let readiness = try SessionReadinessReporter.inherited(role: .compositor)
    status = await runNucleusCompositor(
        configuration: configuration,
        readinessReporter: readiness)
} catch {
    NucleusLogger(subsystem: "compositor").error(
        "invalid session launch contract: \(error)")
    status = 1
}
exit(status)
