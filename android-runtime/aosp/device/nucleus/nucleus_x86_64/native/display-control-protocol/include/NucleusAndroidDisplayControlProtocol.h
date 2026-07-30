#ifndef NUCLEUS_ANDROID_DISPLAY_CONTROL_PROTOCOL_H
#define NUCLEUS_ANDROID_DISPLAY_CONTROL_PROTOCOL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

static const uint32_t NUCLEUS_ANDROID_DISPLAY_CONTROL_MAX_MESSAGE_BYTES = 64;

enum nucleus_android_display_control_operation {
    NUCLEUS_ANDROID_DISPLAY_CONTROL_REGISTER = 1,
    NUCLEUS_ANDROID_DISPLAY_CONTROL_CONFIGURE = 2,
    NUCLEUS_ANDROID_DISPLAY_CONTROL_RESIZE = 3,
};

struct nucleus_android_display_control_header {
    uint32_t operation;
    uint32_t byte_count;
    uint32_t fd_count;
};

struct nucleus_android_display_control_register {
    uint32_t operation;
    uint32_t byte_count;
    uint32_t fd_count;
    uint64_t presentation_id;
};

struct nucleus_android_display_control_configuration {
    uint32_t operation;
    uint32_t byte_count;
    uint32_t fd_count;
    uint64_t presentation_id;
    uint64_t generation;
    uint32_t width;
    uint32_t height;
    uint32_t density_dpi;
    uint32_t refresh_millihertz;
};

#ifdef __cplusplus
}
#endif

#endif
