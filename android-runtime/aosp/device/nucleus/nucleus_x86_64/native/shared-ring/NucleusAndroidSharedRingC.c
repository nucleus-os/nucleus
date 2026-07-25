#define _GNU_SOURCE
#include "NucleusAndroidSharedRingC.h"

#include <errno.h>
#include <fcntl.h>
#include <linux/memfd.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define NUCLEUS_ANDROID_RING_MAGIC UINT32_C(0x4e524e47)
#define NUCLEUS_ANDROID_RING_HEADER_SIZE 128u
#define NUCLEUS_ANDROID_RING_MIN_SLOTS 2u
#define NUCLEUS_ANDROID_RING_MAX_SLOTS 4096u
#define NUCLEUS_ANDROID_RING_MIN_SLOT_SIZE 64u
#define NUCLEUS_ANDROID_RING_MAX_SLOT_SIZE (16u * 1024u * 1024u)
#define NUCLEUS_ANDROID_RING_PRODUCER_CLAIM UINT32_C(1)
#define NUCLEUS_ANDROID_RING_CONSUMER_CLAIM UINT32_C(2)

/*
 * Producer-owned fields occupy cache line zero. Immutable metadata and the
 * infrequently written close/claim state live on that line because endpoints
 * cache slot_count and slot_size locally after validation.
 *
 * Consumer-owned fields occupy cache line one. A peer reads or conditionally
 * modifies the opposite line only when publishing an index or consuming an
 * armed wait; producer and consumer index stores never invalidate each other.
 */
struct nucleus_android_shared_ring_header {
    _Alignas(64) _Atomic uint64_t write_index;
    _Atomic uint64_t write_backpressure_count;
    _Atomic uint64_t maximum_occupancy;
    _Atomic uint64_t data_notification_write_count;
    _Atomic uint64_t space_notification_drain_count;
    _Atomic uint32_t space_wait_armed;
    _Atomic uint32_t closed;
    _Atomic uint32_t endpoint_claims;
    uint32_t slot_count;
    uint32_t slot_size;
    uint32_t magic;

    _Alignas(64) _Atomic uint64_t read_index;
    _Atomic uint64_t read_empty_count;
    _Atomic uint64_t space_notification_write_count;
    _Atomic uint64_t data_notification_drain_count;
    _Atomic uint32_t data_wait_armed;
    uint8_t consumer_padding[28];
};

_Static_assert(
    sizeof(struct nucleus_android_shared_ring_header) ==
        NUCLEUS_ANDROID_RING_HEADER_SIZE,
    "shared ring header size changed");
_Static_assert(
    _Alignof(struct nucleus_android_shared_ring_header) == 64,
    "shared ring header alignment changed");
_Static_assert(
    offsetof(struct nucleus_android_shared_ring_header, write_index) == 0,
    "producer cache line no longer starts with write_index");
_Static_assert(
    offsetof(struct nucleus_android_shared_ring_header, read_index) == 64,
    "consumer cache line no longer starts at byte 64");
_Static_assert(
    offsetof(struct nucleus_android_shared_ring_header, space_wait_armed) < 64,
    "producer wait state escaped the producer cache line");
_Static_assert(
    offsetof(struct nucleus_android_shared_ring_header, data_wait_armed) >= 64,
    "consumer wait state escaped the consumer cache line");

enum nucleus_android_shared_ring_role {
    NUCLEUS_ANDROID_RING_ROLE_MAPPING = 0,
    NUCLEUS_ANDROID_RING_ROLE_PRODUCER = NUCLEUS_ANDROID_RING_PRODUCER_CLAIM,
    NUCLEUS_ANDROID_RING_ROLE_CONSUMER = NUCLEUS_ANDROID_RING_CONSUMER_CLAIM,
};

struct nucleus_android_shared_ring_endpoint {
    int memory_fd;
    int data_notification_fd;
    int space_notification_fd;
    size_t mapping_size;
    struct nucleus_android_shared_ring_header *header;
    uint8_t *slots;
    uint32_t slot_count;
    uint32_t slot_size;
    enum nucleus_android_shared_ring_role role;
    bool role_claimed;
};

static struct nucleus_android_shared_ring_endpoint *
nucleus_android_mapping_endpoint(
    nucleus_android_shared_ring_mapping *mapping) {
    return (struct nucleus_android_shared_ring_endpoint *)(void *)mapping;
}

