#include "NightlyReservationStorageC.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

int32_t nucleus_reservation_lock(const char *path, int32_t initialize) {
    int flags = O_RDWR | O_CLOEXEC | O_NOFOLLOW;
    if (initialize) flags |= O_CREAT | O_EXCL;
    int fd = open(path, flags, 0600);
    if (fd < 0) return -errno;
    struct stat info;
    if (fstat(fd, &info) != 0) {
        int error = errno;
        close(fd);
        return -error;
    }
    if (!S_ISREG(info.st_mode)) {
        close(fd);
        return -EINVAL;
    }
    while (flock(fd, LOCK_EX) != 0) {
        if (errno == EINTR) continue;
        int error = errno;
        close(fd);
        return -error;
    }
    return fd;
}

void nucleus_reservation_unlock(int32_t descriptor) {
    // Closing releases the kernel lock, including on process termination.
    close(descriptor);
}

int32_t nucleus_reservation_sync_directory(const char *path) {
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return errno;
    int error = fsync(fd) == 0 ? 0 : errno;
    close(fd);
    return error;
}

int32_t nucleus_reservation_commit(const char *candidate, const char *destination, const char *directory) {
    int fd = open(candidate, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return errno;
    int dir = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (dir < 0) {
        int error = errno;
        close(fd);
        return error;
    }
    int error = 0;
    if (fsync(fd) != 0 || rename(candidate, destination) != 0 || fsync(dir) != 0) error = errno;
#if defined(__APPLE__)
    // fsync alone does not flush a macOS device's volatile write cache.
    if (error == 0 && fcntl(fd, F_FULLFSYNC) != 0) error = errno;
#endif
    close(dir);
    close(fd);
    return error;
}
