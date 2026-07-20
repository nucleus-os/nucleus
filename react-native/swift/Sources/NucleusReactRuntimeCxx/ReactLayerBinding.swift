// React component views are published by `EmbeddedViewTreePublisher`.
//
// This file intentionally contains no per-component layer binding path: mount
// batches mutate the semantic `View` tree, then one publisher transaction
// creates, orders, updates, paints, and removes the corresponding visual tree.
