import Glibc
import NucleusCompositorRuntime
import NucleusLinuxSession

let status: Int32
do {
    let configuration = try SessionConfiguration.inherited()
    let readiness = try SessionReadinessReporter.inherited(role: .compositor)
    status = await runNucleusCompositor(
        configuration: configuration,
        readinessReporter: readiness)
} catch {
    let line = "nucleus-compositor: invalid session launch contract: \(error)\n"
    _ = line.withCString { write(STDERR_FILENO, $0, strlen($0)) }
    status = 1
}
exit(status)
