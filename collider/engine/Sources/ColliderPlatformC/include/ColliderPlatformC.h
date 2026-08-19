#ifndef COLLIDER_PLATFORM_C_H
#define COLLIDER_PLATFORM_C_H

#include <stddef.h>
#include <stdint.h>

int32_t collider_lock_exclusive(int32_t descriptor, int32_t wait);
int32_t collider_unlock(int32_t descriptor);

/// Copies a file's contents and mode without its access-control list.
///
/// A build stages inputs out of a source tree whose access control exists to
/// keep the executing identity from modifying it. Carrying that control onto
/// the copy leaves the builder owning a file it is denied permission to delete.
/// An ACL describes where a file lives, not what it contains.
int32_t collider_copy_file_without_acl(const char *source, const char *destination);
int32_t collider_copy_tree_without_acl(const char *source, const char *destination);
int32_t collider_sync_file(int32_t descriptor);
int32_t collider_sync_directory(int32_t descriptor);
int32_t collider_replace(const char *source, const char *destination);
int32_t collider_exchange(const char *left, const char *right);
int32_t collider_clone_file(const char *source, const char *destination);
int32_t collider_symlink(const char *target, const char *link_path);
int32_t collider_terminal_size(
    int32_t descriptor,
    uint16_t *columns,
    uint16_t *rows);
int32_t collider_terminal_scalar_width(uint32_t scalar);
int32_t collider_binderfs_add_device(
    const char *control_path,
    const char *name,
    uint32_t *major,
    uint32_t *minor);
int32_t collider_open_raw_pseudo_terminal(
    char *slave_path,
    size_t slave_path_capacity,
    int32_t *slave_descriptor);

#endif