static struct nucleus_android_shared_ring_endpoint *
nucleus_android_producer_endpoint(
    nucleus_android_shared_ring_producer *producer) {
    return (struct nucleus_android_shared_ring_endpoint *)(void *)producer;
}

static struct nucleus_android_shared_ring_endpoint *
nucleus_android_consumer_endpoint(
    nucleus_android_shared_ring_consumer *consumer) {
    return (struct nucleus_android_shared_ring_endpoint *)(void *)consumer;
}

static bool nucleus_android_ring_layout(
    uint32_t slot_count,
    uint32_t slot_size,
    size_t *output_size) {
    if (slot_count < NUCLEUS_ANDROID_RING_MIN_SLOTS ||
        slot_count > NUCLEUS_ANDROID_RING_MAX_SLOTS ||
        slot_size < NUCLEUS_ANDROID_RING_MIN_SLOT_SIZE ||
        slot_size > NUCLEUS_ANDROID_RING_MAX_SLOT_SIZE ||
        slot_size > SIZE_MAX / slot_count) {
        errno = EINVAL;
        return false;
    }
    const size_t slots_size = (size_t)slot_count * slot_size;
    if (slots_size > SIZE_MAX - NUCLEUS_ANDROID_RING_HEADER_SIZE) {
        errno = EOVERFLOW;
        return false;
    }
    *output_size = NUCLEUS_ANDROID_RING_HEADER_SIZE + slots_size;
    return true;
}

static int nucleus_android_dup_cloexec(int fd) {
    return fcntl(fd, F_DUPFD_CLOEXEC, 3);
}

void nucleus_android_shared_ring_descriptors_close(
    nucleus_android_shared_ring_descriptors descriptors) {
    if (descriptors.space_notification_fd >= 0) {
        close(descriptors.space_notification_fd);
    }
    if (descriptors.data_notification_fd >= 0) {
        close(descriptors.data_notification_fd);
    }
    if (descriptors.memory_fd >= 0) {
        close(descriptors.memory_fd);
    }
}

static struct nucleus_android_shared_ring_endpoint *nucleus_android_ring_map(
    nucleus_android_shared_ring_descriptors descriptors,
    size_t mapping_size,
    enum nucleus_android_shared_ring_role role) {
    void *mapping = mmap(
        NULL,
        mapping_size,
        PROT_READ | PROT_WRITE,
        MAP_SHARED,
        descriptors.memory_fd,
        0);
    if (mapping == MAP_FAILED) {
        return NULL;
    }
    struct nucleus_android_shared_ring_endpoint *endpoint =
        calloc(1, sizeof(*endpoint));
    if (!endpoint) {
        const int saved = errno;
        munmap(mapping, mapping_size);
        errno = saved;
        return NULL;
    }
    endpoint->memory_fd = descriptors.memory_fd;
    endpoint->data_notification_fd = descriptors.data_notification_fd;
    endpoint->space_notification_fd = descriptors.space_notification_fd;
    endpoint->mapping_size = mapping_size;
    endpoint->header = mapping;
    endpoint->slots =
        (uint8_t *)mapping + NUCLEUS_ANDROID_RING_HEADER_SIZE;
    endpoint->role = role;
    return endpoint;
}

static void nucleus_android_ring_destroy(
    struct nucleus_android_shared_ring_endpoint *endpoint) {
    if (!endpoint) {
        return;
    }
    if (endpoint->role_claimed && endpoint->header) {
        atomic_fetch_and_explicit(
            &endpoint->header->endpoint_claims,
            ~(uint32_t)endpoint->role,
            memory_order_release);
    }
    if (endpoint->header && endpoint->mapping_size > 0) {
        munmap(endpoint->header, endpoint->mapping_size);
    }
    if (endpoint->space_notification_fd >= 0) {
        close(endpoint->space_notification_fd);
    }
    if (endpoint->data_notification_fd >= 0) {
        close(endpoint->data_notification_fd);
    }
    if (endpoint->memory_fd >= 0) {
        close(endpoint->memory_fd);
    }
    free(endpoint);
}

