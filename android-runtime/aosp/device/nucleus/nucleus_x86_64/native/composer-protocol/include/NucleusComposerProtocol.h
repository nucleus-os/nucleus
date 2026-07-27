#ifndef NUCLEUS_ANDROID_COMPOSER_PROTOCOL_H
#define NUCLEUS_ANDROID_COMPOSER_PROTOCOL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

static const uint32_t NUCLEUS_COMPOSER_PROTOCOL_MAGIC = UINT32_C(0x4e434f4d);
static const uint16_t NUCLEUS_COMPOSER_PROTOCOL_VERSION = UINT16_C(2);
static const uint32_t NUCLEUS_COMPOSER_MAX_MESSAGE_BYTES = 256;
static const uint32_t NUCLEUS_COMPOSER_MAX_FDS = 3;
#define NUCLEUS_COMPOSER_OUTPUT_NAME_BYTES 128

enum nucleus_composer_operation {
    NUCLEUS_COMPOSER_PRESENT = 1,
    NUCLEUS_COMPOSER_SUBSCRIBE_TOPOLOGY = 2,
    NUCLEUS_COMPOSER_TOPOLOGY_SNAPSHOT = 3,
    NUCLEUS_COMPOSER_OUTPUT_CONNECTED = 4,
    NUCLEUS_COMPOSER_OUTPUT_MODE_CHANGED = 5,
    NUCLEUS_COMPOSER_OUTPUT_DISCONNECTED = 6,
    NUCLEUS_COMPOSER_OUTPUT_PRESENTED = 7,
};

enum nucleus_composer_status {
    NUCLEUS_COMPOSER_STATUS_OK = 0,
    NUCLEUS_COMPOSER_STATUS_INVALID_REQUEST = 1,
    NUCLEUS_COMPOSER_STATUS_UNSUPPORTED_BUFFER = 2,
    NUCLEUS_COMPOSER_STATUS_PRESENTATION_FAILED = 3,
    NUCLEUS_COMPOSER_STATUS_DUPLICATE_SUBSCRIBER = 4,
    NUCLEUS_COMPOSER_STATUS_STALE_GENERATION = 5,
};

struct nucleus_composer_message_header {
    uint32_t magic;
    uint16_t version;
    uint16_t operation;
    uint32_t byte_count;
    uint32_t fd_count;
};

struct nucleus_composer_topology_subscribe_request {
    uint32_t magic;
    uint16_t version;
    uint16_t operation;
    uint32_t byte_count;
    uint32_t fd_count;
    uint64_t last_generation;
};

struct nucleus_composer_topology_event {
    uint32_t magic;
    uint16_t version;
    uint16_t operation;
    uint32_t byte_count;
    uint32_t fd_count;
    uint64_t generation;
    uint64_t display_id;
    uint64_t refresh_period_ns;
    uint64_t presentation_timestamp_ns;
    uint64_t presentation_sequence;
    int32_t mode_width;
    int32_t mode_height;
    int32_t refresh_millihertz;
    uint32_t status;
    uint32_t connected;
    char output_name[NUCLEUS_COMPOSER_OUTPUT_NAME_BYTES];
};

struct nucleus_composer_present_request {
    uint32_t magic;
    uint16_t version;
    uint16_t operation;
    uint32_t byte_count;
    uint32_t fd_count;
    uint64_t request_id;
    uint64_t display_id;
    uint64_t allocation_id;
    uint64_t frame_number;
    uint64_t drm_modifier;
    uint64_t allocation_size;
    uint32_t width;
    uint32_t height;
    uint32_t drm_format;
    uint32_t plane_offset;
    uint32_t plane_stride;
    int32_t damage_left;
    int32_t damage_top;
    int32_t damage_right;
    int32_t damage_bottom;
    uint32_t has_acquire_fence;
    uint32_t reserved;
};

struct nucleus_composer_present_reply {
    uint32_t magic;
    uint16_t version;
    uint16_t operation;
    uint32_t byte_count;
    uint32_t fd_count;
    uint64_t request_id;
    uint32_t status;
    uint32_t reserved;
};

#ifdef __cplusplus
}
#endif

#endif
