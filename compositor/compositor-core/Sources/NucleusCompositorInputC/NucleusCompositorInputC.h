// NucleusInputC — first-party Clang importer façade over the upstream input
// device, session, and keyboard libraries Swift owns in the compositor runtime:
// libinput (+ libudev) for device discovery and event extraction, libseat for
// session/seat mediation, and libxkbcommon for keymap compilation and keyboard
// state. The upstream headers are clang-importable directly (Rule 7); this façade
// adds only the importer-incompatible bits (Rule 8): the variadic/syscall
// keymap-memfd construction the Wayland keymap fd needs.
//
// Swift consumes libinput_interface / libseat_seat_listener (callback-table
// structs), the udev monitor API, and the xkb context/keymap/state API directly
// from these headers; nothing here reproduces an upstream state machine.
#ifndef NUCLEUS_INPUT_C_H
#define NUCLEUS_INPUT_C_H

// _GNU_SOURCE must precede every libc include so memfd_create, MFD_ALLOW_SEALING,
// and the F_*_SEAL fcntl commands are visible.
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
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

// Build a sealed read-only memfd holding `len` bytes of `text` (the compiled xkb
// keymap string) for sharing through wl_keyboard.keymap. Returns the fd (caller
// owns it) and writes the mapped size (len + 1, including the NUL the protocol
// requires) through `out_size`, or returns -1 on failure. memfd_create is a
// syscall wrapper and F_ADD_SEALS goes through variadic fcntl, neither of which
// the Swift importer can call directly.
static inline int nucleus_input_keymap_memfd(const char *text, size_t len,
                                             uint32_t *out_size) {
    // The shared keymap is NUL-terminated; clients map size bytes and expect the
    // terminator inside the mapping.
    size_t size = len + 1;
    int fd = memfd_create("nucleus-keymap", MFD_CLOEXEC | MFD_ALLOW_SEALING);
    if (fd < 0) return -1;
    if (ftruncate(fd, (off_t)size) != 0) {
        close(fd);
        return -1;
    }
    ssize_t written = 0;
    while ((size_t)written < len) {
        ssize_t n = write(fd, text + written, len - (size_t)written);
        if (n <= 0) {
            close(fd);
            return -1;
        }
        written += n;
    }
    // Seal the keymap so clients can safely mmap it read-only without a private
    // copy (the wl_keyboard.keymap contract). A kernel without seal support is
    // non-fatal — the fd is still usable.
    (void)fcntl(fd, F_ADD_SEALS, F_SEAL_SHRINK | F_SEAL_GROW | F_SEAL_WRITE);
    if (out_size) *out_size = (uint32_t)size;
    return fd;
}

#endif // NUCLEUS_INPUT_C_H