static bool nucleus_android_ring_atomics_are_lock_free(
    struct nucleus_android_shared_ring_header *header) {
    return
        atomic_is_lock_free(&header->write_index) &&
        atomic_is_lock_free(&header->write_backpressure_count) &&
        atomic_is_lock_free(&header->maximum_occupancy) &&
        atomic_is_lock_free(&header->data_notification_write_count) &&
        atomic_is_lock_free(&header->space_notification_drain_count) &&
        atomic_is_lock_free(&header->space_wait_armed) &&
        atomic_is_lock_free(&header->closed) &&
        atomic_is_lock_free(&header->endpoint_claims) &&
        atomic_is_lock_free(&header->read_index) &&
        atomic_is_lock_free(&header->read_empty_count) &&
        atomic_is_lock_free(&header->space_notification_write_count) &&
        atomic_is_lock_free(&header->data_notification_drain_count) &&
        atomic_is_lock_free(&header->data_wait_armed);
}

nucleus_android_shared_ring_mapping *
nucleus_android_shared_ring_mapping_create(
    uint32_t slot_count,
    uint32_t slot_size) {
    size_t mapping_size = 0;
    if (!nucleus_android_ring_layout(
            slot_count,
            slot_size,
            &mapping_size)) {
        return NULL;
    }
    const int memory_fd = memfd_create(
        "nucleus-gfxstream-ring",
        MFD_CLOEXEC | MFD_ALLOW_SEALING);
    if (memory_fd < 0) {
        return NULL;
    }
    if (ftruncate(memory_fd, (off_t)mapping_size) < 0) {
        const int saved = errno;
        close(memory_fd);
        errno = saved;
        return NULL;
    }
    const int data_notification_fd =
        eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (data_notification_fd < 0) {
        const int saved = errno;
        close(memory_fd);
        errno = saved;
        return NULL;
    }
    const int space_notification_fd =
        eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (space_notification_fd < 0) {
        const int saved = errno;
        close(data_notification_fd);
        close(memory_fd);
        errno = saved;
        return NULL;
    }
    const nucleus_android_shared_ring_descriptors descriptors = {
        .memory_fd = memory_fd,
        .data_notification_fd = data_notification_fd,
        .space_notification_fd = space_notification_fd,
    };
    struct nucleus_android_shared_ring_endpoint *mapping =
        nucleus_android_ring_map(
            descriptors,
            mapping_size,
            NUCLEUS_ANDROID_RING_ROLE_MAPPING);
    if (!mapping) {
        const int saved = errno;
        nucleus_android_shared_ring_descriptors_close(descriptors);
        errno = saved;
        return NULL;
    }

    memset(mapping->header, 0, sizeof(*mapping->header));
    atomic_init(&mapping->header->write_index, 0);
    atomic_init(&mapping->header->write_backpressure_count, 0);
    atomic_init(&mapping->header->maximum_occupancy, 0);
    atomic_init(&mapping->header->data_notification_write_count, 0);
    atomic_init(&mapping->header->space_notification_drain_count, 0);
    atomic_init(&mapping->header->space_wait_armed, 0);
    atomic_init(&mapping->header->closed, 0);
    atomic_init(&mapping->header->endpoint_claims, 0);
    mapping->header->slot_count = slot_count;
    mapping->header->slot_size = slot_size;
    mapping->header->magic = NUCLEUS_ANDROID_RING_MAGIC;
    atomic_init(&mapping->header->read_index, 0);
    atomic_init(&mapping->header->read_empty_count, 0);
    atomic_init(&mapping->header->space_notification_write_count, 0);
    atomic_init(&mapping->header->data_notification_drain_count, 0);
    atomic_init(&mapping->header->data_wait_armed, 0);
    mapping->slot_count = slot_count;
    mapping->slot_size = slot_size;

    if (!nucleus_android_ring_atomics_are_lock_free(mapping->header)) {
        nucleus_android_ring_destroy(mapping);
        errno = ENOTSUP;
        return NULL;
    }
    if (fcntl(
            memory_fd,
            F_ADD_SEALS,
            F_SEAL_GROW | F_SEAL_SHRINK | F_SEAL_SEAL) < 0) {
        nucleus_android_ring_destroy(mapping);
        return NULL;
    }
    return (nucleus_android_shared_ring_mapping *)(void *)mapping;
}

void nucleus_android_shared_ring_mapping_destroy(
    nucleus_android_shared_ring_mapping *mapping) {
    nucleus_android_ring_destroy(
        nucleus_android_mapping_endpoint(mapping));
}

