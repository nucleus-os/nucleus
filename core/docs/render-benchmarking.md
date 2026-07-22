# Render Benchmarking

`tools/nucleus run --present-mode` controls real display presentation policy:

- `vsync`: default tear-free desktop presentation through KMS page flips.
- `mailbox_latest_wins`: experimental latest-frame-wins mailbox path.

`unlimited` is not a display present mode. Use `tools/nucleus benchmark` for
deterministic, release-built headless throughput baselines. Use
`tools/nucleus run --tracy` when the measurement must include the real KMS
submission and page-flip path.
