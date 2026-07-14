#ifndef WAYLAND_WIRE_TEST_C_H
#define WAYLAND_WIRE_TEST_C_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Sends the complete byte stream while attaching `passed_fd` to its first byte.
// Returns 0 on success or a positive errno value on failure.
int swift_wayland_test_send_fd(
    int socket_fd, const void *bytes, size_t byte_count, int passed_fd);

#ifdef __cplusplus
}
#endif

#endif