int nucleus_android_shared_ring_mapping_export_descriptors(
    nucleus_android_shared_ring_mapping *mapping,
    nucleus_android_shared_ring_descriptors *output) {
    if (!mapping || !output) {
        errno = EINVAL;
        return -1;
    }
    struct nucleus_android_shared_ring_endpoint *endpoint =
        nucleus_android_mapping_endpoint(mapping);
    *output = (nucleus_android_shared_ring_descriptors) {
        .memory_fd = -1,
        .data_notification_fd = -1,
        .space_notification_fd = -1,
    };
    output->memory_fd = nucleus_android_dup_cloexec(endpoint->memory_fd);
    if (output->memory_fd < 0) {
        return -1;
    }
    output->data_notification_fd =
        nucleus_android_dup_cloexec(endpoint->data_notification_fd);
    if (output->data_notification_fd < 0) {
        const int saved = errno;
        nucleus_android_shared_ring_descriptors_close(*output);
        *output = (nucleus_android_shared_ring_descriptors) {
            .memory_fd = -1,
            .data_notification_fd = -1,
            .space_notification_fd = -1,
        };
        errno = saved;
        return -1;
    }
    output->space_notification_fd =
        nucleus_android_dup_cloexec(endpoint->space_notification_fd);
    if (output->space_notification_fd < 0) {
        const int saved = errno;
        nucleus_android_shared_ring_descriptors_close(*output);
        *output = (nucleus_android_shared_ring_descriptors) {
            .memory_fd = -1,
            .data_notification_fd = -1,
            .space_notification_fd = -1,
        };
        errno = saved;
        return -1;
    }
    return 0;
}

static struct nucleus_android_shared_ring_endpoint *
nucleus_android_ring_attach(
    nucleus_android_shared_ring_descriptors descriptors,
    enum nucleus_android_shared_ring_role role) {
    if (descriptors.memory_fd < 0 ||
        descriptors.data_notification_fd < 0 ||
        descriptors.space_notification_fd < 0 ||
        (role != NUCLEUS_ANDROID_RING_ROLE_PRODUCER &&
         role != NUCLEUS_ANDROID_RING_ROLE_CONSUMER)) {
        nucleus_android_shared_ring_descriptors_close(descriptors);
        errno = EINVAL;
        return NULL;
    }

    struct stat status;
    if (fstat(descriptors.memory_fd, &status) < 0) {
        const int saved = errno;
        nucleus_android_shared_ring_descriptors_close(descriptors);
        errno = saved;
        return NULL;
    }
    if (status.st_size < (off_t)NUCLEUS_ANDROID_RING_HEADER_SIZE ||
        (uintmax_t)status.st_size > SIZE_MAX) {
        nucleus_android_shared_ring_descriptors_close(descriptors);
        errno = EPROTO;
        return NULL;
    }

    const size_t mapping_size = (size_t)status.st_size;
    struct nucleus_android_shared_ring_endpoint *endpoint =
        nucleus_android_ring_map(descriptors, mapping_size, role);
    if (!endpoint) {
        const int saved = errno;
        nucleus_android_shared_ring_descriptors_close(descriptors);
        errno = saved;
        return NULL;
    }

    size_t expected_size = 0;
    const bool valid =
        endpoint->header->magic == NUCLEUS_ANDROID_RING_MAGIC &&
        nucleus_android_ring_layout(
            endpoint->header->slot_count,
            endpoint->header->slot_size,
            &expected_size) &&
        expected_size == mapping_size &&
        nucleus_android_ring_atomics_are_lock_free(endpoint->header);
    if (!valid) {
        nucleus_android_ring_destroy(endpoint);
        errno = EPROTO;
        return NULL;
    }
    endpoint->slot_count = endpoint->header->slot_count;
    endpoint->slot_size = endpoint->header->slot_size;

    const uint32_t previous = atomic_fetch_or_explicit(
        &endpoint->header->endpoint_claims,
        (uint32_t)role,
        memory_order_acq_rel);
    if ((previous & (uint32_t)role) != 0) {
        nucleus_android_ring_destroy(endpoint);
        errno = EBUSY;
        return NULL;
    }
    endpoint->role_claimed = true;
    return endpoint;
}

nucleus_android_shared_ring_producer *
nucleus_android_shared_ring_producer_attach(
    nucleus_android_shared_ring_descriptors descriptors) {
    return (nucleus_android_shared_ring_producer *)(void *)
        nucleus_android_ring_attach(
            descriptors,
            NUCLEUS_ANDROID_RING_ROLE_PRODUCER);
}

