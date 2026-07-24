#define _GNU_SOURCE

#include "NucleusAndroidSharedRingC.h"

#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define STRESS_SLOT_COUNT 2u
#define STRESS_BATCH_SIZE 32u
#define STRESS_WAIT_TIMEOUT_MS 10000

static nucleus_android_shared_ring_descriptors invalid_descriptors(void) {
    return (nucleus_android_shared_ring_descriptors) {
        .memory_fd = -1,
        .data_notification_fd = -1,
        .space_notification_fd = -1,
    };
}

static int wait_for_notification(int descriptor) {
    struct pollfd event = {
        .fd = descriptor,
        .events = POLLIN,
        .revents = 0,
    };
    int result;
    do {
        result = poll(&event, 1, STRESS_WAIT_TIMEOUT_MS);
    } while (result < 0 && errno == EINTR);
    if (result != 1 ||
        (event.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0 ||
        (event.revents & POLLIN) == 0) {
        errno = result == 0 ? ETIMEDOUT : EIO;
        return -1;
    }
    return 0;
}

static int write_packet(
    nucleus_android_shared_ring_producer *producer,
    const void *bytes,
    uint32_t byte_count) {
    for (;;) {
        if (nucleus_android_shared_ring_producer_write(
                producer,
                bytes,
                byte_count) == 0) {
            return 0;
        }
        if (errno != EAGAIN) {
            return -1;
        }
        const nucleus_android_shared_ring_wait_result preparation =
            nucleus_android_shared_ring_producer_prepare_space_wait(
                producer);
        if (preparation == NUCLEUS_ANDROID_SHARED_RING_WAIT_READY) {
            continue;
        }
        if (preparation == NUCLEUS_ANDROID_SHARED_RING_WAIT_CLOSED) {
            errno = EPIPE;
            return -1;
        }
        if (preparation == NUCLEUS_ANDROID_SHARED_RING_WAIT_ERROR ||
            wait_for_notification(
                nucleus_android_shared_ring_producer_space_notification_fd(
                    producer)) < 0 ||
            nucleus_android_shared_ring_producer_drain_space_notification(
                producer) < 0) {
            return -1;
        }
    }
}

static int read_packet(
    nucleus_android_shared_ring_consumer *consumer,
    void *bytes,
    uint32_t byte_capacity) {
    for (;;) {
        const int result =
            nucleus_android_shared_ring_consumer_read(
                consumer,
                bytes,
                byte_capacity);
        if (result >= 0) {
            return result;
        }
        if (errno != EAGAIN) {
            return -1;
        }
        const nucleus_android_shared_ring_wait_result preparation =
            nucleus_android_shared_ring_consumer_prepare_data_wait(
                consumer);
        if (preparation == NUCLEUS_ANDROID_SHARED_RING_WAIT_READY) {
            continue;
        }
        if (preparation == NUCLEUS_ANDROID_SHARED_RING_WAIT_CLOSED) {
            errno = EPIPE;
            return -1;
        }
        if (preparation == NUCLEUS_ANDROID_SHARED_RING_WAIT_ERROR ||
            wait_for_notification(
                nucleus_android_shared_ring_consumer_data_notification_fd(
                    consumer)) < 0 ||
            nucleus_android_shared_ring_consumer_drain_data_notification(
                consumer) < 0) {
            return -1;
        }
    }
}

static void delay_batch_consumer(void) {
    const struct timespec duration = {
        .tv_sec = 0,
        .tv_nsec = 250000,
    };
    struct timespec remaining = duration;
    while (nanosleep(&remaining, &remaining) < 0 && errno == EINTR) {}
}

static int run_child(
    nucleus_android_shared_ring_mapping *command_mapping,
    nucleus_android_shared_ring_mapping *response_mapping,
    nucleus_android_shared_ring_descriptors command_consumer_descriptors,
    nucleus_android_shared_ring_descriptors response_producer_descriptors,
    uint32_t payload_size,
    uint32_t iterations) {
    nucleus_android_shared_ring_consumer *command_consumer =
        nucleus_android_shared_ring_consumer_attach(
            command_consumer_descriptors);
    nucleus_android_shared_ring_producer *response_producer =
        nucleus_android_shared_ring_producer_attach(
            response_producer_descriptors);
    nucleus_android_shared_ring_mapping_destroy(command_mapping);
    nucleus_android_shared_ring_mapping_destroy(response_mapping);
    if (!command_consumer || !response_producer) {
        nucleus_android_shared_ring_consumer_destroy(command_consumer);
        nucleus_android_shared_ring_producer_destroy(response_producer);
        return 20;
    }

    void *packet = malloc(payload_size);
    if (!packet) {
        nucleus_android_shared_ring_consumer_destroy(command_consumer);
        nucleus_android_shared_ring_producer_destroy(response_producer);
        return 21;
    }
    int status = 0;
    for (uint32_t sequence = 0; sequence < iterations; ++sequence) {
        if (sequence % STRESS_BATCH_SIZE == 0) {
            delay_batch_consumer();
        }
        const int count = read_packet(
            command_consumer,
            packet,
            payload_size);
        uint64_t received_sequence = UINT64_MAX;
        if (count >= (int)sizeof(received_sequence)) {
            memcpy(
                &received_sequence,
                packet,
                sizeof(received_sequence));
        }
        if (count != (int)payload_size ||
            received_sequence != sequence) {
            status = 22;
            break;
        }
        if ((sequence + 1) % STRESS_BATCH_SIZE == 0 ||
            sequence + 1 == iterations) {
            const uint64_t acknowledgement = sequence;
            if (write_packet(
                    response_producer,
                    &acknowledgement,
                    sizeof(acknowledgement)) < 0) {
                status = 23;
                break;
            }
        }
    }
    free(packet);
    nucleus_android_shared_ring_consumer_destroy(command_consumer);
    nucleus_android_shared_ring_producer_destroy(response_producer);
    return status;
}

static uint64_t elapsed_nanoseconds(
    const struct timespec *start,
    const struct timespec *end) {
    const uint64_t seconds =
        (uint64_t)(end->tv_sec - start->tv_sec);
    if (end->tv_nsec >= start->tv_nsec) {
        return seconds * UINT64_C(1000000000) +
            (uint64_t)(end->tv_nsec - start->tv_nsec);
    }
    return (seconds - 1) * UINT64_C(1000000000) +
        UINT64_C(1000000000) +
        (uint64_t)end->tv_nsec -
        (uint64_t)start->tv_nsec;
}

static int run_scenario(
    const char *label,
    uint32_t slot_size,
    uint32_t payload_size,
    uint32_t iterations) {
    nucleus_android_shared_ring_mapping *command_mapping =
        nucleus_android_shared_ring_mapping_create(
            STRESS_SLOT_COUNT,
            slot_size);
    nucleus_android_shared_ring_mapping *response_mapping =
        nucleus_android_shared_ring_mapping_create(
            STRESS_SLOT_COUNT,
            slot_size);
    if (!command_mapping || !response_mapping) {
        nucleus_android_shared_ring_mapping_destroy(command_mapping);
        nucleus_android_shared_ring_mapping_destroy(response_mapping);
        return 1;
    }

    nucleus_android_shared_ring_descriptors command_producer =
        invalid_descriptors();
    nucleus_android_shared_ring_descriptors command_consumer =
        invalid_descriptors();
    nucleus_android_shared_ring_descriptors response_producer =
        invalid_descriptors();
    nucleus_android_shared_ring_descriptors response_consumer =
        invalid_descriptors();
    if (nucleus_android_shared_ring_mapping_export_descriptors(
            command_mapping,
            &command_producer) < 0 ||
        nucleus_android_shared_ring_mapping_export_descriptors(
            command_mapping,
            &command_consumer) < 0 ||
        nucleus_android_shared_ring_mapping_export_descriptors(
            response_mapping,
            &response_producer) < 0 ||
        nucleus_android_shared_ring_mapping_export_descriptors(
            response_mapping,
            &response_consumer) < 0) {
        nucleus_android_shared_ring_descriptors_close(command_producer);
        nucleus_android_shared_ring_descriptors_close(command_consumer);
        nucleus_android_shared_ring_descriptors_close(response_producer);
        nucleus_android_shared_ring_descriptors_close(response_consumer);
        nucleus_android_shared_ring_mapping_destroy(command_mapping);
        nucleus_android_shared_ring_mapping_destroy(response_mapping);
        return 2;
    }

    const pid_t child = fork();
    if (child < 0) {
        nucleus_android_shared_ring_descriptors_close(command_producer);
        nucleus_android_shared_ring_descriptors_close(command_consumer);
        nucleus_android_shared_ring_descriptors_close(response_producer);
        nucleus_android_shared_ring_descriptors_close(response_consumer);
        nucleus_android_shared_ring_mapping_destroy(command_mapping);
        nucleus_android_shared_ring_mapping_destroy(response_mapping);
        return 3;
    }
    if (child == 0) {
        nucleus_android_shared_ring_descriptors_close(command_producer);
        nucleus_android_shared_ring_descriptors_close(response_consumer);
        const int status = run_child(
            command_mapping,
            response_mapping,
            command_consumer,
            response_producer,
            payload_size,
            iterations);
        _exit(status);
    }

    nucleus_android_shared_ring_descriptors_close(command_consumer);
    nucleus_android_shared_ring_descriptors_close(response_producer);
    nucleus_android_shared_ring_producer *producer =
        nucleus_android_shared_ring_producer_attach(command_producer);
    nucleus_android_shared_ring_consumer *consumer =
        nucleus_android_shared_ring_consumer_attach(response_consumer);
    if (!producer || !consumer) {
        nucleus_android_shared_ring_producer_destroy(producer);
        nucleus_android_shared_ring_consumer_destroy(consumer);
        kill(child, SIGKILL);
        waitpid(child, NULL, 0);
        nucleus_android_shared_ring_mapping_destroy(command_mapping);
        nucleus_android_shared_ring_mapping_destroy(response_mapping);
        return 4;
    }

    void *packet = calloc(1, payload_size);
    if (!packet) {
        kill(child, SIGKILL);
        waitpid(child, NULL, 0);
        nucleus_android_shared_ring_producer_destroy(producer);
        nucleus_android_shared_ring_consumer_destroy(consumer);
        nucleus_android_shared_ring_mapping_destroy(command_mapping);
        nucleus_android_shared_ring_mapping_destroy(response_mapping);
        return 5;
    }

    struct timespec start;
    struct timespec end;
    clock_gettime(CLOCK_MONOTONIC, &start);
    int status = 0;
    for (uint32_t sequence = 0; sequence < iterations; ++sequence) {
        const uint64_t wire_sequence = sequence;
        memcpy(packet, &wire_sequence, sizeof(wire_sequence));
        if (write_packet(
                producer,
                packet,
                payload_size) < 0) {
            status = 6;
            break;
        }
        if ((sequence + 1) % STRESS_BATCH_SIZE == 0 ||
            sequence + 1 == iterations) {
            uint64_t acknowledgement = UINT64_MAX;
            const int count = read_packet(
                consumer,
                &acknowledgement,
                sizeof(acknowledgement));
            if (count != (int)sizeof(acknowledgement) ||
                acknowledgement != sequence) {
                status = 7;
                break;
            }
        }
    }
    clock_gettime(CLOCK_MONOTONIC, &end);
    free(packet);

    int child_status = 0;
    pid_t waited;
    do {
        waited = waitpid(child, &child_status, 0);
    } while (waited < 0 && errno == EINTR);
    if (status == 0 &&
        (waited != child ||
         !WIFEXITED(child_status) ||
         WEXITSTATUS(child_status) != 0)) {
        status = 8;
    }

    nucleus_android_shared_ring_diagnostic command_diagnostic = {0};
    nucleus_android_shared_ring_diagnostic response_diagnostic = {0};
    if (status == 0 &&
        (nucleus_android_shared_ring_mapping_get_diagnostic(
             command_mapping,
             &command_diagnostic) < 0 ||
         nucleus_android_shared_ring_mapping_get_diagnostic(
             response_mapping,
             &response_diagnostic) < 0 ||
         command_diagnostic.write_backpressure_count == 0 ||
         command_diagnostic.maximum_occupancy != STRESS_SLOT_COUNT ||
         command_diagnostic.space_notification_write_count == 0)) {
        status = 9;
    }

    const uint64_t elapsed = elapsed_nanoseconds(&start, &end);
    const double packets_per_second =
        elapsed == 0
        ? 0.0
        : (double)iterations * 1000000000.0 / (double)elapsed;
    printf(
        "{\"scenario\":\"%s\",\"slotSize\":%u,\"payloadSize\":%u,"
        "\"iterations\":%u,\"elapsedNanoseconds\":%llu,"
        "\"packetsPerSecond\":%.2f,\"writeBackpressure\":%llu,"
        "\"readEmpty\":%llu,\"maximumOccupancy\":%llu,"
        "\"dataNotificationWrites\":%llu,\"dataNotificationDrains\":%llu,"
        "\"spaceNotificationWrites\":%llu,\"spaceNotificationDrains\":%llu,"
        "\"responseDataNotificationWrites\":%llu,"
        "\"responseDataNotificationDrains\":%llu}\n",
        label,
        slot_size,
        payload_size,
        iterations,
        (unsigned long long)elapsed,
        packets_per_second,
        (unsigned long long)
            command_diagnostic.write_backpressure_count,
        (unsigned long long)command_diagnostic.read_empty_count,
        (unsigned long long)command_diagnostic.maximum_occupancy,
        (unsigned long long)
            command_diagnostic.data_notification_write_count,
        (unsigned long long)
            command_diagnostic.data_notification_drain_count,
        (unsigned long long)
            command_diagnostic.space_notification_write_count,
        (unsigned long long)
            command_diagnostic.space_notification_drain_count,
        (unsigned long long)
            response_diagnostic.data_notification_write_count,
        (unsigned long long)
            response_diagnostic.data_notification_drain_count);
    fflush(stdout);

    nucleus_android_shared_ring_producer_destroy(producer);
    nucleus_android_shared_ring_consumer_destroy(consumer);
    nucleus_android_shared_ring_mapping_destroy(command_mapping);
    nucleus_android_shared_ring_mapping_destroy(response_mapping);
    return status;
}

int main(void) {
    const int small_result = run_scenario(
        "small-message",
        64,
        sizeof(uint64_t),
        4096);
    if (small_result != 0) {
        fprintf(
            stderr,
            "small-message shared-ring stress failed: %d\n",
            small_result);
        return small_result;
    }
    const int default_result = run_scenario(
        "default-slot",
        64 * 1024,
        4096,
        1024);
    if (default_result != 0) {
        fprintf(
            stderr,
            "default-slot shared-ring stress failed: %d\n",
            default_result);
        return 40 + default_result;
    }
    return 0;
}
