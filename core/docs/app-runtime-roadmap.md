# Nucleus Standalone App Runtime — Roadmap

> **The native runtime for in-house design systems.** Ship your own design
> system, pixel-identical on every platform — like Electron — but with native
> performance and native text / IME / scroll / accessibility, from one codebase
> across desktop, mobile, and Linux. The anti-Electron.

**Scope.** This roadmap covers the **standalone app runtime** only. The Wayland
compositor (Nucleus OS) is a separate product that shares core code — Skia,
Nucleus, the render graph — but operates at a different level for a different
audience. No app-level API depends on compositor-only pieces; that boundary is
formalized in Phase 1.

---

## The gap everyone is settling around

Serious cross-platform, brand-forward apps — Discord, Linear, Slack, Figma — all
abandon platform-native UI for a house design system. Every existing way to ship
one forces a compromise. **No incumbent fills all four columns.** That empty cell
is the product.

| Approach | House-style consistent | Native perf / memory | Native text · scroll · a11y | One codebase · desktop + mobile |
| --- | --- | --- | --- | --- |
| **Electron / web** | ✅ | ❌ bloat, battery | ❌ janky, gaps | ❌ desktop only |
| **Flutter** | ✅ | ≈ ok | ❌ self-behaves, foreign | ≈ weak desktop feel |
| **Native per platform** | ❌ drifts | ✅ | ✅ | ❌ N codebases |
| **Nucleus** | ✅ | ✅ | ✅ | ✅ |

---

## The architecture in one idea

Self-draw the **look**, natively drive the **behavior**. Your design system is
one Skia-rendered surface everywhere; underneath it, each platform's native
compositor, text/IME, scrolling, and accessibility do the work. The seam between
them — **the platform-behavior interface** — is the crown-jewel artifact. Design
it once, and every new OS becomes an additive backend rather than a fresh source
of quirks.

| Layer | Apple | Windows | Linux | Android |
| --- | --- | --- | --- | --- |
| **Controls / look** | Skia self-draw | Skia self-draw | Skia self-draw | Skia self-draw |
| **Compositor** | Native — CoreAnimation | Native — DirectComposition | Nucleus — Wayland substrate | Native — SurfaceControl |
| **Text · IME · scroll** | Native — CoreText | Native — TSF | Native — IBus / Fcitx | Native — Android IME |
| **Accessibility** | Native tree — NS / UIAccessibility | Native tree — UIA | Native tree — AT-SPI | Native tree — Android a11y |
| **System integration** | Native | Native | Native | Native |

### The two moats

Every phase should visibly advance both.

- **Moat 01 — Native behavior under a self-drawn UI.** Text editing, IME,
  selection, scroll physics, and a projected accessibility tree that are
  indistinguishable from hand-written native. The hardest thing in the space —
  and the thing Electron and Flutter can't do. Half-solving it makes Nucleus just
  another Flutter.
- **Moat 02 — Web-speed developer experience.** Instant inner loop, hot reload,
  real tooling, RN-optional authoring. Electron wins on velocity; if Nucleus is
  slow to build and iterate, teams stay on Electron despite the perf win. DX is
  not a side quest — it is part of the pitch.

---

## Sequence — prove it vertically before spreading horizontally

The failure mode is adding platforms early and ending up with several half-native
backends and RN-style quirk-hell. Avoid it: prove the self-draw + native-behavior
thesis on the platforms you already have, then treat every new OS as a
conformance test of the platform-behavior interface.

### Phase 1 — Prove the thesis, Linux + Android  ·  *where you already stand*

**Goal.** A self-drawn, house-style UI on a native behavior substrate,
demonstrably better than Electron — done on the platforms you already ship.

- **Design the platform-behavior interface** and back it with Linux (desktop) and
  Android (mobile) — two divergent behavior profiles that stress it usefully.
- **Solve the moat problems for real:** native IME + Nucleus text
  editing/selection, a native accessibility tree projected from self-drawn UI,
  native scroll physics, compositor integration.
