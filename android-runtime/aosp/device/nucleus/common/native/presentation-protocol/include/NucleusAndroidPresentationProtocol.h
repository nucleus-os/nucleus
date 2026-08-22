#ifndef NUCLEUS_ANDROID_PRESENTATION_PROTOCOL_H
#define NUCLEUS_ANDROID_PRESENTATION_PROTOCOL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

static const uint32_t NUCLEUS_ANDROID_PRESENTATION_MAX_MESSAGE_BYTES = 256;
static const uint32_t NUCLEUS_ANDROID_PRESENTATION_MAX_FDS = 3;

enum nucleus_android_presentation_operation {
    NUCLEUS_ANDROID_PRESENTATION_PRESENT = 1,
};

enum nucleus_android_presentation_status {
    NUCLEUS_ANDROID_PRESENTATION_STATUS_OK = 0,
    NUCLEUS_ANDROID_PRESENTATION_STATUS_INVALID_REQUEST = 1,
    NUCLEUS_ANDROID_PRESENTATION_STATUS_UNKNOWN_PRESENTATION = 2,
    NUCLEUS_ANDROID_PRESENTATION_STATUS_UNSUPPORTED_BUFFER = 3,
    NUCLEUS_ANDROID_PRESENTATION_STATUS_FAILED = 4,
};

struct nucleus_android_presentation_message_header {
    uint32_t operation;
    uint32_t byte_count;
    uint32_t fd_count;
};

struct nucleus_android_presentation_frame {
    uint32_t operation;
    uint32_t byte_count;
    uint32_t fd_count;
    uint64_t request_id;
    uint64_t presentation_id;
    uint64_t configuration_generation;
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
    int32_t android_display_id;
    uint32_t has_acquire_fence;
};

struct nucleus_android_presentation_frame_reply {
    uint32_t operation;
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
