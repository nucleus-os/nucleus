#define _GNU_SOURCE
#include "NucleusAndroidSharedRingC.h"

#include <errno.h>
#include <fcntl.h>
#include <linux/memfd.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define NUCLEUS_ANDROID_RING_MAGIC UINT64_C(0x4e55434c52494e47)
#define NUCLEUS_ANDROID_RING_VERSION 2u
#define NUCLEUS_ANDROID_RING_HEADER_SIZE 128u
#define NUCLEUS_ANDROID_RING_MIN_SLOTS 2u
#define NUCLEUS_ANDROID_RING_MAX_SLOTS 4096u
#define NUCLEUS_ANDROID_RING_MIN_SLOT_SIZE 64u
#define NUCLEUS_ANDROID_RING_MAX_SLOT_SIZE (16u * 1024u * 1024u)

struct nucleus_android_shared_ring_header {
    uint64_t magic;
    uint32_t version;
    uint32_t slot_count;
    uint32_t slot_size;
    _Atomic uint32_t closed;
    _Atomic uint64_t write_index;
    _Atomic uint64_t read_index;
    _Atomic uint64_t write_backpressure_count;
    _Atomic uint64_t read_empty_count;
    _Atomic uint64_t maximum_occupancy;
    uint8_t padding[NUCLEUS_ANDROID_RING_HEADER_SIZE - 64u];
};

_Static_assert(
    sizeof(struct nucleus_android_shared_ring_header) == NUCLEUS_ANDROID_RING_HEADER_SIZE,
    "shared ring header size changed");

struct nucleus_android_shared_ring {
    int memory_fd;
    int data_notification_fd;
    int space_notification_fd;
    size_t mapping_size;
    struct nucleus_android_shared_ring_header *header;
    uint8_t *slots;
};

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
    size_t slots_size = (size_t)slot_count * slot_size;
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

static nucleus_android_shared_ring *nucleus_android_ring_map(
    int memory_fd,
    int data_notification_fd,
    int space_notification_fd,
    size_t mapping_size) {
    void *mapping = mmap(
        NULL,
        mapping_size,
        PROT_READ | PROT_WRITE,
        MAP_SHARED,
        memory_fd,
        0);
    if (mapping == MAP_FAILED) return NULL;
    nucleus_android_shared_ring *ring = calloc(1, sizeof(*ring));
    if (!ring) {
        int saved = errno;
        munmap(mapping, mapping_size);
        errno = saved;
        return NULL;
    }
    ring->memory_fd = memory_fd;
    ring->data_notification_fd = data_notification_fd;
    ring->space_notification_fd = space_notification_fd;
    ring->mapping_size = mapping_size;
    ring->header = mapping;
    ring->slots = (uint8_t *)mapping + NUCLEUS_ANDROID_RING_HEADER_SIZE;
    return ring;
}

