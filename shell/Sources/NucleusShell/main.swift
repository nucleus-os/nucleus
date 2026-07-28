import NucleusShellRuntime
#if canImport(Glibc)
import Glibc
#endif

exit(await runShell())
