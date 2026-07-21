// C-ABI accessors the compositor reactor paths use to drive each output's
// Swift-owned `DisplayLink` by output id. The frame scheduler lives in
// the owning `NucleusCompositorServer` display link;
// these forward the live calls (frame demand, continuous bits, the present-id
// reads the session-lock gate samples, and the next-presentation deadline) back
// to that owner. Each runs synchronously on the compositor (main-actor) thread,
// matching every other `nucleus_runtime_*` crossing.
//
// The per-output lifecycle rides the existing `displayAdd`/`displayRemove`
// crossings (which create/remove the Swift `Display`, hence its `displayLink`),
// so there is no separate create/destroy entry. A call naming an output with no
// Swift `Display` is a no-op / fallback.


