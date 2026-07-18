#ifndef NUCLEUS_SHELL_INPUT_C_H
#define NUCLEUS_SHELL_INPUT_C_H

#include <stddef.h>
#include <stdint.h>
#include <sys/mman.h>
#include <unistd.h>
#include <xkbcommon/xkbcommon.h>

// Map a `wl_keyboard.keymap` fd read-only and return the pointer, or NULL.
// mmap's variadic-free signature is importable, but the PROT_/MAP_ constant
// combination and the failure sentinel are clearer wrapped than spelled out at
// the Swift call site.
static inline const char *nucleus_shell_map_keymap_fd(int fd, uint32_t size) {
    if (fd < 0 || size == 0) { return NULL; }
    // MAP_PRIVATE: the compositor may share one keymap with every client, so the
    // mapping must not be writable through this fd.
    void *mapped = mmap(NULL, (size_t)size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (mapped == MAP_FAILED) { return NULL; }
    return (const char *)mapped;
}

static inline void nucleus_shell_unmap_keymap(const char *ptr, uint32_t size) {
    if (ptr != NULL && size != 0) { munmap((void *)ptr, (size_t)size); }
}

#endif
