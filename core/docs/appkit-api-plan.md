# AppKit API completion plan

Status: active.

## Invariant

NucleusUI follows AppKit's semantic contracts where they fit retained desktop
UI, while rendering and publication remain platform-neutral Nucleus
abstractions.

## Current disposition

The platform-neutral text editor, secure single-line storage, Unicode and
UTF-8/UTF-16 conversion, selection, preedit, undo, `TextField`, and `TextView`
are implemented and behavior-tested. The desktop Wayland client and compositor
implement text-input-v3. The native lock screen and isolated PAM helper are
implemented with credential clearing and headless behavior coverage.

The compositor now mediates input-method-v2 against its per-seat text-input-v3
state, including serial-checked commits, popup roles, and keyboard grabs. The
remaining scope is end-to-end IME qualification. Do not rebuild the editor,
text-input-v3 client/server paths, or lock-screen architecture as part of this
plan.

## Phase 1 — Implement input-method-v2 mediation — complete

Vendor and generate the current input-method-v2 protocol, register its manager,
and mediate it against the existing text-input-v3 state. Keep serial tracking,
focus, surrounding text, content type, preedit, commit, delete-surrounding, and
done batches in the Wayland runtime. Keep editor state in NucleusUI.

Gate: wire tests cover valid and hostile sequencing, focus changes, client and
IME destruction, stale serials, byte/code-unit conversion, and cancellation.

## Phase 2 — Qualify the complete text-input path

Exercise a real IME against native editor surfaces and the shell lock screen.
Verify key repeat, preedit replacement, commit, focus transfer, failed
authentication reset, cancellation, credential zeroization, and runtime
teardown.

Gate: all agent-runnable behavior and wire tests pass. Interactive IME and
lock-screen validation is a user-run handoff.