void nucleus_android_shared_ring_producer_destroy(
    nucleus_android_shared_ring_producer *producer) {
    nucleus_android_ring_destroy(
        nucleus_android_producer_endpoint(producer));
}

nucleus_android_shared_ring_consumer *
nucleus_android_shared_ring_consumer_attach(
    nucleus_android_shared_ring_descriptors descriptors) {
    return (nucleus_android_shared_ring_consumer *)(void *)
        nucleus_android_ring_attach(
            descriptors,
            NUCLEUS_ANDROID_RING_ROLE_CONSUMER);
}

void nucleus_android_shared_ring_consumer_destroy(
    nucleus_android_shared_ring_consumer *consumer) {
    nucleus_android_ring_destroy(
        nucleus_android_consumer_endpoint(consumer));
}

static int nucleus_android_shared_ring_signal_fd(
    int notification_fd,
    _Atomic uint64_t *write_count) {
    const uint64_t value = 1;
    ssize_t result;
    do {
        result = write(notification_fd, &value, sizeof(value));
    } while (result < 0 && errno == EINTR);
    if (result == (ssize_t)sizeof(value)) {
        atomic_fetch_add_explicit(
            write_count,
            1,
            memory_order_relaxed);
        return 0;
    }
    if (result < 0 && errno == EAGAIN) {
        return 0;
    }
    return -1;
}

static int nucleus_android_shared_ring_signal_if_armed(
    _Atomic uint32_t *armed,
    int notification_fd,
    _Atomic uint64_t *write_count) {
    /*
     * Index publication, waiter arming, and the corresponding rechecks share
     * one sequentially consistent order. Therefore either the waiter observes
     * the published index or this load observes the arm. Avoid the RMW entirely
     * in the ordinary unarmed case so the peer cache line stays read-only.
     */
    if (atomic_load_explicit(
            armed,
            memory_order_seq_cst) == 0) {
        return 0;
    }
    uint32_t expected = 1;
    if (!atomic_compare_exchange_strong_explicit(
            armed,
            &expected,
            0,
            memory_order_seq_cst,
            memory_order_seq_cst)) {
        return 0;
    }
    return nucleus_android_shared_ring_signal_fd(
        notification_fd,
        write_count);
}

int nucleus_android_shared_ring_producer_write(
    nucleus_android_shared_ring_producer *producer,
    const void *bytes,
    uint32_t byte_count) {
    struct nucleus_android_shared_ring_endpoint *endpoint =
        nucleus_android_producer_endpoint(producer);
    if (!endpoint || (!bytes && byte_count > 0)) {
        errno = EINVAL;
        return -1;
    }
    if (byte_count > endpoint->slot_size - sizeof(uint32_t)) {
        errno = EMSGSIZE;
        return -1;
    }
    if (atomic_load_explicit(
            &endpoint->header->closed,
            memory_order_acquire) != 0) {
        errno = EPIPE;
        return -1;
    }

    const uint64_t write_index = atomic_load_explicit(
        &endpoint->header->write_index,
        memory_order_relaxed);
    const uint64_t read_index = atomic_load_explicit(
        &endpoint->header->read_index,
        memory_order_acquire);
    if (write_index - read_index >= endpoint->slot_count) {
        atomic_fetch_add_explicit(
            &endpoint->header->write_backpressure_count,
            1,
            memory_order_relaxed);
        errno = EAGAIN;
        return -1;
    }

    uint8_t *slot = endpoint->slots +
        (write_index % endpoint->slot_count) * endpoint->slot_size;
    memcpy(slot, &byte_count, sizeof(byte_count));
    if (byte_count > 0) {
        memcpy(slot + sizeof(byte_count), bytes, byte_count);
    }
    atomic_store_explicit(
        &endpoint->header->write_index,
        write_index + 1,
        memory_order_seq_cst);

    const uint64_t occupancy = write_index + 1 - read_index;
    uint64_t maximum = atomic_load_explicit(
        &endpoint->header->maximum_occupancy,
        memory_order_relaxed);
    while (maximum < occupancy &&
           !atomic_compare_exchange_weak_explicit(
               &endpoint->header->maximum_occupancy,
               &maximum,
               occupancy,
               memory_order_relaxed,
               memory_order_relaxed)) {}

    return nucleus_android_shared_ring_signal_if_armed(
        &endpoint->header->data_wait_armed,
        endpoint->data_notification_fd,
        &endpoint->header->data_notification_write_count);
}

