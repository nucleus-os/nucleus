// Atom ↔ window-model bitmask classification — the model-coupled half
// (stateMaskForAtom / windowTypeMaskForAtoms / protocolMask).
//
// The raw _NET_WM_STATE / _NET_WM_WINDOW_TYPE atom lists the property parsers
// populate on an XwaylandSurface are folded here into the authoritative Swift
// OptionSets (XwaylandNetState / XwaylandWindowType / XwaylandProtocols). The
// atom→AtomId resolution is the tested AtomTable.id(of:); this is the trivial
// AtomId→bit tail, mapped against the real model types (no ABI mirror).

import NucleusCompositorXcbC
internal import NucleusCompositorServer

extension AtomId {
    /// The _NET_WM_STATE bit this atom denotes, or nil if it isn't a state atom.
    var netStateBit: XwaylandNetState? {
        switch self {
        case ._NET_WM_STATE_FULLSCREEN: return .fullscreen
        case ._NET_WM_STATE_MAXIMIZED_VERT: return .maximizedVert
        case ._NET_WM_STATE_MAXIMIZED_HORZ: return .maximizedHorz
        case ._NET_WM_STATE_HIDDEN: return .hidden
        case ._NET_WM_STATE_ABOVE: return .above
        case ._NET_WM_STATE_BELOW: return .below
        case ._NET_WM_STATE_DEMANDS_ATTENTION: return .demandsAttention
        case ._NET_WM_STATE_MODAL: return .modal
        case ._NET_WM_STATE_SKIP_TASKBAR: return .skipTaskbar
        case ._NET_WM_STATE_SKIP_PAGER: return .skipPager
        case ._NET_WM_STATE_STICKY: return .sticky
        case ._NET_WM_STATE_FOCUSED: return .focused
        default: return nil
        }
    }

    /// The _NET_WM_WINDOW_TYPE bit this atom denotes, or nil otherwise.
    var windowTypeBit: XwaylandWindowType? {
        switch self {
        case ._NET_WM_WINDOW_TYPE_NORMAL: return .normal
        case ._NET_WM_WINDOW_TYPE_DIALOG: return .dialog
        case ._NET_WM_WINDOW_TYPE_UTILITY: return .utility
        case ._NET_WM_WINDOW_TYPE_TOOLBAR: return .toolbar
        case ._NET_WM_WINDOW_TYPE_SPLASH: return .splash
        case ._NET_WM_WINDOW_TYPE_MENU: return .menu
        case ._NET_WM_WINDOW_TYPE_DROPDOWN_MENU: return .dropdownMenu
        case ._NET_WM_WINDOW_TYPE_POPUP_MENU: return .popupMenu
        case ._NET_WM_WINDOW_TYPE_TOOLTIP: return .tooltip
        case ._NET_WM_WINDOW_TYPE_NOTIFICATION: return .notification
        case ._NET_WM_WINDOW_TYPE_DOCK: return .dock
        case ._NET_WM_WINDOW_TYPE_DESKTOP: return .desktop
        case ._NET_WM_WINDOW_TYPE_DND: return .dragAndDrop
        case ._NET_WM_WINDOW_TYPE_COMBO: return .combo
        default: return nil
        }
    }
}

/// Fold a window's raw _NET_WM_STATE atom list into the model state mask.
func netStateMask(for atoms: [xcb_atom_t], _ table: AtomTable) -> XwaylandNetState {
    var mask: XwaylandNetState = []
    for atom in atoms {
        if let id = table.id(of: atom), let bit = id.netStateBit { mask.insert(bit) }
    }
    return mask
}

/// Fold a window's raw _NET_WM_WINDOW_TYPE atom list into the model type mask.
func windowTypeMask(for atoms: [xcb_atom_t], _ table: AtomTable) -> XwaylandWindowType {
    var mask: XwaylandWindowType = []
    for atom in atoms {
        if let id = table.id(of: atom), let bit = id.windowTypeBit { mask.insert(bit) }
    }
    return mask
}

/// Map the parsed WM_PROTOCOLS bitset to the model protocol mask.
func protocolMask(_ p: WmProtocols) -> XwaylandProtocols {
    var mask: XwaylandProtocols = []
    if p.deleteWindow { mask.insert(.deleteWindow) }
    if p.takeFocus { mask.insert(.takeFocus) }
    if p.ping { mask.insert(.ping) }
    if p.syncRequest { mask.insert(.syncRequest) }
    return mask
}

/// Fixed emission order for _NET_WM_STATE atoms; the published property is
/// byte-stable.
private let netStateEmitOrder: [(XwaylandNetState, AtomId)] = [
    (.fullscreen, ._NET_WM_STATE_FULLSCREEN),
    (.maximizedVert, ._NET_WM_STATE_MAXIMIZED_VERT),
    (.maximizedHorz, ._NET_WM_STATE_MAXIMIZED_HORZ),
    (.hidden, ._NET_WM_STATE_HIDDEN),
    (.above, ._NET_WM_STATE_ABOVE),
    (.below, ._NET_WM_STATE_BELOW),
    (.demandsAttention, ._NET_WM_STATE_DEMANDS_ATTENTION),
    (.modal, ._NET_WM_STATE_MODAL),
    (.skipTaskbar, ._NET_WM_STATE_SKIP_TASKBAR),
    (.skipPager, ._NET_WM_STATE_SKIP_PAGER),
    (.sticky, ._NET_WM_STATE_STICKY),
    (.focused, ._NET_WM_STATE_FOCUSED),
]

/// Publish a window's _NET_WM_STATE from the model state mask: rebuild the surface's
/// cached atom list and write it back on the X window.
func writeNetWmStateMask(
    _ conn: OpaquePointer, _ atoms: AtomTable, _ surface: XwaylandSurface, _ mask: XwaylandNetState
) {
    var states: [xcb_atom_t] = []
    for (bit, id) in netStateEmitOrder where mask.contains(bit) { states.append(atoms[id]) }
    surface.states = states
    writeAtomListProperty(conn, atoms, surface.windowID, atoms[._NET_WM_STATE], states)
    _ = xcb_flush(conn)
}
