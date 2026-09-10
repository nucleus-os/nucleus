# Linux build toolchain faults

Observations, not a plan. Each entry records a fault that is not the change
that happened to be in flight when it appeared, so that a recurrence is
recognised rather than re-diagnosed. Most originate below Collider, in the
Swift toolchain or its runtime inside a build container. Where an entry has not
established that, it says so, because a fault whose origin is open is exactly
the one a second occurrence has to settle.

## SIGSEGV in libdispatch during SwiftBuild task planning

`swift-package-manager` dies on signal 11 while planning a Linux build. The
task fails with status 139 and no diagnostic beyond the progress line it had
reached:

```
Building for production...
[Computing dependencies]
[Constructing description]
[Pre-planning 1 / 712]
```

Where a backtrace was captured, the crash is not in SwiftBuild. It is on
libdispatch's manager thread, in its event loop, and the two lines before it
are the Swift runtime failing to stop a thread:

```
swift-runtime: cannot open status file
swift-runtime: failed to suspend thread 1048 retrying...

*** Program crashed: Bad pointer dereference at 0xffff55553da638f3 ***

Platform: arm64 Linux (Ubuntu 26.04.1 LTS)

Thread 2 "DispatchWorker" crashed:

0      0x0000ffffb341cd08 _dispatch_event_loop_drain + 1228 in libdispatch.so
1 [ra] 0x0000ffffb3412084 _dispatch_mgr_invoke + 123 in libdispatch.so
2 [ra] 0x0000ffffb3411ff8 _dispatch_mgr_thread + 131 in libdispatch.so
```

The other threads are doing ordinary planning work at the time -- one of them
in `ClangCompilerSpec.constructTasks` -- which is what makes the report
misleading at a glance. The thread that faulted is the dispatch manager, and
nothing a build declares reaches it.

### Observed

Three consecutive `verify all` sweeps on 2026-09-08, on the same revision:

| run | failed | status |
| --- | --- | --- |
| `2026-09-08T04-54-51.208Z-10060` | `swift.package.build.sha256:f924a053` | 139 |
| `2026-09-08T05-21-16.226Z-20082` | `swift.package.build.sha256:ba141d6e` | 139 |
| `2026-09-08T05-32-31.855Z-26580` | no build failed | -- |
| `2026-09-09T23-37-48.059Z-75006` | `swift.package.build.sha256:ba141d6e` | 139 |

A different task each time, and the third sweep planned and built every Linux
lane. Both crashing tasks execute in an arm64 container; they differ in the
architecture they target, so the fault is not particular to a lane, a package,
or a target.

The fourth entry is a day later, on a different revision, and repeats the
second exactly: the same task, the same status, and a backtrace naming
`_dispatch_event_loop_drain + 1228` on a thread called `DispatchWorker`. It is
recorded because a fault that recurs on one task across revisions is worth
distinguishing from one that wanders, and because it landed in a sweep whose
other failure had a cause of its own -- a test that forked and then recorded an
expectation in the child. Two unrelated faults in consecutive sweeps is what
makes reading a single red sweep as one story a mistake.

### What makes it appear

The first occurrences followed a change to the C and C++ flags every Linux
SwiftPM invocation receives. That gives each of them a new identity, so eleven
builds that are normally cache hits plan and compile back to back in one sweep.
The fault has not been seen on a sweep where most lanes were clean.

What matters is the count of Linux SwiftPM invocations planning in one sweep,
not what raised it. A change that stopped keying identity on postconditions
re-keyed every task in the graph rather than one lane's flags, and the two
sweeps after it lost a build each -- different tasks, so the attribution rule
below cleared the change itself -- while a third resumed past them and
finished. Treat anything that invalidates Linux lanes in bulk as the condition
that makes this likely, with a graph-wide re-key as its extreme, rather than as
its cause.

### On recurrence

Re-run the sweep. The graph is incremental, so it resumes past the crashed
task rather than repeating the work behind it. Attribute the failure to a
change only if it fails the same task twice.

### Evidence gap

The Swift runtime's backtracer wrote nothing in the CI occurrence and a
complete report in the local one, where it reported taking 18.75 seconds. A
crash inside a container leaves no macOS crash report, so that in-log
backtrace is the whole of the evidence, and the diagnostic bundle described in
[CI diagnostic artifacts](ci-diagnostic-artifacts-contract.md) carries only
what the stage log happened to receive.

## SIGSEGV in a Linux test runner, origin not established

`NucleusReactRuntimeFabricTests-test-runner` exited on signal 11 during a
`swift.package.test` task, in a release build for `aarch64-unknown-linux-gnu`:

```
error: Process '…/NucleusReactRuntimeFabricTests-test-runner --skip …
  --xunit-output …/xunit-29-NucleusReactRuntimeFabricTests.xml
  --testing-library swift-testing' exited with unexpected signal code 11
```

The runner died mid-write, so its xUnit file was truncated and the driver
reported a parse error -- "Premature end of data in tag testsuites" -- beside
the signal. That parse error is a consequence and not a second fault.

### Observed

Once, in run `2026-09-09T05-40-51.737Z-72493` on revision `932d5b62`. Three
suites were running concurrently in that binary, and five tests had started
without reporting when it died, among them
`fabricMeasurementRunsConcurrentlyThroughSendableManager` and
`transactionsShareOneOrderedDrainPerBurst`.

It has not recurred. The lane has executed successfully several times since,
including under a full re-key that ran every task in the graph.

### Why it is recorded separately

It resembles the entry above and is not it. That one is `swift-package-manager`
dying while planning a build; this is a test runner dying while executing one
-- a different process in a different phase, and with no backtrace, where the
other produced a complete one. The sweep that carried this crash also carried
an unrelated hang whose cause was a test that forked and then recorded an
expectation in the child, so reading one red sweep as one story would have
attributed all of it to whichever cause was found first.

### On recurrence

What a second occurrence has to settle is whether this originates below
Collider at all. The tests that never reported are concurrency tests, so a race
in first-party code is as likely as a runtime fault, and nothing observed so
far distinguishes them. Capture the stage log before rerunning: the signal line
is the whole of the evidence today, and a backtrace would decide it.