int nucleus_android_shared_ring_consumer_read(
    nucleus_android_shared_ring_consumer *consumer,
    void *bytes,
    uint32_t byte_capacity) {
    struct nucleus_android_shared_ring_endpoint *endpoint =
        nucleus_android_consumer_endpoint(consumer);
    if (!endpoint || (!bytes && byte_capacity > 0)) {
        errno = EINVAL;
        return -1;
    }

    const uint64_t read_index = atomic_load_explicit(
        &endpoint->header->read_index,
        memory_order_relaxed);
    const uint64_t write_index = atomic_load_explicit(
        &endpoint->header->write_index,
        memory_order_acquire);
    if (read_index == write_index) {
        atomic_fetch_add_explicit(
            &endpoint->header->read_empty_count,
            1,
            memory_order_relaxed);
        if (atomic_load_explicit(
                &endpoint->header->closed,
                memory_order_acquire) != 0) {
            errno = EPIPE;
            return -1;
        }
        errno = EAGAIN;
        return -1;
    }

    uint8_t *slot = endpoint->slots +
        (read_index % endpoint->slot_count) * endpoint->slot_size;
    uint32_t byte_count = 0;
    memcpy(&byte_count, slot, sizeof(byte_count));
    if (byte_count > endpoint->slot_size - sizeof(uint32_t)) {
        errno = EPROTO;
        return -1;
    }
    if (byte_count > byte_capacity) {
        errno = EMSGSIZE;
        return -1;
    }
    if (byte_count > 0) {
        memcpy(bytes, slot + sizeof(byte_count), byte_count);
    }
    atomic_store_explicit(
        &endpoint->header->read_index,
        read_index + 1,
        memory_order_seq_cst);

    if (nucleus_android_shared_ring_signal_if_armed(
            &endpoint->header->space_wait_armed,
            endpoint->space_notification_fd,
            &endpoint->header->space_notification_write_count) < 0) {
        return -1;
    }
    return (int)byte_count;
}

nucleus_android_shared_ring_wait_result
nucleus_android_shared_ring_producer_prepare_space_wait(
    nucleus_android_shared_ring_producer *producer) {
    struct nucleus_android_shared_ring_endpoint *endpoint =
        nucleus_android_producer_endpoint(producer);
    if (!endpoint) {
        errno = EINVAL;
        return NUCLEUS_ANDROID_SHARED_RING_WAIT_ERROR;
    }
    if (atomic_load_explicit(
            &endpoint->header->closed,
            memory_order_acquire) != 0) {
        return NUCLEUS_ANDROID_SHARED_RING_WAIT_CLOSED;
    }

    const uint64_t write_index = atomic_load_explicit(
        &endpoint->header->write_index,
        memory_order_relaxed);
    uint64_t read_index = atomic_load_explicit(
        &endpoint->header->read_index,
        memory_order_acquire);
    if (write_index - read_index < endpoint->slot_count) {
        return NUCLEUS_ANDROID_SHARED_RING_WAIT_READY;
    }

    atomic_store_explicit(
        &endpoint->header->space_wait_armed,
        1,
        memory_order_seq_cst);
    read_index = atomic_load_explicit(
        &endpoint->header->read_index,
        memory_order_seq_cst);
    if (write_index - read_index < endpoint->slot_count) {
        atomic_exchange_explicit(
            &endpoint->header->space_wait_armed,
            0,
            memory_order_seq_cst);
        return NUCLEUS_ANDROID_SHARED_RING_WAIT_READY;
    }
    if (atomic_load_explicit(
            &endpoint->header->closed,
            memory_order_seq_cst) != 0) {
        atomic_exchange_explicit(
            &endpoint->header->space_wait_armed,
            0,
            memory_order_seq_cst);
        return NUCLEUS_ANDROID_SHARED_RING_WAIT_CLOSED;
    }
    return NUCLEUS_ANDROID_SHARED_RING_WAIT_ARMED;
}

