# AppKit API completion plan

**Status: active.**

**Invariant: NucleusUI follows AppKit's semantic contracts where they fit retained desktop UI, while rendering and publication remain platform-neutral Nucleus abstractions.**

The render vocabulary, `GraphicsContext`, publication seam, event/responder model, focus, pointer capture, measure/arrange, flex layout, and native shell hosting are implemented. Scroll and multiline authoring belong to `ui-authoring-model.md`; this plan has one remaining scope.

## Phase 1 — Complete the text editor model

Finish secure single-line editing, grapheme and word navigation, selection, deletion, clipboard commands, undo grouping, UTF-8/UTF-16 conversion, and preedit state in one platform-neutral editor model. Secure storage uses the repository secure-memory boundary and never exposes the password through diagnostics or accessibility values.

Gate: behavioral tests cover Unicode, bidi selection, word boundaries, replacement ranges, undo/redo, secure clearing, and teardown.

## Phase 2 — Complete Wayland text input

Bind `text-input-v3` and `input-method-v2` through typed Wayland handlers. Translate surrounding-text, content-type, preedit, commit, delete-surrounding, enter/leave, and done batches into the editor model. Keep protocol state in the Wayland runtime and UI state in NucleusUI.

Gate: wire tests cover valid and hostile sequencing, focus changes, client destruction, byte/code-unit conversion, and cancellation.

## Phase 3 — Close the native lock-screen proof

Use the completed editor and input-method path for the shell lock screen and PAM helper. The shell owns presentation; the isolated helper owns PAM; neither compositor nor logs receive credentials.

Gate: headless behavior tests prove focus, key repeat, IME commit, failed authentication reset, cancellation, and credential zeroization. Interactive lock-screen validation remains a user-run handoff.
