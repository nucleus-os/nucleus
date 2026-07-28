#ifndef NUCLEUS_IPC_TRANSPORT_C_H
#define NUCLEUS_IPC_TRANSPORT_C_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct nucleus_ipc_peer_credentials {
    int32_t pid;
    uint32_t uid;
    uint32_t gid;
};

int nucleus_ipc_socket_pair(int output_fds[2]);
int nucleus_ipc_listen(const char *path, uint32_t mode);
int nucleus_ipc_accept(int listener_fd);
int nucleus_ipc_connect(const char *path);
int nucleus_ipc_peer_credentials(
    int socket_fd,
    struct nucleus_ipc_peer_credentials *output);
int nucleus_ipc_send(
    int socket_fd,
    const void *bytes,
    size_t byte_count,
    const int *fds,
    size_t fd_count);
int nucleus_ipc_receive(
    int socket_fd,
    void *bytes,
    size_t byte_capacity,
    int *fds,
    size_t fd_capacity,
    size_t *output_fd_count);

#ifdef __cplusplus
}
#endif

#endif