nucleus_android_shared_ring_wait_result
nucleus_android_shared_ring_consumer_prepare_data_wait(
    nucleus_android_shared_ring_consumer *consumer) {
    struct nucleus_android_shared_ring_endpoint *endpoint =
        nucleus_android_consumer_endpoint(consumer);
    if (!endpoint) {
        errno = EINVAL;
        return NUCLEUS_ANDROID_SHARED_RING_WAIT_ERROR;
    }

    const uint64_t read_index = atomic_load_explicit(
        &endpoint->header->read_index,
        memory_order_relaxed);
    uint64_t write_index = atomic_load_explicit(
        &endpoint->header->write_index,
        memory_order_acquire);
    if (read_index != write_index) {
        return NUCLEUS_ANDROID_SHARED_RING_WAIT_READY;
    }
    if (atomic_load_explicit(
            &endpoint->header->closed,
            memory_order_acquire) != 0) {
        return NUCLEUS_ANDROID_SHARED_RING_WAIT_CLOSED;
    }

    atomic_store_explicit(
        &endpoint->header->data_wait_armed,
        1,
        memory_order_seq_cst);
    write_index = atomic_load_explicit(
        &endpoint->header->write_index,
        memory_order_seq_cst);
    if (read_index != write_index) {
        atomic_exchange_explicit(
            &endpoint->header->data_wait_armed,
            0,
            memory_order_seq_cst);
        return NUCLEUS_ANDROID_SHARED_RING_WAIT_READY;
    }
    if (atomic_load_explicit(
            &endpoint->header->closed,
            memory_order_seq_cst) != 0) {
        atomic_exchange_explicit(
            &endpoint->header->data_wait_armed,
            0,
            memory_order_seq_cst);
        return NUCLEUS_ANDROID_SHARED_RING_WAIT_CLOSED;
    }
    return NUCLEUS_ANDROID_SHARED_RING_WAIT_ARMED;
}

static int nucleus_android_shared_ring_drain_fd(
    int notification_fd,
    _Atomic uint64_t *drain_count) {
    uint64_t value = 0;
    ssize_t result;
    do {
        result = read(notification_fd, &value, sizeof(value));
    } while (result < 0 && errno == EINTR);
    if (result == (ssize_t)sizeof(value)) {
        atomic_fetch_add_explicit(
            drain_count,
            1,
            memory_order_relaxed);
        return 0;
    }
    if (result < 0 && errno == EAGAIN) {
        return 0;
    }
    return -1;
}

int nucleus_android_shared_ring_producer_space_notification_fd(
    nucleus_android_shared_ring_producer *producer) {
    struct nucleus_android_shared_ring_endpoint *endpoint =
        nucleus_android_producer_endpoint(producer);
    if (!endpoint) {
        errno = EINVAL;
        return -1;
    }
    return endpoint->space_notification_fd;
}

int nucleus_android_shared_ring_producer_drain_space_notification(
    nucleus_android_shared_ring_producer *producer) {
    struct nucleus_android_shared_ring_endpoint *endpoint =
        nucleus_android_producer_endpoint(producer);
    if (!endpoint) {
        errno = EINVAL;
        return -1;
    }
    return nucleus_android_shared_ring_drain_fd(
        endpoint->space_notification_fd,
        &endpoint->header->space_notification_drain_count);
}

int nucleus_android_shared_ring_consumer_data_notification_fd(
    nucleus_android_shared_ring_consumer *consumer) {
    struct nucleus_android_shared_ring_endpoint *endpoint =
        nucleus_android_consumer_endpoint(consumer);
    if (!endpoint) {
        errno = EINVAL;
        return -1;
    }
    return endpoint->data_notification_fd;
}

int nucleus_android_shared_ring_consumer_drain_data_notification(
    nucleus_android_shared_ring_consumer *consumer) {
    struct nucleus_android_shared_ring_endpoint *endpoint =
        nucleus_android_consumer_endpoint(consumer);
    if (!endpoint) {
        errno = EINVAL;
        return -1;
    }
    return nucleus_android_shared_ring_drain_fd(
        endpoint->data_notification_fd,
        &endpoint->header->data_notification_drain_count);
}

static int nucleus_android_shared_ring_close_endpoint(
    struct nucleus_android_shared_ring_endpoint *endpoint) {
    if (!endpoint) {
        errno = EINVAL;
        return -1;
    }
    atomic_store_explicit(
        &endpoint->header->closed,
        1,
        memory_order_seq_cst);
    const int data_result =
        nucleus_android_shared_ring_signal_if_armed(
            &endpoint->header->data_wait_armed,
            endpoint->data_notification_fd,
            &endpoint->header->data_notification_write_count);
    const int space_result =
        nucleus_android_shared_ring_signal_if_armed(
            &endpoint->header->space_wait_armed,
            endpoint->space_notification_fd,
            &endpoint->header->space_notification_write_count);
    return data_result == 0 && space_result == 0 ? 0 : -1;
}

