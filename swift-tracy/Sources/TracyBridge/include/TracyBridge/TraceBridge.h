#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SwiftTracyZoneContext {
  uint32_t id;
  int32_t active;
} SwiftTracyZoneContext;

bool swift_tracy_enabled(void);
bool swift_tracy_connected(void);

SwiftTracyZoneContext swift_tracy_begin_zone(
    const char *name,
    size_t name_length,
    const char *function,
    size_t function_length,
    const char *file,
    size_t file_length,
    uint32_t line,
    uint32_t color);

void swift_tracy_end_zone(SwiftTracyZoneContext zone);
void swift_tracy_zone_value(SwiftTracyZoneContext zone, uint64_t value);
void swift_tracy_zone_text(
    SwiftTracyZoneContext zone,
    const char *text,
    size_t text_length);

void swift_tracy_set_thread_name(const char *name, size_t name_length);
void swift_tracy_message(const char *text, size_t text_length);
void swift_tracy_message_color(
    const char *text,
    size_t text_length,
    uint32_t color);
void swift_tracy_plot(const char *name, double value);
void swift_tracy_plot_int(const char *name, int64_t value);
void swift_tracy_frame_mark_start(const char *name);
void swift_tracy_frame_mark_end(const char *name);

#ifdef __cplusplus
}
#endif