nucleus_android_shared_ring *nucleus_android_shared_ring_create(
    uint32_t slot_count,
    uint32_t slot_size) {
    size_t mapping_size = 0;
    if (!nucleus_android_ring_layout(slot_count, slot_size, &mapping_size)) return NULL;
    int memory_fd = memfd_create(
        "nucleus-gfxstream-ring",
        MFD_CLOEXEC | MFD_ALLOW_SEALING);
    if (memory_fd < 0) return NULL;
    if (ftruncate(memory_fd, (off_t)mapping_size) < 0) {
        int saved = errno;
        close(memory_fd);
        errno = saved;
        return NULL;
    }
    int data_notification_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (data_notification_fd < 0) {
        int saved = errno;
        close(memory_fd);
        errno = saved;
        return NULL;
    }
    int space_notification_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (space_notification_fd < 0) {
        int saved = errno;
        close(data_notification_fd);
        close(memory_fd);
        errno = saved;
        return NULL;
    }
    nucleus_android_shared_ring *ring = nucleus_android_ring_map(
        memory_fd,
        data_notification_fd,
        space_notification_fd,
        mapping_size);
    if (!ring) {
        int saved = errno;
        close(space_notification_fd);
        close(data_notification_fd);
        close(memory_fd);
        errno = saved;
        return NULL;
    }
    memset(ring->header, 0, sizeof(*ring->header));
    ring->header->magic = NUCLEUS_ANDROID_RING_MAGIC;
    ring->header->version = NUCLEUS_ANDROID_RING_VERSION;
    ring->header->slot_count = slot_count;
    ring->header->slot_size = slot_size;
    atomic_init(&ring->header->write_index, 0);
    atomic_init(&ring->header->read_index, 0);
    atomic_init(&ring->header->closed, 0);
    atomic_init(&ring->header->write_backpressure_count, 0);
    atomic_init(&ring->header->read_empty_count, 0);
    atomic_init(&ring->header->maximum_occupancy, 0);
    if (!atomic_is_lock_free(&ring->header->write_index) ||
        !atomic_is_lock_free(&ring->header->read_index) ||
        !atomic_is_lock_free(&ring->header->closed) ||
        !atomic_is_lock_free(&ring->header->write_backpressure_count) ||
        !atomic_is_lock_free(&ring->header->read_empty_count) ||
        !atomic_is_lock_free(&ring->header->maximum_occupancy)) {
        nucleus_android_shared_ring_destroy(ring);
        errno = ENOTSUP;
        return NULL;
    }
    if (fcntl(
            memory_fd,
            F_ADD_SEALS,
            F_SEAL_GROW | F_SEAL_SHRINK | F_SEAL_SEAL) < 0) {
        nucleus_android_shared_ring_destroy(ring);
        return NULL;
    }
    return ring;
}

nucleus_android_shared_ring *nucleus_android_shared_ring_attach(
    int memory_fd,
    int data_notification_fd,
    int space_notification_fd) {
    if (memory_fd < 0 || data_notification_fd < 0 ||
        space_notification_fd < 0) {
        if (space_notification_fd >= 0) close(space_notification_fd);
        if (data_notification_fd >= 0) close(data_notification_fd);
        if (memory_fd >= 0) close(memory_fd);
        errno = EINVAL;
        return NULL;
    }
    struct stat status;
    if (fstat(memory_fd, &status) < 0) {
        int saved = errno;
        close(space_notification_fd);
        close(data_notification_fd);
        close(memory_fd);
        errno = saved;
        return NULL;
    }
    if (status.st_size < NUCLEUS_ANDROID_RING_HEADER_SIZE) {
        close(space_notification_fd);
        close(data_notification_fd);
        close(memory_fd);
        errno = EPROTO;
        return NULL;
    }
    size_t mapping_size = (size_t)status.st_size;
    nucleus_android_shared_ring *ring = nucleus_android_ring_map(
        memory_fd,
        data_notification_fd,
        space_notification_fd,
        mapping_size);
    if (!ring) {
        int saved = errno;
        close(space_notification_fd);
        close(data_notification_fd);
        close(memory_fd);
        errno = saved;
        return NULL;
    }
    size_t expected_size = 0;
    bool valid = ring->header->magic == NUCLEUS_ANDROID_RING_MAGIC &&
        ring->header->version == NUCLEUS_ANDROID_RING_VERSION &&
        nucleus_android_ring_layout(
            ring->header->slot_count,
            ring->header->slot_size,
            &expected_size) &&
        expected_size == mapping_size &&
        atomic_is_lock_free(&ring->header->write_index) &&
        atomic_is_lock_free(&ring->header->read_index) &&
        atomic_is_lock_free(&ring->header->closed) &&
        atomic_is_lock_free(&ring->header->write_backpressure_count) &&
        atomic_is_lock_free(&ring->header->read_empty_count) &&
        atomic_is_lock_free(&ring->header->maximum_occupancy);
    if (!valid) {
        nucleus_android_shared_ring_destroy(ring);
        errno = EPROTO;
        return NULL;
    }
    return ring;
}

