---
name: collider
description: Build, test, inspect, and operate the Nucleus repository with its Collider CLI. Use for Nucleus bootstrap, component builds and tests, task-graph inspection, run logs, cache maintenance, SDK generation, and Android-image work.
---

# Use Collider

Read the repository `AGENTS.md` before changing code or running a workflow.

1. On a fresh clone, run `./collider-setup.sh` once to provision dependencies and install the `collider` launcher.
2. After setup, invoke `collider` from anywhere inside the clone. Never invoke the built executable directly and never source `tools/host-env.sh` for normal Collider usage.
3. Select the narrowest component or task surface that satisfies the request. Use `--dry-run` before an expensive build when task selection or cache state is uncertain.
4. Let Collider own Apple-container creation, persistent workspaces, cancellation, logs, and cleanup. Do not replace its Swift container API path with `container` CLI commands.
5. Keep container actions offline. Host-side Collider actions own downloads and caches; retry an intermittent host download instead of reducing package-manager concurrency or enabling container networking.
6. Inspect durable execution state with `collider runs` and `collider logs`; use the run or task log named by a failure before changing behavior.
7. Preserve the build graph's incremental contract. Use `--rebuild` only when the user requests a forced rebuild or the declared outputs cannot establish the required state.

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
