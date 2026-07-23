# Patches

The Collider Swift-platform recipe applies these patches to the source workspace after
`update-checkout` resets each upstream repository. Without them the
build does not complete cleanly on Ubuntu.

## Layout

```
patches/
├── swift/                 # patches against the `swift` upstream repo
├── swift-driver/          # patches against `swift-driver`
├── swift-build/           # patches against `swift-build`
├── swiftpm/               # patches against `swiftpm`
├── indexstore-db/         # patches against `indexstore-db`
└── sourcekit-lsp/         # patches against `sourcekit-lsp`
```

Each subdirectory corresponds to a workspace repository under
`~/.cache/nucleus/swift-source/<source-id>/<repo>/`. Patches in a
subdirectory apply to that repository's root through Collider's typed git
patch operation.

## File format

Each `.patch` file is a unified diff with a free-form header block above
the first `diff --git` line. The header records:

* A `Subject:` line (one-sentence summary).
* A paragraph explaining why the patch exists.
* A `Sentinel:` line naming the unique marker the patch adds to the
  upstream source. The sentinel exists primarily as documentation.

The header is human-only; `git apply` ignores everything above the
`diff --git` line.

## Applying

Collider creates one ordered patch task per repository
after `update-checkout --reset-to-remote`. The helper:

1. Iterates `.patch` files in lexicographic order.
2. Applies a patch when `git apply --check` succeeds.
3. Treats the patch as already applied when
   `git apply --reverse --check` succeeds.
4. Fails loudly if a patch neither applies cleanly nor is already
   applied.

This makes the patch step idempotent and resilient to `update-checkout`
resets, while allowing `git apply --check` or `patch --dry-run` to
validate a patch in isolation before committing it.

## Authoring a new patch

1. From the workspace repo (e.g. `~/.cache/nucleus/swift-source/release-6.4.x/swift`),
   make the change against a clean upstream checkout.
2. Pick a unique sentinel name (convention: `NUCLEUS_SWIFT_SOURCE_<DESCRIPTION>`)
   and add a comment containing that sentinel near the change. This
   protects against accidental drift if two patches touch nearby code.
3. Generate the unified diff: `git diff HEAD -- <changed-file>`.
4. Save it under `patches/<repo>/<NNNN>-<short-name>.patch` with a
   header block per the file format section above. The numeric prefix
   sets the apply order; reserve gaps so future patches can slot in
   between.
5. Drop the changes from the workspace (`git restore`), then run
   `git apply --check` from the affected upstream checkout.

## Removing a patch

1. Delete the `.patch` file.
2. Run `tools/collider toolchain rebuild` — source synchronization discards
   the change on its own.
