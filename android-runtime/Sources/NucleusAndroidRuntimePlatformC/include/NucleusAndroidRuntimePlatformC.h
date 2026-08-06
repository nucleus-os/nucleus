#ifndef NUCLEUS_ANDROID_RUNTIME_PLATFORM_C_H
#define NUCLEUS_ANDROID_RUNTIME_PLATFORM_C_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int32_t nucleus_android_runtime_open_raw_pseudo_terminal(
    char *slave_path,
    size_t slave_path_capacity);

int32_t nucleus_android_runtime_binderfs_add_device(
    const char *control_path,
    const char *name,
    uint32_t *major,
    uint32_t *minor);

int32_t nucleus_android_runtime_pidfd_open(int32_t process_identifier);

int32_t nucleus_android_runtime_pidfd_wait(
    int32_t descriptor,
    int32_t timeout_milliseconds);

int32_t nucleus_android_runtime_spawn_container_launcher(
    const char *container_name,
    const char *configuration,
    const char *log_file);

int32_t nucleus_android_runtime_poll_process_status(
    int32_t process_identifier);

int32_t nucleus_android_runtime_wait_process_status(
    int32_t process_identifier);

int32_t nucleus_android_runtime_stop_container(
    const char *container_name);

enum nucleus_android_runtime_apex_payload_filesystem {
    NUCLEUS_ANDROID_RUNTIME_APEX_PAYLOAD_FILESYSTEM_EROFS = 1,
    NUCLEUS_ANDROID_RUNTIME_APEX_PAYLOAD_FILESYSTEM_EXT4 = 2,
};

int32_t nucleus_android_runtime_mount_apex_in_chroot(
    const char *root_path,
    const char *source_path,
    const char *target_path,
    uint32_t payload_filesystem,
    uint64_t payload_offset);

int32_t nucleus_android_runtime_android_bpf_delegation_broker(
    const char *socket_path,
    uint32_t container_root_uid,
    uint32_t container_root_gid);

int32_t nucleus_android_runtime_android_bpf_delegation_mount(
    const char *socket_path,
    const char *target_path);

#ifdef __cplusplus
}
#endif

#endif
