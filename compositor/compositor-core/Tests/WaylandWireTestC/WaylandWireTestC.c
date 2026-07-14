#include "WaylandWireTestC.h"

#include <errno.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

int swift_wayland_test_send_fd(
    int socket_fd, const void *bytes, size_t byte_count, int passed_fd) {
    if (socket_fd < 0 || passed_fd < 0 || bytes == NULL || byte_count == 0) {
        return EINVAL;
    }

    char control[CMSG_SPACE(sizeof(int))];
    memset(control, 0, sizeof(control));

    struct iovec iov = {
        .iov_base = (void *)bytes,
        .iov_len = byte_count,
    };
    struct msghdr message;
    memset(&message, 0, sizeof(message));
    message.msg_iov = &iov;
    message.msg_iovlen = 1;
    message.msg_control = control;
    message.msg_controllen = sizeof(control);

    struct cmsghdr *header = CMSG_FIRSTHDR(&message);
    if (header == NULL) return EINVAL;
    header->cmsg_level = SOL_SOCKET;
    header->cmsg_type = SCM_RIGHTS;
    header->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(header), &passed_fd, sizeof(passed_fd));

    ssize_t sent;
    do {
        sent = sendmsg(socket_fd, &message, MSG_NOSIGNAL);
    } while (sent < 0 && errno == EINTR);
    if (sent < 0) return errno;

    const uint8_t *remaining = (const uint8_t *)bytes + (size_t)sent;
    size_t remaining_count = byte_count - (size_t)sent;
    while (remaining_count > 0) {
        ssize_t n;
        do {
            n = send(socket_fd, remaining, remaining_count, MSG_NOSIGNAL);
        } while (n < 0 && errno == EINTR);
        if (n < 0) return errno;
        if (n == 0) return EIO;
        remaining += (size_t)n;
        remaining_count -= (size_t)n;
    }
    return 0;
}
