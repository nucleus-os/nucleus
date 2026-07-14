# Compositor Accessibility Direction

Direction-setting doc for accessibility across Nucleus: the AppKit-alike's accessibility property surface, the platform AT bridges (AT-SPI2 on Linux, NSAccessibility on macOS, UIA on Windows), a built-in screen reader, and live captions. Not a plan — most of this is downstream of design-docs work and won't be implementable for a while. The doc captures decisions, sequencing, naming, and the catalyst angle so when the work becomes actionable each piece has a documented direction.

## Why this exists now

Three reasons accessibility has to be thought through ahead of implementation:

1. **RN accessibility props need a home.** RN ships extensive accessibility props (`accessibilityLabel`, `accessibilityRole`, `accessibilityHint`, `accessibilityState`, `accessibilityActions`, `accessibilityValue`, `accessible`, `importantForAccessibility`) on every component. Without an AT bridge wired through to the platform's accessibility infrastructure, these props are dead data. The Nucleus framework surfaces accessibility properties on `View` (`swift/Sources/Nucleus/Accessibility.swift`), but the *bridge* from those properties to the OS accessibility layer is the critical-path piece that doesn't exist yet.
2. **Linux accessibility is genuinely underserved.** Orca is the only mainstream Linux screen reader; live captions on Linux essentially don't exist; magnification and switch-control are inconsistent across desktops. Compared to macOS VoiceOver / Live Captions / Switch Control or Windows Narrator / Live Captions / Magnifier, the gap is wide. Nucleus mirroring macOS-level polish here is a real product opportunity, not a checkbox.
3. **Framework freeze forces explicit commitment.** AT bridges should land before the Nucleus framework's v1.0 API freeze. That commitment needs a coherent picture of what comes after the bridges (screen reader, live captions) so the AT bridges are designed to support those use cases, not just to check the box.

## Linux accessibility landscape

A few facts that shape what's possible:

- **AT-SPI2 (Assistive Technology Service Provider Interface, version 2)** is the Linux accessibility standard. It's a D-Bus protocol with a registry daemon (`at-spi2-registryd`) and a per-application interface tree exposing `org.a11y.atspi.Accessible` plus role-specific interfaces (`Component`, `Action`, `Text`, `Value`, `Selection`, `Table`, `Hypertext`, `EditableText`).
- **AT-SPI2 is D-Bus-based, not Wayland-protocol-based.** Apps speak D-Bus directly to AT clients (Orca, magnifiers, etc.); the compositor is not in the path. This means: no Wayland protocol extension is needed for basic accessibility. The compositor only matters if it wants to provide compositor-driven AT features (focus highlighting overlays, gesture-driven navigation, etc.).
- **GTK4 and Qt6 both speak AT-SPI2 natively.** Apps written in those toolkits are accessible to Orca out of the box. RN apps on Nucleus speaking AT-SPI2 (via the AppKit-alike bridge) puts Nucleus apps on equal footing with native toolkits.
- **Orca** is the de-facto Linux screen reader, primarily maintained by GNOME accessibility folks. Functional but with significant rough edges; the ecosystem around it is small.
- **speech-dispatcher** is the Linux TTS abstraction layer, routing to eSpeak NG, Mimic 3, festival, system TTS, etc. The right thing to integrate against; don't reinvent.
- **whisper.cpp** is the de-facto local speech-to-text in 2026: fast, multilingual, runs real-time on modern hardware. Distil-Whisper variants for low-latency mode. The right STT target for live captions.

## Apple-parity naming

