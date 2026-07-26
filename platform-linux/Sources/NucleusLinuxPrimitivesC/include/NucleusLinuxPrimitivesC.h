#ifndef NUCLEUS_LINUX_PRIMITIVES_C_H
#define NUCLEUS_LINUX_PRIMITIVES_C_H

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <fcntl.h>
#include <linux/memfd.h>
#include <sys/mman.h>
#include <unistd.h>

static inline int nucleus_linux_create_sealable_memfd(const char *name) {
    return memfd_create(name, MFD_CLOEXEC | MFD_ALLOW_SEALING);
}

static inline int nucleus_linux_seal_memfd_immutable(int descriptor) {
    return fcntl(
        descriptor,
        F_ADD_SEALS,
        F_SEAL_SHRINK | F_SEAL_GROW | F_SEAL_WRITE | F_SEAL_SEAL);
}

static inline int nucleus_linux_memfd_is_immutable(int descriptor) {
    const int expected =
        F_SEAL_SHRINK | F_SEAL_GROW | F_SEAL_WRITE | F_SEAL_SEAL;
    const int actual = fcntl(descriptor, F_GET_SEALS);
    return actual >= 0 && (actual & expected) == expected;
}

#endif
