#ifndef COLLIDER_PLATFORM_C_H
#define COLLIDER_PLATFORM_C_H

#include <stdint.h>

int32_t collider_lock_exclusive(int32_t descriptor, int32_t wait);
int32_t collider_unlock(int32_t descriptor);
int32_t collider_sync_file(int32_t descriptor);
int32_t collider_sync_directory(int32_t descriptor);
int32_t collider_replace(const char *source, const char *destination);
int32_t collider_exchange(const char *left, const char *right);
int32_t collider_symlink(const char *target, const char *link_path);

#endif
