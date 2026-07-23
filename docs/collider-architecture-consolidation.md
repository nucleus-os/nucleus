# Collider Architecture Consolidation

## Invariant

The Collider CLI is a thin typed front over an asynchronous task runtime. Every
command is parsed exactly once, into a typed value that is the single source of
truth for its options; a command never re-tokenizes an argument array. A command
declares its own capabilities — whether it drives the task graph, whether it
resumes an interrupted run, whether it emits machine-readable output — through
its type, so there is no runtime guard rejecting flags and no second copy of the
command topology anywhere. The runtime module is layered by concern: the task
engine contains only the engine, and the toolchain and Android-SDK provisioning
subsystems it hosts live beside it. There is no synchronous-over-asynchronous
bridge; `await` flows unbroken from `main` through the runtime.

## Target architecture

Four seams define the end state.

1. **One typed parse.** ArgumentParser is the only parser. Each subcommand's
   `@Option`/`@Flag`/`@Argument` fields are authoritative. Cross-field rules live
   in `validate()` or in a `validated()` on the command's typed options value.
   The command implementation types (`RunCommand`, `ChromiumCommand`,
   `AndroidCommand`, `ToolchainCommand`, `InstallCommand`) accept typed values,
   never `ArraySlice<String>`.

2. **Declared capability, not guarded capability.** Commands that drive the task
   graph carry a `TaskControlOptions` group (the plan/explain/verbose/json flags
   plus `--run-id`). Report commands carry at most a `--json` group; side-effect
   commands carry neither. ArgumentParser rejects an unsupported flag at parse
   time, so no command re-checks controls at runtime.

3. **Command-owned resumability.** A resumable task command conforms to a
   protocol that exposes its run identity. `main` consults the parsed command
   through that protocol, never a hardcoded list of command names and never a
   raw scan of `CommandLine.arguments`.

4. **One asynchronous execution seam.** The command tree is
   `AsyncParsableCommand`. `WorkspaceContext.execute` and `WorkspaceContext.run`
   are `async`. The RunRegistry orchestration in `main` is plain `await`. The
   `waitForAsyncResult` bridge does not exist.

The phases below reach this state in sequence. Each phase leaves the tree
building and the `ColliderCommandsTests` and `ColliderCoreTests` suites green.

## Phase 1 — Partition the runtime engine file

`collider/Sources/ColliderRuntime/TaskEngine.swift` is one file carrying the task
engine and two provisioning subsystems that merely happen to sit in the same
`extension ColliderRuntime`. The engine proper — `execute`, `identity`, `assess`,
the two `perform` overloads, and the plan/report types — is roughly a third of
the file. The remainder is host-toolchain assembly, Android-SDK assembly and
wiring, git checkout synchronization, JSON-RPC/LSP framing, embedded
source-template constants, and filesystem/symlink/version helpers.

This phase relocates code without changing behavior, establishing a module whose
structure matches its concerns before any later phase reshapes call sites.

Structural moves, all within `ColliderRuntime`:

- `TaskEngine.swift` retains only `TaskExecutionOptions`, `TaskPlanEntry`,
  `TaskExecutionReport`, `RuntimeFailure`, and the `execute`/`identity`/`assess`/
  `perform` core.
- `HostToolchainAssembly.swift` receives host-toolchain validation and assembly
  (`validateHostToolchain`, `prepareHostToolchainBuild`, `assembleHostToolchain`
  and their helpers).
- `AndroidSDKAssembly.swift` receives Android-SDK validation, assembly, metadata
  rewrite, and wiring (`validateAndroidSDK`, `validateAndroidRuntimeLinkage`,
  `validateAndroidHost`, `assembleAndroidSDK`, `rewriteAndroidSDKMetadata`,
  `wireAndroidSDK`, `androidNDKReadELF`).
- `GitCheckout.swift` receives `syncGitCheckout`.
- `ToolchainSmokeFixtures.swift` receives the embedded source-template `let`
  constants and the JSON-RPC framing helpers that only the smoke tests use.
- `FilesystemSupport.swift` receives the symlink, version-ordering,
  static-archive, and directory helpers.

Provisioning methods stay members of `extension ColliderRuntime` declared in the
new files. Free functions that were `private` become file-scoped `internal`
where a move crosses a file boundary; the two `perform` overloads keep their
distinct signatures so the split does not disturb overload resolution.

