#ifndef NUCLEUS_ANDROID_SHARED_RING_C_H
#define NUCLEUS_ANDROID_SHARED_RING_C_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct nucleus_android_shared_ring nucleus_android_shared_ring;

typedef struct nucleus_android_shared_ring_diagnostic {
    uint64_t write_backpressure_count;
    uint64_t read_empty_count;
    uint64_t maximum_occupancy;
    int closed;
} nucleus_android_shared_ring_diagnostic;

nucleus_android_shared_ring *nucleus_android_shared_ring_create(
    uint32_t slot_count,
    uint32_t slot_size);
/* Takes ownership of all descriptors on success and failure. */
nucleus_android_shared_ring *nucleus_android_shared_ring_attach(
    int memory_fd,
    int data_notification_fd,
    int space_notification_fd);
void nucleus_android_shared_ring_destroy(nucleus_android_shared_ring *ring);
int nucleus_android_shared_ring_export_memory_fd(nucleus_android_shared_ring *ring);
int nucleus_android_shared_ring_export_data_notification_fd(
    nucleus_android_shared_ring *ring);
int nucleus_android_shared_ring_export_space_notification_fd(
    nucleus_android_shared_ring *ring);
int nucleus_android_shared_ring_data_notification_fd(
    nucleus_android_shared_ring *ring);
int nucleus_android_shared_ring_space_notification_fd(
    nucleus_android_shared_ring *ring);
int nucleus_android_shared_ring_write(
    nucleus_android_shared_ring *ring,
    const void *bytes,
    uint32_t byte_count);
int nucleus_android_shared_ring_read(
    nucleus_android_shared_ring *ring,
    void *bytes,
    uint32_t byte_capacity);
int nucleus_android_shared_ring_drain_data_notification(
    nucleus_android_shared_ring *ring);
int nucleus_android_shared_ring_drain_space_notification(
    nucleus_android_shared_ring *ring);
int nucleus_android_shared_ring_close(nucleus_android_shared_ring *ring);
int nucleus_android_shared_ring_get_diagnostic(
    nucleus_android_shared_ring *ring,
    nucleus_android_shared_ring_diagnostic *output);
uint32_t nucleus_android_shared_ring_slot_count(nucleus_android_shared_ring *ring);
uint32_t nucleus_android_shared_ring_slot_size(nucleus_android_shared_ring *ring);

#ifdef __cplusplus
}
#endif

#endif