void nucleus_android_shared_ring_destroy(nucleus_android_shared_ring *ring) {
    if (!ring) return;
    if (ring->header && ring->mapping_size > 0) {
        munmap(ring->header, ring->mapping_size);
    }
    if (ring->space_notification_fd >= 0) close(ring->space_notification_fd);
    if (ring->data_notification_fd >= 0) close(ring->data_notification_fd);
    if (ring->memory_fd >= 0) close(ring->memory_fd);
    free(ring);
}

int nucleus_android_shared_ring_export_memory_fd(nucleus_android_shared_ring *ring) {
    if (!ring) {
        errno = EINVAL;
        return -1;
    }
    return nucleus_android_dup_cloexec(ring->memory_fd);
}

int nucleus_android_shared_ring_export_data_notification_fd(
    nucleus_android_shared_ring *ring) {
    if (!ring) {
        errno = EINVAL;
        return -1;
    }
    return nucleus_android_dup_cloexec(ring->data_notification_fd);
}

int nucleus_android_shared_ring_export_space_notification_fd(
    nucleus_android_shared_ring *ring) {
    if (!ring) {
        errno = EINVAL;
        return -1;
    }
    return nucleus_android_dup_cloexec(ring->space_notification_fd);
}

int nucleus_android_shared_ring_data_notification_fd(
    nucleus_android_shared_ring *ring) {
    if (!ring) {
        errno = EINVAL;
        return -1;
    }
    return ring->data_notification_fd;
}

int nucleus_android_shared_ring_space_notification_fd(
    nucleus_android_shared_ring *ring) {
    if (!ring) {
        errno = EINVAL;
        return -1;
    }
    return ring->space_notification_fd;
}

int nucleus_android_shared_ring_write(
    nucleus_android_shared_ring *ring,
    const void *bytes,
    uint32_t byte_count) {
    if (!ring || (!bytes && byte_count > 0) ||
        byte_count > ring->header->slot_size - sizeof(uint32_t)) {
        errno = EMSGSIZE;
        return -1;
    }
    if (atomic_load_explicit(
            &ring->header->closed,
            memory_order_acquire) != 0) {
        errno = EPIPE;
        return -1;
    }
    uint64_t write_index = atomic_load_explicit(
        &ring->header->write_index, memory_order_relaxed);
    uint64_t read_index = atomic_load_explicit(
        &ring->header->read_index, memory_order_acquire);
    if (write_index - read_index >= ring->header->slot_count) {
        atomic_fetch_add_explicit(
            &ring->header->write_backpressure_count,
            1,
            memory_order_relaxed);
        errno = EAGAIN;
        return -1;
    }
    uint8_t *slot = ring->slots +
        (write_index % ring->header->slot_count) * ring->header->slot_size;
    memcpy(slot, &byte_count, sizeof(byte_count));
    if (byte_count > 0) memcpy(slot + sizeof(byte_count), bytes, byte_count);
    atomic_store_explicit(
        &ring->header->write_index, write_index + 1, memory_order_release);
    const uint64_t occupancy = write_index + 1 - read_index;
    uint64_t maximum = atomic_load_explicit(
        &ring->header->maximum_occupancy,
        memory_order_relaxed);
    while (maximum < occupancy &&
           !atomic_compare_exchange_weak_explicit(
               &ring->header->maximum_occupancy,
               &maximum,
               occupancy,
               memory_order_relaxed,
               memory_order_relaxed)) {}
    uint64_t signal = 1;
    ssize_t result;
    do {
        result = write(ring->data_notification_fd, &signal, sizeof(signal));
    } while (result < 0 && errno == EINTR);
    if (result < 0 && errno != EAGAIN) return -1;
    return 0;
}

