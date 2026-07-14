// `nucleus_compositor_window_manager_fullscreen_relinquish_plan` and
// `nucleus_compositor_window_resolve_popup` migrated to `WindowMechanismHost`
// protocol methods.

// wlr-layer-shell is served Swift-native (`NucleusWaylandRouter.ZwlrLayerSurface`):
// the role drives `LayerShellPolicy` in-process, so the former layer-shell host
// relay methods are gone — there is no binding or courier to bridge.
