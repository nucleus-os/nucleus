#ifndef NUCLEUS_ANDROID_COMPOSER_PROTOCOL_H
#define NUCLEUS_ANDROID_COMPOSER_PROTOCOL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

static const uint32_t NUCLEUS_COMPOSER_MAX_MESSAGE_BYTES = 256;
#define NUCLEUS_COMPOSER_OUTPUT_NAME_BYTES 128

enum nucleus_composer_operation {
    NUCLEUS_COMPOSER_SUBSCRIBE_TOPOLOGY = 1,
    NUCLEUS_COMPOSER_TOPOLOGY_SNAPSHOT = 2,
    NUCLEUS_COMPOSER_OUTPUT_CONNECTED = 3,
    NUCLEUS_COMPOSER_OUTPUT_MODE_CHANGED = 4,
    NUCLEUS_COMPOSER_OUTPUT_DISCONNECTED = 5,
};

enum nucleus_composer_status {
    NUCLEUS_COMPOSER_STATUS_OK = 0,
    NUCLEUS_COMPOSER_STATUS_DUPLICATE_SUBSCRIBER = 1,
    NUCLEUS_COMPOSER_STATUS_STALE_GENERATION = 2,
};

struct nucleus_composer_message_header {
    uint32_t operation;
    uint32_t byte_count;
    uint32_t fd_count;
};

struct nucleus_composer_topology_subscribe_request {
    uint32_t operation;
    uint32_t byte_count;
    uint32_t fd_count;
    uint64_t last_generation;
};

struct nucleus_composer_topology_event {
    uint32_t operation;
    uint32_t byte_count;
    uint32_t fd_count;
    uint64_t generation;
    uint64_t display_id;
    uint64_t refresh_period_ns;
    int32_t mode_width;
    int32_t mode_height;
    int32_t refresh_millihertz;
    uint32_t status;
    uint32_t connected;
    char output_name[NUCLEUS_COMPOSER_OUTPUT_NAME_BYTES];
};

#ifdef __cplusplus
}
#endif

#endif
