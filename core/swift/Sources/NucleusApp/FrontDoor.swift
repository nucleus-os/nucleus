// The single-import front door (migration rule 4). `import NucleusApp` carries the whole
// common authoring surface — the `App` / `Scene` / `WindowGroup` entry vocabulary defined
// here, plus `NucleusUI`'s `View`, `Window`, `Transaction`, geometry, `Color`, and the
// rest of the design-system surface — with no second import for the 90% case.
//
// The re-export stops at `NucleusUI` deliberately. `NucleusUI` already exposes the
// developer-facing versions of the names an app authors with; the lower-level
// `NucleusLayers` shares many of those bare names (`Color`, `Rect`, `Transaction`,
// `Shadow`, `Size`, `ActionPolicy`, `LayerRole`, `CommitSink`, …) as its more primitive
// forms, so re-exporting it would make every one of them ambiguous at the call site.
// Direct layer authoring is the advanced case and keeps its granular `import NucleusLayers`
// — exactly the "granular modules stay importable for advanced use" invariant.
@_exported import NucleusUI