Dependencies: none. This phase is prerequisite context for every later phase but
depends on nothing.

Risk surface: mechanical. The only failure mode is an access-level or
overload-resolution regression from `private` widening to `internal`; the
build gate catches both.

## Phase 2 — Command-owned resumability

`main` decides between resuming and beginning a run before it dispatches, and it
does so by scanning raw arguments: `selectedRunID(in:)` walks `CommandLine`
for `--run-id`, and `isResumableTaskCommand(_:)` matches a hardcoded list of
command and subcommand names. This is a second, hand-maintained copy of the
command tree, and `--run-id` is already parsed into `GlobalOptions`. The
duplication exists because `parseAsRoot` yields a type-erased command whose
nested option group `main` cannot read generically.

This phase moves the knowledge onto the commands.

- Introduce `protocol ResumableRun` with a single requirement exposing the
  parsed run identity (`var requestedRunID: String? { get }`).
- The resumable task leaves — the `bootstrap`, `build`, `test`, `generate`
  commands, the `toolchain rebuild` leaf, the `android build`/`native`/`verify`
  leaves, and the `browser bootstrap`/`build`/`test` leaves — conform by
  surfacing `global.runID`.
- `main` replaces both helpers with a single check on the parsed command:
  `(command as? ResumableRun)?.requestedRunID`. A `--run-id` supplied to a
  command that does not conform surfaces the same rejection as today, expressed
  once.

`selectedRunID` and `isResumableTaskCommand` are deleted, and the run-id value
flows from the typed `GlobalOptions` rather than a raw-argument scan.

Dependencies: builds on the partitioned module from Phase 1 only insofar as it
edits `ColliderCommand.swift`, which Phase 1 leaves untouched; it can proceed
directly after Phase 1.

Risk surface: confined to `main` and the command structs. The orchestration
ordering — resume/begin ahead of `command.run()`, status finalization in the
surrounding `do`/`catch` — is preserved unchanged; only the source of the
resumability decision moves.

## Phase 3 — Declared task capability, not guarded capability

`rejectUnsupportedControls` guards roughly ten commands and throws through
`unavailable(_:)`, whose message frames every non-task command as one that "has
not migrated to the Collider task runtime." Most of those commands are report or
side-effect commands — `status`, `logs`, `cache status`, `toolchain install`/
`uninstall` — that will never produce a task plan. The guard is a permanent
capability boundary dressed as an unfinished migration, and the boundary is
applied inconsistently through per-call `allowingDryRun`/`allowingJSON` flags.

This phase expresses the boundary in the type system.

- Split the flags currently bundled in `GlobalOptions` into two groups:
  `TaskControlOptions` carries `--dry-run`, `--explain`, `--verbose`, `--json`,
  and `--run-id`; `ReportOptions` carries only `--json`.
- Task-graph commands adopt `TaskControlOptions`. Report commands that emit
  machine-readable output (`status`, `logs list`, `cache status`, `cache prune`,
  `toolchain status`) adopt `ReportOptions`. Side-effect commands that emit
  neither (`logs show`, `logs tail`) adopt no control group.
- `toolchain install`/`uninstall` keep their `--dry-run` as a first-class
  `@Flag` on the command, since it means "print the privileged invocation," a
  command-specific behavior rather than a task-plan control.

`rejectUnsupportedControls`, `unavailable`, and the "migrated" language are
deleted. An unsupported flag now fails at parse time with ArgumentParser's own
message.

Dependencies: builds on Phase 2, which has already reduced `GlobalOptions` to the
fields this phase repartitions.

Risk surface: confined to `ColliderCommand.swift` option groups and the command
structs' `run()` bodies. Behavior is preserved — `collider status --dry-run`
still fails — as a parse error rather than a runtime error.

## Phase 4 — Single typed parse per command

Each task-driving command is parsed twice today. ArgumentParser produces a typed
struct; the struct's `run()` flattens its fields back into `[String]` through the
`append(_:_:to:)` helper; and the implementation type re-tokenizes that array —
`RunOptions.parse` for `run`, `ChromiumCommand.parse` for `browser`, a string
`switch` for `android`, `RebuildOptions.init(_:)` for `toolchain rebuild`, and
`InstallCommand.parsePrefix` for `install`. Validation and usage text are
maintained twice, and every option is spelled three times.

This phase makes the typed value authoritative.