| Apple feature | Apple naming | Nucleus naming | Notes |
|---|---|---|---|
| Screen reader | `VoiceOver` | TBD — `Speak`, `Narrator`, `ScreenReader`, or similar | "VoiceOver" is Apple-trademarked; Microsoft's "Narrator" is also branded though more generic-sounding. Nucleus-native naming territory; no real Apple type to mirror 1:1. |
| Live captions | `Live Captions` | `LiveCaptions` | Generic-enough term; Apple uses it, Microsoft uses it, no trademark concern. 1:1 fine. |
| Accessibility framework | `NSAccessibility` (Cocoa), `Accessibility` (Swift) | The AppKit-alike's accessibility property surface | Per design docs, the AppKit-alike's accessibility surface mirrors the AppKit/UIKit property model. 1:1 in shape, not a 1:1 type-name claim. |
| AT element | `AXUIElement` (private), `NSAccessibilityElement` (public) | Surface implicit on every View — no separate element type needed | The AppKit-alike's View *is* the accessibility element via property protocol conformance. |
| Magnifier | `Zoom` | `Magnifier` (Nucleus-native) | Apple's "Zoom" is too generic and overloaded; "Magnifier" is clearer. |
| Switch control | `Switch Control` | TBD when implemented | Out of scope here; mentioned for completeness. |

The screen-reader naming is the open one. Leaning toward `Speak` — short, clear, no trademark conflict, evokes the function. Final decision waits until the project actually starts.

## The four layers

Accessibility in Nucleus decomposes into four distinct projects with very different scopes. Conflating them muddles planning; separating them makes the dependency graph explicit.

### Layer 1 — Nucleus framework accessibility property surface

**Status: shipped.** The `Accessible` protocol and `AccessibilityProperties` live in `swift/Sources/Nucleus/Accessibility.swift`; every `View` carries the property surface.

What it is: the View base type and every concrete view (Button, Label, TextField, Image, etc.) get accessibility properties as first-class fields:

