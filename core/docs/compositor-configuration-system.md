# Compositor Configuration System

Direction-setting doc for the Nucleus configuration substrate. Niri-style KDL is the chosen format; this doc records the decision, the scope, and the open questions. Implementation lands as its own plan when one of the queued initiatives (blur tunables, focus dim, gesture mappings, window rules) actually needs the substrate to ship.

## Direction

**KDL** ([kdl.dev](https://kdl.dev)) is the config language. Niri's `niri-config/src/` (`~/Developer/niri/niri-config/`) is the architectural reference for layout and idiom — appearance.rs's `Blur` / `BackgroundEffect` / animation block, input.rs's `focus-follows-mouse` / `warp-mouse-to-focus`, the per-window `window-rule {}` pattern, the schema-validated parsing approach. Adopt niri's *shape* (block-and-property structure, naming conventions for tunable groups, deny-unknown-fields validation) without copying niri's *content* (their column-layout config doesn't apply to a macOS-mirroring compositor).

Two non-negotiables:

1. **Declarative.** No imperative escape hatches in the config file itself. No conditionals, no loops, no inline scripts. If a use case demands runtime logic, it goes through IPC, not through config (see *Out of scope* below — the zx question is settled there).
2. **Hot-reloadable.** Editing the config file applies changes without a compositor restart. The config-load path must be sub-100ms end-to-end so the edit→see-change loop feels instant.

## Why KDL specifically

- **Niri demonstrates it works at this scope.** Their config is the closest peer-compositor to what Nucleus needs (gestures, window rules, animations, output config, layered defaults). The pattern is proven for a Wayland compositor, not theorized.
- **Schema-validatable, LSP-friendly.** KDL has a schema spec; editor tooling (LSP, syntax highlighting) is real and growing. Users get autocomplete and live error reporting in their config editor.
- **Tiny spec.** KDL's grammar fits on a page. A Zig parser is a contained one-time write — no large library dependency, no runtime overhead beyond the parse itself.
- **Block-and-property syntax matches compositor config naturally.** Nested `output {}`, `window-rule {}`, `keybind {}`, `gesture {}` blocks read clearly without YAML's whitespace-sensitivity or TOML's flat-key awkwardness for nested groups.
- **Zero runtime dependency.** Config loading is just file IO + parsing; no Node.js / Python / Lua runtime in the compositor's load path.

Rejected alternatives, named so the decision is visible:

- **TOML / YAML / JSON** — workable but flatter / awkwarder for the nested-block cases the compositor needs (window rules with conditions and actions, keybind sequences with modifiers).
- **Custom format (Hyprland's hyprlang, Sway's sway-config)** — bespoke parser, bespoke editor tooling, no schema. Not worth re-inventing when KDL exists.
- **Lua / Lisp / similar embedded scripting language** — config-as-program failure mode (runtime errors mid-load), large runtime dependency, fragile reload. AwesomeWM's Lua-config experience is informative; the breakage stories are real.
- **JS/TS via Google's zx** — same failure modes as Lua plus a Node.js runtime requirement. Settled in *Out of scope*.

## Scope

What goes in config (declarative knobs, runtime-reloadable):

- **Visual material**: blur parameters per layer-role, window dim level on focus loss, animation curves and durations, default opacity, default rounded-corner radii. Per-`RenderLayer` blur params live in `src/valence/render/RenderLayer.zig`; the `default_unfocused_dim` knob comes from the focus-architecture work.
- **Input**: keyboard layout, repeat rate / delay, modifier key remaps (caps-as-control etc.), pointer acceleration, scroll factor and direction, gesture-to-action mappings. Cross-references `compositor-trackpad-gestures.md` (Phase 4's hard-coded mappings become config-driven once this substrate lands).
- **Output**: per-monitor mode, scale, transform, position, VRR enable, color profile path (when color management lands). Cross-references the existing `output_management.zig` for the protocol-side surface that consumes this.
- **Keybindings**: a flat list of `keybind <chord> <action>` blocks. Actions are a closed enum the compositor knows about (focus-window, raise-window, switch-space, toggle-fullscreen, etc.). No arbitrary command execution — that's an IPC concern.
- **Window rules**: per-app or per-class policy overrides. `window-rule { match { app-id "discord" } { space 3 } { float false } { opacity 1.0 } }` shape. Niri's `window-rule` is the syntactic reference.
- **Spaces**: default Space count, per-Space defaults (wallpaper, layout policy when there's a layout policy to set).
- **Compositor behavior knobs**: cursor theme + size, idle-blank timeout (when idle protocols land), notification position / dismiss-after.

What stays out of config (separate substrates):

- **Runtime state** that should survive across sessions but isn't user-authored — window positions on restart, last-used Space per app, etc. Lives in a state file (separate from config), serialized by the compositor automatically, not human-edited.
- **Scripting / automation** — see *Out of scope*.
- **Per-output policy that requires runtime decision-making** (e.g. "behave differently when this monitor is plugged in" beyond static-mode-config). Workable via window-rule-style match conditions if needed; otherwise IPC.

## Apple-parity considerations

macOS doesn't have a single unified config file. Per-domain `.plist` files (`~/Library/Preferences/com.apple.dock.plist`, etc.) plus `defaults write` are the surface. Nucleus's choice of one unified config file is **Linux-shaped, not macOS-shaped**, and that's intentional — the Linux compositor convention is one config, and matching Linux conventions matters for users coming from other Wayland compositors.

What can mirror Apple inside the config:

- **Naming.** Use Apple-parity terms in the config schema where they map. `space { count 4 }` not `workspace { count 4 }`. `window-rule { is-key true }` not `is-focused`. `dim { unfocused 0.15 }` aligned with the `is_key` / `key_window_dim` internal model. Per CLAUDE.md's strict naming-parity rules.
- **Defaults that match macOS feel.** Animation curves bias toward Apple's standard ease-out; gesture defaults match macOS trackpad behavior (3-finger workspace swipe, 4-finger pinch for Mission Control); dim level is subtle, not loud.

What stays Linux-shaped:

- The unified-config model itself.
- Compositor-side keybindings (macOS does these per-app; Linux compositors do them globally).
- Window rules (macOS doesn't have a user-facing "always float Calculator" surface).

## Implementation sketch (loose)

Not a phase plan — a rough shape so the work is concrete when picked up:

1. **KDL parser.** Native Zig implementation. KDL's grammar is small enough that handwriting it is reasonable; alternative is porting from `kdl-rs` (the canonical Rust implementation under MIT). Either lands as `src/compositor/config/kdl.zig` (or similar). Output: a typed AST.
2. **Config schema.** A Zig type per top-level config block (`OutputConfig`, `KeybindConfig`, `WindowRuleConfig`, etc.) with `parseFromKdl` constructors. Deny-unknown-fields by default to catch typos at load time.
3. **Config loader.** Reads `$XDG_CONFIG_HOME/nucleus/config.kdl` (with fallback to `~/.config/nucleus/config.kdl`), parses, validates, applies. On parse error: load the previous valid config and surface the error via a notification (when notifications work) or stderr (until then).
4. **Hot-reload.** `inotify` watch on the config file (or directory, to handle editor swap-write semantics). On change, re-parse, diff against current config, apply the diff. The diff matters because some changes (output mode) may need re-applying with hardware effects, while others (dim level) are pure value updates.
5. **Default config.** Ship a documented default `config.kdl` alongside the compositor binary, copied to the user's config dir on first run if missing. Documentation lives inline as KDL comments — niri's default config is the reference.
6. **Schema export for editors.** Generate a KDL schema document from the Zig types so VSCode / nvim / Helix LSP setups can validate user configs and offer autocomplete.

## Cross-cutting plan interactions

When this lands, the following queued plans pick up `config.kdl`-driven values that are currently hardcoded or shipped as Zig constants:

- `compositor-blur-improvements.md` Phase 3 (per-layer blur) — config provides `blur { default-radius 10.0; default-noise 0.02; default-saturation 1.5 }` and per-window-rule overrides.
- Focus dim stopgap — `dim { unfocused 0.15; animation-duration 200ms }`.
- `compositor-trackpad-gestures.md` Phase 4 (WM bindings) — gesture→action map becomes user-overridable.
- Window rules generally — the substrate this doc creates is the precondition for any per-app policy work.

None of those plans block on this one; they ship with hardcoded defaults that get exposed to config when this substrate lands.

## Out of scope

- **Scripting / automation.** zx-style imperative scripting is a separate concern, layered on top of IPC (`nucleusctl`). Users wanting runtime logic write a script in any language they like and talk to Nucleus over the socket. The compositor doesn't bake a scripting runtime in. Settled.
- **State persistence (window positions on restart, last-Space per app).** Mentioned above. Different substrate, different file, automatic serialization not user-edited.
- **Theme files** (icon themes, cursor themes, color themes). Standard XDG locations; the config refers to them by name. Not part of `config.kdl`'s own scope.
- **Per-app `.desktop` files.** Standard XDG. Compositor reads them for app metadata; config doesn't replace or augment them.
- **Imperative escape hatch for power users.** Explicitly rejected. If a use case demands logic-in-config, that's a signal to expose a new declarative knob or to make IPC more capable, not to add eval to the config language.

## Open questions (resolve when the implementation plan is written)

- **Multi-file include semantics.** `include "input.kdl"`-style? Niri supports this; useful for separating user config from defaults but adds parser complexity. Defer until needed.
- **Schema versioning.** Config schema will evolve; how does an old config fail forward? Hard-error with migration message? Soft-warn-and-ignore? Niri's current answer is hard-error with the config-version field; that's the cleanest pattern.
- **System vs user config layering.** Is there a `/etc/nucleus/config.kdl` system default that user config overlays? Useful for distro packaging and multi-user systems; not urgent for single-user-laptop use.
- **First-run experience.** Empty `~/.config/nucleus/`? Generate a documented default? Ship with a setup-wizard CLI that walks the user through? Lowest-friction is probably the default-with-comments approach.
- **Live-reload diff fidelity.** How granular does the diff get? Per-block? Per-property? Full-replace-and-reapply is simplest but may cause flicker on output reconfig. Defer the optimization until visible.
- **What happens when the config tries to reference an output / monitor / app that doesn't currently exist?** Window rule for an app that hasn't launched yet — store as pending, apply on first match. Output config for a disconnected monitor — store, apply on hotplug. Keybind referencing an action the build doesn't have — hard-error at parse.

## When this graduates

This doc is direction-setting. It graduates to a real implementation plan (`compositor-configuration-system-impl.md` or absorbs the implementation into itself with proper phases) when one of these triggers fires:

- A queued plan that depends on user-tunable values needs the substrate to ship its user-facing surface.
- Window rules become required to unblock daily-driver workflows that hardcoded behavior can't cover.
- A config-related functionality gap graduates and explicitly needs `config.kdl` to land first.

Until one of those happens, this doc records the decision and waits.
