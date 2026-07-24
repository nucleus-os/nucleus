#ifndef NUCLEUS_ANDROID_SHARED_RING_C_H
#define NUCLEUS_ANDROID_SHARED_RING_C_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct nucleus_android_shared_ring_mapping
    nucleus_android_shared_ring_mapping;
typedef struct nucleus_android_shared_ring_producer
    nucleus_android_shared_ring_producer;
typedef struct nucleus_android_shared_ring_consumer
    nucleus_android_shared_ring_consumer;

typedef struct nucleus_android_shared_ring_descriptors {
    int memory_fd;
    int data_notification_fd;
    int space_notification_fd;
} nucleus_android_shared_ring_descriptors;

typedef struct nucleus_android_shared_ring_diagnostic {
    uint64_t write_backpressure_count;
    uint64_t read_empty_count;
    uint64_t maximum_occupancy;
    uint64_t data_notification_write_count;
    uint64_t data_notification_drain_count;
    uint64_t space_notification_write_count;
    uint64_t space_notification_drain_count;
    int closed;
} nucleus_android_shared_ring_diagnostic;

typedef enum nucleus_android_shared_ring_wait_result {
    NUCLEUS_ANDROID_SHARED_RING_WAIT_ERROR = -1,
    NUCLEUS_ANDROID_SHARED_RING_WAIT_READY = 0,
    NUCLEUS_ANDROID_SHARED_RING_WAIT_ARMED = 1,
    NUCLEUS_ANDROID_SHARED_RING_WAIT_CLOSED = 2,
} nucleus_android_shared_ring_wait_result;

/*
 * A mapping owns the memfd and both eventfds but has no producer or consumer
 * authority. It exists only while wiring endpoints and collecting diagnostics.
 */
nucleus_android_shared_ring_mapping *
nucleus_android_shared_ring_mapping_create(
    uint32_t slot_count,
    uint32_t slot_size);
void nucleus_android_shared_ring_mapping_destroy(
    nucleus_android_shared_ring_mapping *mapping);
int nucleus_android_shared_ring_mapping_export_descriptors(
    nucleus_android_shared_ring_mapping *mapping,
    nucleus_android_shared_ring_descriptors *output);
int nucleus_android_shared_ring_mapping_close(
    nucleus_android_shared_ring_mapping *mapping);
int nucleus_android_shared_ring_mapping_get_diagnostic(
    nucleus_android_shared_ring_mapping *mapping,
    nucleus_android_shared_ring_diagnostic *output);

/*
 * Attach takes ownership of all three descriptors on success and failure.
 * Exactly one producer and one consumer may be attached at a time.
 */
nucleus_android_shared_ring_producer *
nucleus_android_shared_ring_producer_attach(
    nucleus_android_shared_ring_descriptors descriptors);
void nucleus_android_shared_ring_producer_destroy(
    nucleus_android_shared_ring_producer *producer);
int nucleus_android_shared_ring_producer_write(
    nucleus_android_shared_ring_producer *producer,
    const void *bytes,
    uint32_t byte_count);
nucleus_android_shared_ring_wait_result
nucleus_android_shared_ring_producer_prepare_space_wait(
    nucleus_android_shared_ring_producer *producer);
int nucleus_android_shared_ring_producer_space_notification_fd(
    nucleus_android_shared_ring_producer *producer);
int nucleus_android_shared_ring_producer_drain_space_notification(
    nucleus_android_shared_ring_producer *producer);
int nucleus_android_shared_ring_producer_close(
    nucleus_android_shared_ring_producer *producer);
int nucleus_android_shared_ring_producer_get_diagnostic(
    nucleus_android_shared_ring_producer *producer,
    nucleus_android_shared_ring_diagnostic *output);
uint32_t nucleus_android_shared_ring_producer_slot_count(
    nucleus_android_shared_ring_producer *producer);
uint32_t nucleus_android_shared_ring_producer_slot_size(
    nucleus_android_shared_ring_producer *producer);

nucleus_android_shared_ring_consumer *
nucleus_android_shared_ring_consumer_attach(
    nucleus_android_shared_ring_descriptors descriptors);
void nucleus_android_shared_ring_consumer_destroy(
    nucleus_android_shared_ring_consumer *consumer);
int nucleus_android_shared_ring_consumer_read(
    nucleus_android_shared_ring_consumer *consumer,
    void *bytes,
    uint32_t byte_capacity);
nucleus_android_shared_ring_wait_result
nucleus_android_shared_ring_consumer_prepare_data_wait(
    nucleus_android_shared_ring_consumer *consumer);
int nucleus_android_shared_ring_consumer_data_notification_fd(
    nucleus_android_shared_ring_consumer *consumer);
int nucleus_android_shared_ring_consumer_drain_data_notification(
    nucleus_android_shared_ring_consumer *consumer);
int nucleus_android_shared_ring_consumer_close(
    nucleus_android_shared_ring_consumer *consumer);
int nucleus_android_shared_ring_consumer_get_diagnostic(
    nucleus_android_shared_ring_consumer *consumer,
    nucleus_android_shared_ring_diagnostic *output);
uint32_t nucleus_android_shared_ring_consumer_slot_count(
    nucleus_android_shared_ring_consumer *consumer);
uint32_t nucleus_android_shared_ring_consumer_slot_size(
    nucleus_android_shared_ring_consumer *consumer);

void nucleus_android_shared_ring_descriptors_close(
    nucleus_android_shared_ring_descriptors descriptors);

#ifdef __cplusplus
}
#endif

#endif
