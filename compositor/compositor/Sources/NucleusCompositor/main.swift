// The compositor executable entry. The runtime is Swift-owned end to end: this
// hands process control to `nucleus_runtime_main` (NucleusCompositorRuntime's
// @c @implementation), which does session isolation, DRM discovery, bring-up,
// the io_uring loop, and teardown, then maps the result to a process exit code.
import Glibc
import NucleusCompositorRuntimeEntry

exit(nucleus_runtime_main())