int nucleus_android_shared_ring_mapping_close(
    nucleus_android_shared_ring_mapping *mapping) {
    return nucleus_android_shared_ring_close_endpoint(
        nucleus_android_mapping_endpoint(mapping));
}

int nucleus_android_shared_ring_producer_close(
    nucleus_android_shared_ring_producer *producer) {
    return nucleus_android_shared_ring_close_endpoint(
        nucleus_android_producer_endpoint(producer));
}

int nucleus_android_shared_ring_consumer_close(
    nucleus_android_shared_ring_consumer *consumer) {
    return nucleus_android_shared_ring_close_endpoint(
        nucleus_android_consumer_endpoint(consumer));
}

static int nucleus_android_shared_ring_get_diagnostic_common(
    struct nucleus_android_shared_ring_endpoint *endpoint,
    nucleus_android_shared_ring_diagnostic *output) {
    if (!endpoint || !output) {
        errno = EINVAL;
        return -1;
    }
    *output = (nucleus_android_shared_ring_diagnostic) {
        .write_backpressure_count = atomic_load_explicit(
            &endpoint->header->write_backpressure_count,
            memory_order_relaxed),
        .read_empty_count = atomic_load_explicit(
            &endpoint->header->read_empty_count,
            memory_order_relaxed),
        .maximum_occupancy = atomic_load_explicit(
            &endpoint->header->maximum_occupancy,
            memory_order_relaxed),
        .data_notification_write_count = atomic_load_explicit(
            &endpoint->header->data_notification_write_count,
            memory_order_relaxed),
        .data_notification_drain_count = atomic_load_explicit(
            &endpoint->header->data_notification_drain_count,
            memory_order_relaxed),
        .space_notification_write_count = atomic_load_explicit(
            &endpoint->header->space_notification_write_count,
            memory_order_relaxed),
        .space_notification_drain_count = atomic_load_explicit(
            &endpoint->header->space_notification_drain_count,
            memory_order_relaxed),
        .closed = atomic_load_explicit(
            &endpoint->header->closed,
            memory_order_acquire) != 0,
    };
    return 0;
}

int nucleus_android_shared_ring_mapping_get_diagnostic(
    nucleus_android_shared_ring_mapping *mapping,
    nucleus_android_shared_ring_diagnostic *output) {
    return nucleus_android_shared_ring_get_diagnostic_common(
        nucleus_android_mapping_endpoint(mapping),
        output);
}

int nucleus_android_shared_ring_producer_get_diagnostic(
    nucleus_android_shared_ring_producer *producer,
    nucleus_android_shared_ring_diagnostic *output) {
    return nucleus_android_shared_ring_get_diagnostic_common(
        nucleus_android_producer_endpoint(producer),
        output);
}

int nucleus_android_shared_ring_consumer_get_diagnostic(
    nucleus_android_shared_ring_consumer *consumer,
    nucleus_android_shared_ring_diagnostic *output) {
    return nucleus_android_shared_ring_get_diagnostic_common(
        nucleus_android_consumer_endpoint(consumer),
        output);
}

uint32_t nucleus_android_shared_ring_producer_slot_count(
    nucleus_android_shared_ring_producer *producer) {
    struct nucleus_android_shared_ring_endpoint *endpoint =
        nucleus_android_producer_endpoint(producer);
    return endpoint ? endpoint->slot_count : 0;
}

uint32_t nucleus_android_shared_ring_producer_slot_size(
    nucleus_android_shared_ring_producer *producer) {
    struct nucleus_android_shared_ring_endpoint *endpoint =
        nucleus_android_producer_endpoint(producer);
    return endpoint ? endpoint->slot_size : 0;
}

uint32_t nucleus_android_shared_ring_consumer_slot_count(
    nucleus_android_shared_ring_consumer *consumer) {
    struct nucleus_android_shared_ring_endpoint *endpoint =
        nucleus_android_consumer_endpoint(consumer);
    return endpoint ? endpoint->slot_count : 0;
}

uint32_t nucleus_android_shared_ring_consumer_slot_size(
    nucleus_android_shared_ring_consumer *consumer) {
    struct nucleus_android_shared_ring_endpoint *endpoint =
        nucleus_android_consumer_endpoint(consumer);
    return endpoint ? endpoint->slot_size : 0;
}
