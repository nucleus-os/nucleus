#include "ColliderPlatformC.h"

#include <errno.h>
#include <fcntl.h>
#include <sys/file.h>
#include <stdio.h>
#include <unistd.h>
#if defined(__linux__)
#include <sys/syscall.h>
#endif

int32_t collider_lock_exclusive(int32_t descriptor, int32_t wait) {
    return flock(descriptor, LOCK_EX | (wait ? 0 : LOCK_NB));
}

int32_t collider_unlock(int32_t descriptor) {
    return flock(descriptor, LOCK_UN);
}

int32_t collider_sync_file(int32_t descriptor) {
    return fsync(descriptor);
}

int32_t collider_sync_directory(int32_t descriptor) {
    return fsync(descriptor);
}

int32_t collider_replace(const char *source, const char *destination) {
    return rename(source, destination);
}

int32_t collider_exchange(const char *left, const char *right) {
#if defined(__linux__) && defined(SYS_renameat2)
    return (int32_t)syscall(
        SYS_renameat2, AT_FDCWD, left, AT_FDCWD, right, 1U << 1);
#else
    (void)left;
    (void)right;
    errno = ENOTSUP;
    return -1;
#endif
}

int32_t collider_symlink(const char *target, const char *link_path) {
    return symlink(target, link_path);
}
