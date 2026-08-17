#define _GNU_SOURCE
#include "ColliderPlatformC.h"

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stddef.h>
#include <stdlib.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <stdio.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>
#if defined(__linux__)
#include <linux/android/binderfs.h>
#include <linux/loop.h>
#include <linux/mount.h>
#include <sys/mount.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/un.h>
#elif defined(__APPLE__)
#include <sys/clonefile.h>
#include <sys/stdio.h>
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
#elif defined(__APPLE__)
    return renameatx_np(
        AT_FDCWD, left, AT_FDCWD, right, RENAME_SWAP);
#else
    (void)left;
    (void)right;
    errno = ENOTSUP;
    return -1;
#endif
}

int32_t collider_clone_file(const char *source, const char *destination) {
#if defined(__APPLE__)
    return clonefile(source, destination, CLONE_NOOWNERCOPY);
#else
    (void)source;
    (void)destination;
    errno = ENOTSUP;
    return -1;
#endif
}

int32_t collider_symlink(const char *target, const char *link_path) {
    return symlink(target, link_path);
}

int32_t collider_open_raw_pseudo_terminal(
    char *slave_path,
    size_t slave_path_capacity,
    int32_t *slave_descriptor) {
#if defined(__linux__) || defined(__APPLE__)
    if (slave_path == NULL || slave_path_capacity == 0U
        || slave_descriptor == NULL) {
        errno = EINVAL;
        return -1;
    }
    int master = posix_openpt(
        O_RDWR | O_NOCTTY | O_CLOEXEC | O_NONBLOCK);
    if (master < 0) {
        return -1;
    }
    if (grantpt(master) != 0 || unlockpt(master) != 0) {
        int saved_errno = errno;
        (void)close(master);
        errno = saved_errno;
        return -1;
    }
    int path_error = ptsname_r(
        master, slave_path, slave_path_capacity);
    if (path_error != 0) {
        (void)close(master);
        errno = path_error;
        return -1;
    }
    int slave = open(
        slave_path, O_RDWR | O_NOCTTY | O_CLOEXEC | O_NONBLOCK);
    if (slave < 0) {
        int saved_errno = errno;
        (void)close(master);
        errno = saved_errno;
        return -1;
    }
    struct termios attributes;
    if (tcgetattr(slave, &attributes) != 0) {
        int saved_errno = errno;
        (void)close(slave);
        (void)close(master);
        errno = saved_errno;
        return -1;
    }
    cfmakeraw(&attributes);
    if (tcsetattr(slave, TCSANOW, &attributes) != 0) {
        int saved_errno = errno;
        (void)close(slave);
        (void)close(master);
        errno = saved_errno;
        return -1;
    }
    *slave_descriptor = slave;
    return master;
#else
    (void)slave_path;
    (void)slave_path_capacity;
    (void)slave_descriptor;
    errno = ENOTSUP;
    return -1;
#endif
}

int32_t collider_binderfs_add_device(
    const char *control_path,
    const char *name,
    uint32_t *major,
    uint32_t *minor) {
#if defined(__linux__)
    if (control_path == NULL || name == NULL || major == NULL || minor == NULL) {
        errno = EINVAL;
        return -1;
    }
    struct binderfs_device device = {0};
    size_t name_length = strnlen(name, BINDERFS_MAX_NAME + 1U);
    if (name_length == 0U || name_length > BINDERFS_MAX_NAME) {
        errno = EINVAL;
        return -1;
    }
    memcpy(device.name, name, name_length);
    int descriptor = open(control_path, O_RDONLY | O_CLOEXEC);
    if (descriptor < 0) {
        return -1;
    }
    int result = ioctl(descriptor, BINDER_CTL_ADD, &device);
    int saved_errno = errno;
    if (close(descriptor) != 0 && result == 0) {
        return -1;
    }
    if (result != 0) {
        errno = saved_errno;
        return -1;
    }
    *major = device.major;
    *minor = device.minor;
    return 0;
#else
    (void)control_path;
    (void)name;
    (void)major;
    (void)minor;
    errno = ENOTSUP;
    return -1;
#endif
}
