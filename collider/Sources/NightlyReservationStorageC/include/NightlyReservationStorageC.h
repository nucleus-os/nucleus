#ifndef NUCLEUS_NIGHTLY_RESERVATION_STORAGE_H
#define NUCLEUS_NIGHTLY_RESERVATION_STORAGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Paths are borrowed only for the duration of the call. No pointer is retained,
// no callback runs, and errors are scalar errno values, never exceptions.
// Lock acquisition can block. Swift owns the returned descriptor until unlock.
// Returns an open, exclusively locked descriptor or a negative errno.
int32_t nucleus_reservation_lock(const char *path, int32_t initialize);
void nucleus_reservation_unlock(int32_t descriptor);
int32_t nucleus_reservation_sync_directory(const char *path);
// Publishes a complete candidate and synchronizes both data and its directory.
// Returns zero or a positive errno. A failure after rename has an uncertain
// outcome; callers must retry using the same reservation request ID.
int32_t nucleus_reservation_commit(const char *candidate, const char *destination, const char *directory);

#ifdef __cplusplus
}
#endif

#endif
