// NucleusInputC — first-party Clang importer façade over the upstream input
// device, session, and keyboard libraries Swift owns in the compositor runtime:
// libinput (+ libudev) for device discovery and event extraction, libseat for
// session/seat mediation, and libxkbcommon for keymap compilation and keyboard
// state. The upstream headers are clang-importable directly (Rule 7).
//
// Swift consumes libinput_interface / libseat_seat_listener (callback-table
// structs), the udev monitor API, and the xkb context/keymap/state API directly
// from these headers; nothing here reproduces an upstream state machine.
#ifndef NUCLEUS_INPUT_C_H
#define NUCLEUS_INPUT_C_H

#include <stddef.h>
#include <stdint.h>

#include <libinput.h>
#include <libudev.h>
// libseat.h ships without its own extern "C" guard, so under the Swift C++ interop
// importer its declarations would take C++ linkage and the references would mangle
// away from the C symbols the library exports. Wrap it.
#ifdef __cplusplus
extern "C" {
#endif
#include <libseat.h>
#ifdef __cplusplus
}
#endif
#include <xkbcommon/xkbcommon.h>

#endif // NUCLEUS_INPUT_C_H
