#ifndef COLLIDER_PLATFORM_C_H
#define COLLIDER_PLATFORM_C_H

#include <stddef.h>
#include <stdint.h>

int32_t collider_lock_exclusive(int32_t descriptor, int32_t wait);
int32_t collider_unlock(int32_t descriptor);
int32_t collider_sync_file(int32_t descriptor);
int32_t collider_sync_directory(int32_t descriptor);
int32_t collider_replace(const char *source, const char *destination);
int32_t collider_exchange(const char *left, const char *right);
int32_t collider_symlink(const char *target, const char *link_path);
int32_t collider_binderfs_add_device(
    const char *control_path,
    const char *name,
    uint32_t *major,
    uint32_t *minor);
enum collider_apex_payload_filesystem {
    COLLIDER_APEX_PAYLOAD_FILESYSTEM_EROFS = 1,
    COLLIDER_APEX_PAYLOAD_FILESYSTEM_EXT4 = 2,
};

int32_t collider_mount_apex_in_chroot(
    const char *root_path,
    const char *source_path,
    const char *target_path,
    uint32_t payload_filesystem,
    uint64_t payload_offset);
int32_t collider_android_bpf_delegation_broker(
    const char *socket_path,
    uint32_t expected_peer_uid);
int32_t collider_android_bpf_delegation_mount(
    const char *socket_path,
    const char *target_path);
int32_t collider_open_raw_pseudo_terminal(
    char *slave_path,
    size_t slave_path_capacity);
char *collider_copy_loaded_library_path(const char *symbol);

#endif
