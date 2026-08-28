---
name: collider
description: Build, test, inspect, and operate the Nucleus repository with its Collider CLI. Use for Nucleus bootstrap, component builds and tests, task-graph inspection, run logs, cache maintenance, SDK generation, and Android-image work.
---

# Use Collider

Read the repository `AGENTS.md` before changing code or running a workflow.

1. On a fresh clone, run `./collider-setup.sh` once to provision dependencies and install the `collider` launcher.
2. After setup, invoke `collider` from anywhere inside the clone. Never invoke the built executable directly and never source `tools/host-env.sh` for normal Collider usage.
3. On a host with a machine build store, a command that executes a task graph re-runs itself as the builder identity and reports that on standard error; inspection and dry runs stay in the invoking account. Never invoke the root launcher by hand.
4. Select the narrowest component or task surface that satisfies the request. Use `--dry-run` before an expensive build when task selection or cache state is uncertain.
5. Let Collider own Apple-container creation, persistent workspaces, cancellation, logs, and cleanup. Do not replace its Swift container API path with `container` CLI commands.
6. Keep container actions offline. Host-side Collider actions own downloads and caches; retry an intermittent host download instead of reducing package-manager concurrency or enabling container networking.
7. Inspect durable execution state with `collider runs` and `collider logs`; use the run or task log named by a failure before changing behavior.
8. Preserve the build graph's incremental contract. Use `--rebuild` only when the user requests a forced rebuild or the declared outputs cannot establish the required state.
9. Protected `main` CI is the verification sweep: `collider verify all` plans the complete build and test closure once on each pushed revision, so a local component gate repeats it and contends for the single host execution admission. Scope local verification to the change, then push and read the CI result, and say which tests the local run covered. Iterate on Collider's own host Swift code with `swift test --package-path collider --filter <pattern>`, which needs neither the task graph nor the build store; that is the one place a package's tests run outside Collider, and it never invokes the built Collider executable. Run every other test that needs the graph -- Linux lanes executing in containers, `gpu-headless`, `gpu-drm`, `loader`, `android`, `browser`, release gates, and anything consuming a Swift SDK, native SDK, or image the graph produces -- as `collider test <selection> --filter <pattern>`. A filtered run is a distinct task from the unfiltered one, so it never records the full gate as satisfied.

Read [references/commands.md](references/commands.md) when exact command, argument, option, or subcommand syntax is needed. That reference is generated from Swift Argument Parser's structured representation of the current Collider command tree.

Regenerate this skill after changing Collider command grammar:

```sh
collider skill generate collider
```

Verify every managed skill against its authoritative source. This uses host networking for upstream-backed skills:

```sh
collider skill verify
```

Do not edit generated files under `.agents/skills/collider` by hand. Change `ColliderSkillDocumentation` and regenerate them.