- `RunCommand.run` accepts a `RunOptions` value. The ArgumentParser `Run`
  command constructs `RunOptions` from its typed fields and calls
  `.validated()`. The hand-written tokenizer `RunOptions.parse` and the
  hand-maintained `RunCommand.usage` block are deleted; `RunOptions.validated`,
  which holds the cross-field rules, is retained and becomes the single
  validation site.
- `ChromiumCommand.run` accepts a `ChromiumOperation`. `Chromium` maps its typed
  argument to the operation directly; `ChromiumCommand.parse` is deleted.
- `AndroidCommand.run` accepts a typed operation value; the string `switch` and
  arity checks are replaced by ArgumentParser subcommands or a typed enum
  argument.
- `ToolchainCommand.rebuild` accepts a `RebuildOptions` value built from the
  `Rebuild` command's typed fields; `RebuildOptions.init(_:)`'s argument walk is
  deleted.
- `InstallCommand.run` accepts the component and optional prefix as typed
  values; `parsePrefix` is deleted.
- The `append(_:_:to:)` helper and `taskControlArguments(_:)` are deleted, since
  no command re-serializes its options; the `Build`/`Test` dispatch passes
  `TaskControls` and typed values into the implementation types directly.

The pinned tests retarget: the `RunOptions.parse` cases exercise `RunOptions`
construction and `.validated()`, and the `ChromiumCommand.parse` cases exercise
the typed `ChromiumOperation` mapping. Behavior and validation coverage are
preserved; only the input representation changes.

Dependencies: builds on Phase 3. With controls already carried as
`TaskControlOptions`, the implementation types receive `TaskControls` and typed
options together, and the last string seam — the `toolchain` dispatch — closes
here.

Risk surface: per-command and test-coupled. Converting one command at a time
keeps each change reviewable, with `run` the largest and highest-value.

## Phase 5 — Asynchronous command tree

`waitForAsyncResult` blocks a thread on a semaphore while a detached task
re-enters the asynchronous world. It exists because ArgumentParser's `run()` is
synchronous while the runtime beneath it — `ColliderRuntime.execute`, the
RunRegistry, subprocess execution — is asynchronous. It sits on nearly every
path, since `WorkspaceContext.run` and `WorkspaceContext.execute` both cross it,
and `main`'s failure and cancellation handling is written as nested
`waitForAsyncResult` blocks rather than `await`.

This phase removes the bridge.

- `ColliderCommand` gains an `@main` asynchronous entry point, and the command
  tree adopts `AsyncParsableCommand` with `func run() async throws`.
- `WorkspaceContext.execute` and `WorkspaceContext.run` become `async`, and the
  implementation types (`ComponentRegistry`, `RunCommand`, `SanitizerCommand`,
  `ToolchainCommand`, `ProfileCapture`, the qualification command) become
  `async` along their call chains.
- `main`'s RunRegistry begin/resume/finish/appendLog calls and its
  interrupt-versus-clean-exit-versus-failure finalization become direct
  `await`s.
- `waitForAsyncResult` is deleted. `WorkspaceManagedCommand`, which wraps a
  long-lived child process for profile capture and qualification, is re-expressed
  over structured tasks so the "start a child and poll it" pattern no longer
  depends on the removed bridge.

Dependencies: builds on Phase 4. With the string-parse layers already removed,
the asynchronous conversion threads through clean typed signatures rather than
dragging tokenizers across the boundary; with Phases 2 and 3 done, `main`'s
orchestration is already at its final shape and only its synchronicity changes.

Risk surface: module-wide but mechanical. The conversion touches most methods in
the command layer because `WorkspaceContext.run` is nearly universal. The
substantive care is in preserving `main`'s status-finalization semantics and in
re-expressing `WorkspaceManagedCommand`; the wide remainder is signature
propagation that the build gate verifies exhaustively.

## Sequencing rationale

Phase 1 is first because a module partitioned by concern is the surface every
later phase edits. Phases 2 and 3 are next because they are self-contained within
`ColliderCommand.swift` and shrink `main` and `GlobalOptions` to their final
shape before those shapes are threaded elsewhere. Phase 4 follows because
collapsing the typed-to-string round trip depends on controls already being
carried as a group and closes the last string seam. Phase 5 is last because the
asynchronous cascade is cleanest once the string layers it would otherwise
propagate are gone and the orchestration it converts is already final.