int nucleus_android_shared_ring_read(
    nucleus_android_shared_ring *ring,
    void *bytes,
    uint32_t byte_capacity) {
    if (!ring || (!bytes && byte_capacity > 0)) {
        errno = EINVAL;
        return -1;
    }
    uint64_t read_index = atomic_load_explicit(
        &ring->header->read_index, memory_order_relaxed);
    uint64_t write_index = atomic_load_explicit(
        &ring->header->write_index, memory_order_acquire);
    if (read_index == write_index) {
        atomic_fetch_add_explicit(
            &ring->header->read_empty_count,
            1,
            memory_order_relaxed);
        if (atomic_load_explicit(
                &ring->header->closed,
                memory_order_acquire) != 0) {
            errno = EPIPE;
            return -1;
        }
        errno = EAGAIN;
        return -1;
    }
    uint8_t *slot = ring->slots +
        (read_index % ring->header->slot_count) * ring->header->slot_size;
    uint32_t byte_count = 0;
    memcpy(&byte_count, slot, sizeof(byte_count));
    if (byte_count > ring->header->slot_size - sizeof(uint32_t)) {
        errno = EPROTO;
        return -1;
    }
    if (byte_count > byte_capacity) {
        errno = EMSGSIZE;
        return -1;
    }
    if (byte_count > 0) memcpy(bytes, slot + sizeof(byte_count), byte_count);
    atomic_store_explicit(
        &ring->header->read_index, read_index + 1, memory_order_release);
    uint64_t signal = 1;
    ssize_t result;
    do {
        result = write(ring->space_notification_fd, &signal, sizeof(signal));
    } while (result < 0 && errno == EINTR);
    if (result < 0 && errno != EAGAIN) return -1;
    return (int)byte_count;
}

static int nucleus_android_shared_ring_drain_fd(int notification_fd) {
    uint64_t value = 0;
    ssize_t result;
    do {
        result = read(notification_fd, &value, sizeof(value));
    } while (result < 0 && errno == EINTR);
    if (result < 0 && errno == EAGAIN) return 0;
    return result == (ssize_t)sizeof(value) ? 0 : -1;
}

static int nucleus_android_shared_ring_signal_fd(int notification_fd) {
    uint64_t value = 1;
    ssize_t result;
    do {
        result = write(notification_fd, &value, sizeof(value));
    } while (result < 0 && errno == EINTR);
    if (result < 0 && errno != EAGAIN) return -1;
    return 0;
}

int nucleus_android_shared_ring_drain_data_notification(
    nucleus_android_shared_ring *ring) {
    if (!ring) {
        errno = EINVAL;
        return -1;
    }
    return nucleus_android_shared_ring_drain_fd(ring->data_notification_fd);
}

int nucleus_android_shared_ring_drain_space_notification(
    nucleus_android_shared_ring *ring) {
    if (!ring) {
        errno = EINVAL;
        return -1;
    }
    return nucleus_android_shared_ring_drain_fd(ring->space_notification_fd);
}

int nucleus_android_shared_ring_close(nucleus_android_shared_ring *ring) {
    if (!ring) {
        errno = EINVAL;
        return -1;
    }
    atomic_store_explicit(
        &ring->header->closed,
        1,
        memory_order_release);
    const int data_result =
        nucleus_android_shared_ring_signal_fd(
            ring->data_notification_fd);
    const int space_result =
        nucleus_android_shared_ring_signal_fd(
            ring->space_notification_fd);
    return data_result == 0 && space_result == 0 ? 0 : -1;
}

int nucleus_android_shared_ring_get_diagnostic(
    nucleus_android_shared_ring *ring,
    nucleus_android_shared_ring_diagnostic *output) {
    if (!ring || !output) {
        errno = EINVAL;
        return -1;
    }
    *output = (nucleus_android_shared_ring_diagnostic) {
        .write_backpressure_count =
            atomic_load_explicit(
                &ring->header->write_backpressure_count,
                memory_order_relaxed),
        .read_empty_count =
            atomic_load_explicit(
                &ring->header->read_empty_count,
                memory_order_relaxed),
        .maximum_occupancy =
            atomic_load_explicit(
                &ring->header->maximum_occupancy,
                memory_order_relaxed),
        .closed =
            atomic_load_explicit(
                &ring->header->closed,
                memory_order_acquire) != 0,
    };
    return 0;
}

uint32_t nucleus_android_shared_ring_slot_count(nucleus_android_shared_ring *ring) {
    return ring ? ring->header->slot_count : 0;
}

uint32_t nucleus_android_shared_ring_slot_size(nucleus_android_shared_ring *ring) {
    return ring ? ring->header->slot_size : 0;
}
