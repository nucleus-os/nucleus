#define _GNU_SOURCE
#include "NucleusAndroidIPCC.h"

#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#define NUCLEUS_ANDROID_MAX_FDS 64

static int nucleus_android_set_cloexec(int fd) {
    int flags = fcntl(fd, F_GETFD);
    if (flags < 0 || fcntl(fd, F_SETFD, flags | FD_CLOEXEC) < 0) {
        int saved = errno;
        close(fd);
        errno = saved;
        return -1;
    }
    return fd;
}

static int nucleus_android_socket_address(
    const char *path,
    struct sockaddr_un *address,
    socklen_t *length) {
    if (!path || !address || !length) {
        errno = EINVAL;
        return -1;
    }
    size_t size = strlen(path);
    if (size == 0 || size >= sizeof(address->sun_path)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    memset(address, 0, sizeof(*address));
    address->sun_family = AF_UNIX;
    memcpy(address->sun_path, path, size + 1);
    *length = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + size + 1);
    return 0;
}

int nucleus_android_ipc_socket_pair(int output_fds[2]) {
    if (!output_fds) {
        errno = EINVAL;
        return -1;
    }
    return socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, output_fds);
}

int nucleus_android_ipc_listen(const char *path, uint32_t mode) {
    struct sockaddr_un address;
    socklen_t length = 0;
    if (nucleus_android_socket_address(path, &address, &length) < 0) return -1;

    struct stat existing;
    if (lstat(path, &existing) == 0) {
        if (!S_ISSOCK(existing.st_mode) || existing.st_uid != geteuid()) {
            errno = EEXIST;
            return -1;
        }
        if (unlink(path) < 0) return -1;
    } else if (errno != ENOENT) {
        return -1;
    }

    int fd = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    if (bind(fd, (const struct sockaddr *)&address, length) < 0 ||
        chmod(path, mode & 0777u) < 0 || listen(fd, 16) < 0) {
        int saved = errno;
        close(fd);
        unlink(path);
        errno = saved;
        return -1;
    }
    return fd;
}

int nucleus_android_ipc_accept(int listener_fd) {
    int fd = accept4(listener_fd, NULL, NULL, SOCK_CLOEXEC);
    if (fd >= 0 || errno != ENOSYS) return fd;
    fd = accept(listener_fd, NULL, NULL);
    return fd < 0 ? -1 : nucleus_android_set_cloexec(fd);
}

int nucleus_android_ipc_connect(const char *path) {
    struct sockaddr_un address;
    socklen_t length = 0;
    if (nucleus_android_socket_address(path, &address, &length) < 0) return -1;
    int fd = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    if (connect(fd, (const struct sockaddr *)&address, length) < 0) {
        int saved = errno;
        close(fd);
        errno = saved;
        return -1;
    }
    return fd;
}

int nucleus_android_ipc_peer_credentials(
    int socket_fd,
    struct nucleus_android_peer_credentials *output) {
    if (!output) {
        errno = EINVAL;
        return -1;
    }
    struct ucred credentials;
    socklen_t size = sizeof(credentials);
    if (getsockopt(socket_fd, SOL_SOCKET, SO_PEERCRED, &credentials, &size) < 0) return -1;
    output->pid = credentials.pid;
    output->uid = credentials.uid;
    output->gid = credentials.gid;
    return 0;
}

int nucleus_android_ipc_send(
    int socket_fd,
    const void *bytes,
    size_t byte_count,
    const int *fds,
    size_t fd_count) {
    if (!bytes || byte_count == 0 || fd_count > NUCLEUS_ANDROID_MAX_FDS ||
        (fd_count > 0 && !fds)) {
        errno = EINVAL;
        return -1;
    }
    struct iovec iov = {.iov_base = (void *)bytes, .iov_len = byte_count};
    char control[CMSG_SPACE(sizeof(int) * NUCLEUS_ANDROID_MAX_FDS)];
    struct msghdr message;
    memset(&message, 0, sizeof(message));
    message.msg_iov = &iov;
    message.msg_iovlen = 1;
    if (fd_count > 0) {
        message.msg_control = control;
        message.msg_controllen = CMSG_SPACE(sizeof(int) * fd_count);
        memset(control, 0, message.msg_controllen);
        struct cmsghdr *header = CMSG_FIRSTHDR(&message);
        header->cmsg_level = SOL_SOCKET;
        header->cmsg_type = SCM_RIGHTS;
        header->cmsg_len = CMSG_LEN(sizeof(int) * fd_count);
        memcpy(CMSG_DATA(header), fds, sizeof(int) * fd_count);
    }
    ssize_t sent;
    do {
        sent = sendmsg(socket_fd, &message, MSG_NOSIGNAL);
    } while (sent < 0 && errno == EINTR);
    if (sent < 0) return -1;
    if ((size_t)sent != byte_count) {
        errno = EIO;
        return -1;
    }
    return 0;
}

int nucleus_android_ipc_receive(
    int socket_fd,
    void *bytes,
    size_t byte_capacity,
    int *fds,
    size_t fd_capacity,
    size_t *output_fd_count) {
    if (!bytes || byte_capacity == 0 || !output_fd_count ||
        fd_capacity > NUCLEUS_ANDROID_MAX_FDS || (fd_capacity > 0 && !fds)) {
        errno = EINVAL;
        return -1;
    }
    *output_fd_count = 0;
    struct iovec iov = {.iov_base = bytes, .iov_len = byte_capacity};
    char control[CMSG_SPACE(sizeof(int) * NUCLEUS_ANDROID_MAX_FDS)];
    struct msghdr message;
    memset(&message, 0, sizeof(message));
    message.msg_iov = &iov;
    message.msg_iovlen = 1;
    message.msg_control = control;
    message.msg_controllen = sizeof(control);

    ssize_t received;
    do {
        received = recvmsg(socket_fd, &message, MSG_CMSG_CLOEXEC);
    } while (received < 0 && errno == EINTR);
    if (received <= 0) {
        if (received == 0) errno = ECONNRESET;
        return -1;
    }

    size_t copied = 0;
    int dropped_descriptors = 0;
    for (struct cmsghdr *header = CMSG_FIRSTHDR(&message); header;
         header = CMSG_NXTHDR(&message, header)) {
        if (header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS) continue;
        size_t payload = header->cmsg_len - CMSG_LEN(0);
        size_t count = payload / sizeof(int);
        const int *received_fds = (const int *)CMSG_DATA(header);
        for (size_t index = 0; index < count; ++index) {
            if (copied < fd_capacity) {
                fds[copied++] = received_fds[index];
            } else {
                close(received_fds[index]);
                dropped_descriptors = 1;
            }
        }
    }
    if ((message.msg_flags & (MSG_TRUNC | MSG_CTRUNC)) != 0 || dropped_descriptors) {
        for (size_t index = 0; index < copied; ++index) close(fds[index]);
        errno = EMSGSIZE;
        return -1;
    }
    *output_fd_count = copied;
    return (int)received;
}