- **Make the public API a contract** — specify layout/animation/event semantics
  backend-independently and test the backend against the spec, not against itself.
- **Formalize the app-runtime ↔ compositor boundary** so the app product shares
  core code but takes zero dependency on compositor-only pieces.
- **Stand up a fast app inner loop** — hot reload, edit-to-pixel in seconds. This
  is app-iteration DX (Moat 02), orthogonal to toolchain builds, and the one piece
  of "foundation" work that pays off even for a single developer.
- **Then scaffold a UI-only Discord** as the reference app — the perpetual
  quality benchmark, demo, and regression net. Comes after the foundations above.

**Exit.** Reference app on Linux + Android, custom design system, native text /
IME / scroll and a working a11y tree — beating Electron on feel and memory. Don't
proceed until this is true.

### Phase 2 — Apple backend, macOS → iOS / iPadOS  ·  *hardest bar, unlocks dev*

**Goal.** Validate the interface at the highest native-feel scrutiny, and unlock
the platform your app developers actually work on. Toolchain is stock Xcode —
libc++ native, no custom release system.

- **Apple behavior backend:** CoreAnimation compositor, CoreText + native
  text-input/IME, native scroll, NS/UIAccessibility, native menus and
  notifications.
- **Controls stay Skia-Metal self-draw into CALayer** — house style, not
  native-look controls.
- **macOS first**, then iOS/iPadOS reusing most of the backend (touch, scenes;
  Hermes AOT bytecode already satisfies the no-JIT rule).

**Exit.** Reference app on macOS + iOS, pixel-identical to Linux, native feel, one
codebase. The interface is now proven across two radically different backends.

### Phase 3 — Windows backend  ·  *sequenced after Apple, resourced as a peer*

**Goal.** Largest desktop reach on the now-proven interface — and an easier
native-feel bar than Apple, so it's high reward at lower risk once the seam
exists. Equal priority to Apple in the long run.

- **Windows behavior backend:** DirectComposition compositor, Skia-D3D12
  self-draw, TSF text/IME, UIA accessibility, native integration.
- **Themeable self-draw** — ship a Fluent-flavored theme so an app can blend into
  Windows, or keep the house brand. Same code, a config switch — a choice
  WinUI-mapping can't offer.

**Exit.** Four platforms — Linux, Android, Apple, Windows — one codebase, one
design system.

---

## Deferred — toolchain & release DX

Not critical while Nucleus is a single developer with the toolchain already built,
and while the build intentionally tracks the still-in-flux Swift 6.4 development
branch (rebuilds exist to pull the latest, not to reproduce a pinned state).
Revisit each item when its trigger fires.

- **Prebuilt toolchain + Android SDK artifacts** (published, SHA-verified;
  the host bootstrap downloads instead of building). *Trigger: a second contributor, or
  a CI runner that needs the toolchain.*
- **CI for the toolchain repos** — build → smoke-test (including the libc++ `nm`
  guard) → publish. The libc++ guard has standalone value as a rebuild sanity
  check even solo, but isn't urgent. *Trigger: toolchain regressions start costing
  real time, or a second contributor.*
- **Exact-commit pinning + reproducible builds.** Actively counterproductive
  today — pinning fights the deliberate "track latest 6.4 dev" workflow. *Trigger:
  Swift 6.4 stabilizes / releases, at which point a pinned, reproducible baseline
  becomes worthwhile.*

---

## Always-on — adoption readiness (from Phase 1)

A Discord-tier team needs more than "it runs."

- **Benchmarks vs Electron / Flutter.** Memory, cold start, scroll jank, battery —
  captured from the reference app every phase. This is the sales weapon.
- **Design-system tooling.** Figma tokens → components, a component library, and a
  devtools / inspector for the tier that builds sophisticated design systems.
- **Escape hatches & longevity.** Native interop when teams need it, plus a
  credible roadmap — the young-framework risk is real and must be de-risked
  explicitly.
- **Land a design partner.** One brand-forward, cross-platform team piloting in
  production. The truest validation, and it shapes priorities better than any plan.
