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
#include <wchar.h>
#if defined(__linux__)
#include <dirent.h>
#include <limits.h>
#include <linux/android/binderfs.h>
#include <linux/loop.h>
#include <linux/mount.h>
#include <sys/mount.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/un.h>
#elif defined(__APPLE__)
#include <copyfile.h>
#include <sys/clonefile.h>
#include <sys/stdio.h>
#endif

int32_t collider_lock_exclusive(int32_t descriptor, int32_t wait) {
    return flock(descriptor, LOCK_EX | (wait ? 0 : LOCK_NB));
}

int32_t collider_unlock(int32_t descriptor) {
    return flock(descriptor, LOCK_UN);
}

#if defined(__linux__)
// Contents, mode, and timestamps, never extended attributes. A POSIX ACL lives
// in system.posix_acl_access, so copying no xattrs is what leaves the ACL
// behind. A plain read/write loop rather than copy_file_range, because the
// copies that matter here cross mount boundaries between a read-only input and
// a writable export, where the kernel may refuse the reflink path.
static int32_t collider_copy_regular_linux(
    const char *source, const char *destination, const struct stat *info) {
    int in = open(source, O_RDONLY | O_CLOEXEC);
    if (in < 0) {
        return -1;
    }
    int out = open(
        destination, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, info->st_mode & 07777);
    if (out < 0) {
        int failure = errno;
        close(in);
        errno = failure;
        return -1;
    }
    char buffer[131072];
    for (;;) {
        ssize_t read_count = read(in, buffer, sizeof(buffer));
        if (read_count == 0) {
            break;
        }
        if (read_count < 0) {
            if (errno == EINTR) {
                continue;
            }
            int failure = errno;
            close(in);
            close(out);
            errno = failure;
            return -1;
        }
        ssize_t written = 0;
        while (written < read_count) {
            ssize_t write_count = write(out, buffer + written, (size_t)(read_count - written));
            if (write_count < 0) {
                if (errno == EINTR) {
                    continue;
                }
                int failure = errno;
                close(in);
                close(out);
                errno = failure;
                return -1;
            }
            written += write_count;
        }
    }
    if (fchmod(out, info->st_mode & 07777) != 0) {
        int failure = errno;
        close(in);
        close(out);
        errno = failure;
        return -1;
    }
    struct timespec times[2];
    times[0] = info->st_atim;
    times[1] = info->st_mtim;
    (void)futimens(out, times);
    close(in);
    if (close(out) != 0) {
        return -1;
    }
    return 0;
}

static int32_t collider_copy_entry_linux(const char *source, const char *destination);

static int32_t collider_copy_directory_linux(
    const char *source, const char *destination, const struct stat *info) {
    if (mkdir(destination, info->st_mode & 07777) != 0 && errno != EEXIST) {
        return -1;
    }
    DIR *directory = opendir(source);
    if (directory == NULL) {
        return -1;
    }
    int32_t result = 0;
    struct dirent *entry;
    while (result == 0 && (entry = readdir(directory)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        char *child_source = NULL;
        char *child_destination = NULL;
        if (asprintf(&child_source, "%s/%s", source, entry->d_name) < 0
            || asprintf(&child_destination, "%s/%s", destination, entry->d_name) < 0) {
            free(child_source);
            errno = ENOMEM;
            result = -1;
            break;
        }
        result = collider_copy_entry_linux(child_source, child_destination);
        free(child_source);
        free(child_destination);
    }
    int failure = errno;
    closedir(directory);
    if (result != 0) {
        errno = failure;
        return -1;
    }
    struct timespec times[2];
    times[0] = info->st_atim;
    times[1] = info->st_mtim;
    (void)utimensat(AT_FDCWD, destination, times, AT_SYMLINK_NOFOLLOW);
    return 0;
}

static int32_t collider_copy_entry_linux(const char *source, const char *destination) {
    struct stat info;
    if (lstat(source, &info) != 0) {
        return -1;
    }
    if (S_ISLNK(info.st_mode)) {
        char target[PATH_MAX];
        ssize_t length = readlink(source, target, sizeof(target) - 1);
        if (length < 0) {
            return -1;
        }
        target[length] = '\0';
        if (unlink(destination) != 0 && errno != ENOENT) {
            return -1;
        }
        return symlink(target, destination) == 0 ? 0 : -1;
    }
    if (S_ISDIR(info.st_mode)) {
        return collider_copy_directory_linux(source, destination, &info);
    }
    if (!S_ISREG(info.st_mode)) {
        // Sockets, devices, and fifos are not build outputs. Refusing them is
        // better than materializing something the consumer cannot reason about.
        errno = ENOTSUP;
        return -1;
    }
    return collider_copy_regular_linux(source, destination, &info);
}
#endif

int32_t collider_copy_file_without_acl(const char *source, const char *destination) {
#if defined(__APPLE__)
    // COPYFILE_DATA and COPYFILE_STAT without COPYFILE_ACL: mode, timestamps,
    // and contents travel with the copy; the source's access-control list does
    // not.
    return (int32_t)copyfile(source, destination, NULL, COPYFILE_DATA | COPYFILE_STAT);
#elif defined(__linux__)
    struct stat info;
    if (stat(source, &info) != 0) {
        return -1;
    }
    if (!S_ISREG(info.st_mode)) {
        errno = ENOTSUP;
        return -1;
    }
    return collider_copy_regular_linux(source, destination, &info);
#else
    (void)source;
    (void)destination;
    errno = ENOTSUP;
    return -1;
#endif
}

int32_t collider_copy_tree_without_acl(const char *source, const char *destination) {
#if defined(__APPLE__)
    return (int32_t)copyfile(
        source, destination, NULL,
        COPYFILE_DATA | COPYFILE_STAT | COPYFILE_RECURSIVE);
#elif defined(__linux__)
    return collider_copy_entry_linux(source, destination);
#else
    (void)source;
    (void)destination;
    errno = ENOTSUP;
    return -1;
#endif
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

int32_t collider_terminal_size(
    int32_t descriptor,
    uint16_t *columns,
    uint16_t *rows) {
    if (columns == NULL || rows == NULL) {
        errno = EINVAL;
        return -1;
    }
    struct winsize size = {0};
    if (ioctl(descriptor, TIOCGWINSZ, &size) != 0) {
        return -1;
    }
    if (size.ws_col == 0U || size.ws_row == 0U) {
        errno = EINVAL;
        return -1;
    }
    *columns = size.ws_col;
    *rows = size.ws_row;
    return 0;
}

int32_t collider_terminal_scalar_width(uint32_t scalar) {
    if (scalar > (uint32_t)WCHAR_MAX) {
        return 1;
    }
    int width = wcwidth((wchar_t)scalar);
    return width < 0 ? 1 : (int32_t)width;
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
