# Accessibility architecture

## Invariant

NucleusUI owns one platform-neutral accessibility tree with stable semantic
identity, immutable snapshots, incremental updates, typed actions, text/range
state, relationships, live regions, and virtualized children. Platform hosts
translate that tree into their native assistive-technology contract. Rendering
and compositor protocols are not accessibility databases.

Secure content is redacted before it reaches a platform bridge. Accessibility
actions return through the owning `UIContext` and main actor. A bridge never
retains a view as a transport object or grants a shell additional compositor
authority.

## Current Linux implementation

`NucleusUI` publishes `AccessibilityTreeSnapshot` and
`AccessibilityTreeUpdate` from retained views and virtual elements. It supports
stable IDs, roles, traits, state, values, text selection, relationships,
announcements, focus, actions, and incremental subtree reuse.

`NucleusLinuxAccessibility` implements the AT-SPI2 application boundary over
the accessibility bus. It owns:

- accessible, application, component, action, text, editable-text, value,
  selection, and relationship projections;
- exact D-Bus signature validation and typed error replies;
- incremental object publication and event encoding;
- action dispatch into the NucleusUI tree;
- bounded disconnected-event buffering and reconnect registration;
- one reactor-integrated bus connection per UI host.

The native shell installs `AtSPIBridge` and `AtSPIService` at its composition
root. Export-model, wire-boundary, private-bus live, reconnect, malformed
request, announcement, action, and teardown tests define the Linux contract.

## React Native mapping

Fabric accessibility properties lower into the same NucleusUI semantic model.
RN roles, labels, hints, values, state, actions, relationships, live regions,
focus, and text semantics do not create a second accessibility tree. Missing RN
properties are added to the shared vocabulary only when they have a stable
platform-neutral meaning.

## Future platform bridges

The macOS host implements NSAccessibility from the same snapshots and actions.
The Android host projects them through Android accessibility nodes and actions.
A future Windows host implements UI Automation. Each bridge is a separate
platform target with conformance fixtures; none changes the NucleusUI tree
contract to expose native object types.

## Product accessibility

The native shell and applications complete semantic labels, focus order,
keyboard navigation, reduced motion, increased contrast, reduced transparency,
and text scaling as ordinary product work. AT-SPI compatibility allows Orca and
other Linux assistive technologies to consume Nucleus applications.

A bundled screen reader, magnifier, switch control, voice control, and live
captions are separate future products. They are not prerequisites for the
platform bridge. Live captions may consume a future PipeWire audio-capture
service after screen-recording work establishes that service; it does not share
a fictional plan phase or predeclared wire model.

## Verification contract

- Accessibility behavior is tested through snapshots, actions, and live native
  bridge fixtures rather than declaration-shape assertions.
- Virtualized collections expose bounded semantic children without
  materializing offscreen views.
- Secure text exports no recoverable value, selection, or surrounding text.
- Malformed peers receive scoped errors and cannot corrupt bridge state.
- Reconnect retains semantic identity without replaying stale removals or
  duplicate announcements.
- Host teardown removes every bus registration, callback, retained snapshot,
  and reactor source.
