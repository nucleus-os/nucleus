# Render Benchmarking

`NUCLEUS_PRESENT_MODE` controls real display presentation policy:

- `vsync`: default tear-free desktop presentation through KMS page flips.
- `mailbox_latest_wins`: experimental latest-frame-wins mailbox path.

`unlimited` is not a present mode. Use the profiling mode when the goal is to
measure render throughput independent of monitor refresh:

```sh
NUCLEUS_PROFILE_RENDER_MODE=uncapped_offscreen
```

The uncapped offscreen benchmark uses the normal `RenderInputs`, composition
plan, producer preparation, and Vulkan scene execution path, but renders into
rotating offscreen textures instead of submitting DRM atomic commits. It keeps
the output size, scale, and format from the active KMS output and reports
240/360/500 Hz budget misses through Tracy events.

From the monorepo root, run:

```sh
tools/nucleus run --tracy --render-benchmark uncapped
```
