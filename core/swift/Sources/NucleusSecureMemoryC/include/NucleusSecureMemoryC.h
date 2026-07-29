#ifndef NUCLEUS_SECURE_MEMORY_C_H
#define NUCLEUS_SECURE_MEMORY_C_H

#include <stddef.h>

// The implementation is compiled as C, so the declaration must keep C linkage
// when a C++ (or C++-interop Swift) translation unit parses this header —
// otherwise the caller emits a mangled reference that never resolves.
#ifdef __cplusplus
extern "C" {
#endif

void nucleus_secure_zero(void *bytes, size_t count);

#ifdef __cplusplus
}
#endif

#endif