- `accessibilityLabel: String?` — human-readable name (the accessibility-friendly equivalent of `Text`'s string content)
- `accessibilityRole: AccessibilityRole` — element kind (button, label, link, heading, etc.)
- `accessibilityHint: String?` — additional context for screen reader users
- `accessibilityValue: AccessibilityValue?` — current value for stateful elements (sliders, progress bars)
- `accessibilityState: AccessibilityState` — checked, selected, disabled, focused, expanded
- `accessibilityActions: [AccessibilityAction]` — non-default invocable actions (long-press, custom action buttons)
- `accessibilityTraits: AccessibilityTraits` — additional semantic flags (header, summary element, image, etc.)
- `accessible: Bool` / `accessibilityElementsHidden: Bool` — visibility to AT
- `importantForAccessibility: Importance` — focus ordering hints

These properties exist as Swift fields and are carried through the Nucleus wire
transaction model when they affect compositor/render behavior. RN's
accessibility props map 1:1 to these — RN's accessibility model is itself based
on UIKit/AppKit conventions, so the mapping is direct.

This is the cheapest layer. Shipped on `View` already.

### Layer 2 — Platform AT bridges (framework-freeze blocker)

**Status: designed at the property-surface level, bridges not yet specified.** Lands before Nucleus framework v1.0 freeze per the architecture-separation-plan; not deferred to post-v1.

Three bridges from the AppKit-alike's accessibility properties to the platform AT:

**AT-SPI2 (Linux):**
- Each Window registers as an AT-SPI accessible application via D-Bus (`org.a11y.Bus` registration).
- Each View in the tree exposes `org.a11y.atspi.Accessible` plus role-specific interfaces.
- Property changes on the View emit AT-SPI events (`object:property-change`, `object:state-changed`, `focus:`, etc.).
- Hit-testing: AT-SPI's `Component.GetAccessibleAtPoint` maps to the AppKit-alike's existing hit-test machinery.
- Library choice: hand-rolled D-Bus client or vendor `libatspi` C bindings — TBD when implementation starts.

**NSAccessibility (macOS):**
- Each View conforms to `NSAccessibilityProtocol`.
- The Cocoa runtime walks the View tree via `NSAccessibility` queries. The AppKit-alike's existing View hierarchy answers them naturally.
- Property changes notify AT via `NSAccessibilityPostNotification`.
- Most of this is "implement the protocol on View"; the system handles the rest.

**UIA (Windows):**
- Each View implements an `IRawElementProviderSimple` / `IRawElementProviderFragment` provider via the UIA COM API.
- Property changes notify via `UiaRaiseAutomationEvent`.
- More boilerplate than the macOS path; UIA's COM-shaped API is the cost.

Common substrate across all three: a Zig-side accessibility-tree observer that watches the AppKit-alike's view tree and emits the right events. The AppKit-alike layer translates property changes into platform-specific notifications via this substrate.

**This is the unlock.** Once Layer 2 lands:
- Orca works against any Nucleus app (third-party screen reader support).
- Magnifiers work.
- Switch control works.
- RN's accessibility props become observable to all of the above.
- A future built-in Nucleus screen reader (Layer 3) has something to read from.

The pre-Phase-1 spike from doc 01's freeze posture validates that the AppKit-alike's accessibility properties map cleanly to all three platform AT models. Catches structural mismatches early.

### Layer 3 — Built-in screen reader (`Speak`-or-similar)

**Status: not designed; aspirational. Future direction, post-v1.**

What it is: a Nucleus-bundled screen reader, comparable to macOS VoiceOver. Sits alongside (not instead of) Orca — Linux users can choose either. The Nucleus version's value-add is compositor integration that Orca can't have without compositor cooperation.

Architecture sketch (rough — concrete plan when the project actually starts):

- **AT-SPI2 client.** Subscribes to the AT-SPI registry's events, queries running app trees, tracks focus. Same job Orca does today — the AT-SPI2 bridge from Layer 2 makes Nucleus apps speakable; the screen reader speaks them.
- **TTS engine.** Integrates with `speech-dispatcher` (the right Linux TTS abstraction). Don't reinvent TTS; speech-dispatcher routes to whichever TTS engine the user prefers (eSpeak NG, Mimic 3, system TTS).
- **Focus and gesture layer.** Compositor integration via the focus-architecture work (`is_key` and `front_process` observables) and the trackpad gestures work (`docs/compositor-trackpad-gestures.md`'s gesture pipeline). The screen reader knows which control has focus, can highlight it via a native overlay surface (or via the AppKit-alike once shell widgets are real), and can be navigated with custom gestures.
- **Command surface.** Keyboard shortcuts (read next item, skip headings, list links, etc.) — VoiceOver-style command set as the parity reference. Possibly voice control later.
- **Configuration.** Voice, pace, verbosity, hint level, language — KDL config per `docs/compositor-configuration-system.md`.
- **Implementation language.** Probably a Swift app on the AppKit-alike (eats own dogfood — the screen reader's own UI is accessible via the same machinery it uses to read other apps). Alternative: native Zig service. The Swift app path is more consistent with the documented direction once shell widgets and AppKit-alike both exist.

**Scope:** comparable to one of the shell widgets, possibly larger. Multi-quarter effort. Real engineering investment, not a side project.

**Naming:** TBD. `Speak` is the current lean. Trademark check before any public commitment.

### Layer 4 — Live captions

**Status: not designed; aspirational. Future direction.**

What it is: real-time speech-to-text rendered as captions overlaid on the desktop. Three modes:

- **System audio captions** — caption a video call, a YouTube video, a podcast. STT runs against the audio that would otherwise just be played out the speakers.
- **Microphone captions** — caption your own speech (useful when sharing a call with a hearing-impaired person on the same screen, or for accessibility self-monitoring).
- **Per-app captions** — only caption a specific app (Discord, Zoom, etc.). Requires per-app audio routing, which PipeWire supports.

Components:

- **Audio capture.** Reuses the screen-recording plan's `AudioAdapter` infrastructure (`docs/screen_recording_plan.md` Phase 11). Same PipeWire monitor-source / microphone-source paths; same `SCAudioFrame` shape. Live captions subscribes to those frames instead of feeding them to an encoder.
- **Speech-to-text.** whisper.cpp (or a Distil-Whisper variant for lower latency). Local, fast, real-time on modern hardware, multilingual. Output is timestamped text segments.
- **Captions overlay.** A compositor-rendered surface — native Zig + Skia first, eventually a Swift app on the AppKit-alike. Configurable position (bottom of screen vs top), font size, opacity, language hint.
- **Configuration.** Source selection (system audio, mic, specific app), language, latency-vs-accuracy tradeoff (smaller whisper model = faster + less accurate), model loading at startup vs on-demand. KDL config.

**Scope:** smaller than Layer 3 because the heavy lifting (whisper.cpp, audio capture) exists upstream. The Nucleus-side work is the captions overlay, the audio routing config, and the integration glue.

**Apple parity:** macOS Live Captions (Sequoia+) is the parity reference. Apple's implementation runs entirely on-device using their Neural Engine; whisper.cpp on consumer GPU/CPU is the equivalent on Linux/Windows.

## Sequencing dependencies

```
Layer 1 (Nucleus AX property surface)
    │
    │ ─── Shipped on `View` (Accessibility.swift)
    │
    ▼
Layer 2 (Platform AT bridges: AT-SPI2 / NSAccessibility / UIA)
    │
    │ ─── Before Nucleus framework v1.0 freeze (architecture-separation-plan Phase 8)
    │ ─── Unblocks: Orca, magnifiers, switch control, RN accessibility props
    │ ─── Foundation for Layer 3
    │
    ▼
Layer 3 (Built-in screen reader / "Speak")     Layer 4 (Live captions)
                                                    │
            ▼                                       ▼
    Post-v1, multi-quarter,                 Post-v1, smaller,
    depends on Layer 2 +                    depends on
    focus-architecture work +               screen_recording_plan.md
    trackpad-gestures work +                Phase 11 (AudioAdapter)
    Nucleus maturity
```

Layers 3 and 4 are independent of each other — both depend on Layer 2 plus their respective supporting infrastructure, but they don't depend on each other. Either could ship first.

## Catalyst angle

Linux desktop accessibility is a genuine commons-improvement opportunity:

- **Orca is the only real Linux screen reader.** Anything Nucleus ships that's better is a real contribution that other distros can learn from.
- **Live captions on Linux essentially don't exist.** Shipping them puts Nucleus ahead of mainstream Linux desktop UX in a way that's user-visible and meaningful.
- **macOS VoiceOver users with vision impairments are an underserved segment for Linux migration.** A polished accessibility story removes the biggest blocker for that demographic considering Linux at all.
- **Apple sets the bar.** VoiceOver and Live Captions are the gold standard. Mirroring Apple-class quality on Linux is a coherent story that aligns with the rest of the macOS-mirror project posture.

The catalyst dynamic: shipping accessibility-first means real-world users with real accessibility needs adopt and surface bugs / improvement requests / documentation gaps that pure synthetic testing wouldn't. Linux accessibility improves because there's a concrete consumer driving it forward, not because the abstract engineering case is compelling.

## Cross-references

- `docs/screen_recording_plan.md` — Phase 11's `AudioAdapter` infrastructure is shared with Layer 4 (live captions).
- `docs/compositor-trackpad-gestures.md` — gesture pipeline is consumed by Layer 3 for VoiceOver-style gesture navigation.
- `docs/compositor-configuration-system.md` — KDL config is the substrate for Layer 3 + Layer 4 user settings.

## Out of scope for this direction doc

- **Specific implementation plans for Layers 3 and 4.** Those are aspirational. When they become actionable, each gets its own plan doc.
- **Switch Control, Voice Control, eye-tracking input.** Adjacent accessibility surfaces; possible long-term direction, not in scope here. Each would be its own future project.
- **Closed captions for media playback specifically.** That's an app-level concern (the media app handles its own captions). Live captions here is system-level (caption any audio source regardless of app cooperation).
- **Sign language synthesis / 3D avatar interpreters.** Real research projects; out of scope.
- **Magnifier app.** Mentioned in the naming table but not a full layer here. Smaller project than the screen reader; would graduate to its own plan if it becomes priority. Linux's `gnome-magnifier` and `kmag` are existing-but-rough references.

## When this graduates

This direction doc records decisions and dependencies. Sub-pieces graduate to their own plan docs when:

- **Layer 2 (AT bridges)** graduates to its own plan once doc 01 Phase 1 is shipping and the spike against AT-SPI2 / NSAccessibility / UIA reveals concrete implementation work.
- **Layer 3 (screen reader)** graduates when the AT bridge is complete and there's a triggering need (user demand, accessibility-focused release, etc.).
- **Layer 4 (live captions)** graduates when the screen-recording plan's `AudioAdapter` lands.

Until those graduations, this doc is the source of truth for what direction each layer is heading and what assumptions each downstream plan relies on.
