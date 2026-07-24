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
#include <dlfcn.h>
#include <linux/android/binderfs.h>
#include <linux/loop.h>
#include <linux/mount.h>
#include <sys/mount.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/un.h>
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

int32_t collider_open_raw_pseudo_terminal(
    char *slave_path,
    size_t slave_path_capacity) {
#if defined(__linux__)
    if (slave_path == NULL || slave_path_capacity == 0U) {
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
    if (close(slave) != 0) {
        int saved_errno = errno;
        (void)close(master);
        errno = saved_errno;
        return -1;
    }
    return master;
#else
    (void)slave_path;
    (void)slave_path_capacity;
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

int32_t collider_mount_apex_in_chroot(
    const char *root_path,
    const char *source_path,
    const char *target_path,
    uint32_t payload_filesystem,
    uint64_t payload_offset) {
#if defined(__linux__)
    if (root_path == NULL || source_path == NULL || target_path == NULL
        || payload_offset == 0U
        || (payload_filesystem != COLLIDER_APEX_PAYLOAD_FILESYSTEM_EROFS
            && payload_filesystem != COLLIDER_APEX_PAYLOAD_FILESYSTEM_EXT4)) {
        errno = EINVAL;
        return -1;
    }

    int loop_control_descriptor = -1;
    int loop_descriptor = -1;
    int loop_number = -1;
    if (payload_filesystem == COLLIDER_APEX_PAYLOAD_FILESYSTEM_EXT4) {
        loop_control_descriptor = open(
            "/dev/loop-control", O_RDWR | O_CLOEXEC | O_NOFOLLOW);
        if (loop_control_descriptor < 0) {
            return -1;
        }
        loop_number = ioctl(loop_control_descriptor, LOOP_CTL_GET_FREE);
        if (loop_number < 0) {
            int saved_errno = errno;
            (void)close(loop_control_descriptor);
            errno = saved_errno;
            return -1;
        }
        char loop_path[64];
        int loop_path_length = snprintf(
            loop_path, sizeof(loop_path), "/dev/loop%d", loop_number);
        if (loop_path_length < 0
            || (size_t)loop_path_length >= sizeof(loop_path)) {
            (void)close(loop_control_descriptor);
            errno = EOVERFLOW;
            return -1;
        }
        loop_descriptor = open(
            loop_path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
        if (loop_descriptor < 0) {
            int saved_errno = errno;
            (void)close(loop_control_descriptor);
            errno = saved_errno;
            return -1;
        }
    }

    int root_descriptor = open(
        root_path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW);
    if (root_descriptor < 0) {
        int saved_errno = errno;
        (void)close(loop_descriptor);
        (void)close(loop_control_descriptor);
        errno = saved_errno;
        return -1;
    }
    if (fchdir(root_descriptor) != 0 || chroot(".") != 0 || chdir("/") != 0) {
        int saved_errno = errno;
        (void)close(root_descriptor);
        (void)close(loop_descriptor);
        (void)close(loop_control_descriptor);
        errno = saved_errno;
        return -1;
    }
    if (close(root_descriptor) != 0) {
        int saved_errno = errno;
        (void)close(loop_descriptor);
        (void)close(loop_control_descriptor);
        errno = saved_errno;
        return -1;
    }

    if (payload_filesystem == COLLIDER_APEX_PAYLOAD_FILESYSTEM_EROFS) {
        char options[64];
        int option_length = snprintf(
            options, sizeof(options), "fsoffset=%" PRIu64, payload_offset);
        if (option_length < 0 || (size_t)option_length >= sizeof(options)) {
            errno = EOVERFLOW;
            return -1;
        }
        return mount(
            source_path,
            target_path,
            "erofs",
            MS_RDONLY | MS_NOSUID | MS_NODEV,
            options);
    }

    int source_descriptor = open(
        source_path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (source_descriptor < 0) {
        int saved_errno = errno;
        (void)close(loop_descriptor);
        (void)close(loop_control_descriptor);
        errno = saved_errno;
        return -1;
    }

    struct loop_config configuration = {0};
    configuration.fd = (uint32_t)source_descriptor;
    configuration.info.lo_offset = payload_offset;
    configuration.info.lo_flags =
        LO_FLAGS_READ_ONLY | LO_FLAGS_AUTOCLEAR;
    if (ioctl(loop_descriptor, LOOP_CONFIGURE, &configuration) != 0) {
        int saved_errno = errno;
        (void)close(source_descriptor);
        (void)close(loop_descriptor);
        (void)close(loop_control_descriptor);
        errno = saved_errno;
        return -1;
    }
    if (close(source_descriptor) != 0) {
        int saved_errno = errno;
        (void)close(loop_descriptor);
        (void)close(loop_control_descriptor);
        errno = saved_errno;
        return -1;
    }
    if (close(loop_control_descriptor) != 0) {
        int saved_errno = errno;
        (void)close(loop_descriptor);
        errno = saved_errno;
        return -1;
    }

    struct stat loop_info;
    if (fstat(loop_descriptor, &loop_info) != 0) {
        int saved_errno = errno;
        (void)close(loop_descriptor);
        errno = saved_errno;
        return -1;
    }
    char temporary_device[64];
    int device_path_length = snprintf(
        temporary_device,
        sizeof(temporary_device),
        "/apex/.nucleus-loop-%d",
        loop_number);
    if (device_path_length < 0
        || (size_t)device_path_length >= sizeof(temporary_device)) {
        (void)close(loop_descriptor);
        errno = EOVERFLOW;
        return -1;
    }
    if (mknod(temporary_device, S_IFBLK | 0600, loop_info.st_rdev) != 0) {
        int saved_errno = errno;
        (void)close(loop_descriptor);
        errno = saved_errno;
        return -1;
    }

    int result = mount(
        temporary_device,
        target_path,
        "ext4",
        MS_RDONLY | MS_NOSUID | MS_NODEV,
        "noload");
    int saved_errno = result == 0 ? 0 : errno;
    if (unlink(temporary_device) != 0 && result == 0) {
        result = -1;
        saved_errno = errno;
        (void)umount2(target_path, MNT_DETACH);
    }
    if (close(loop_descriptor) != 0 && result == 0) {
        result = -1;
        saved_errno = errno;
        (void)umount2(target_path, MNT_DETACH);
    }
    errno = saved_errno;
    return result;
#else
    (void)root_path;
    (void)source_path;
    (void)target_path;
    (void)payload_filesystem;
    (void)payload_offset;
    errno = ENOTSUP;
    return -1;
#endif
}

#if defined(__linux__)
static int collider_fsopen(const char *filesystem, unsigned int flags) {
#if defined(SYS_fsopen)
    return (int)syscall(SYS_fsopen, filesystem, flags);
#else
    (void)filesystem;
    (void)flags;
    errno = ENOTSUP;
    return -1;
#endif
}

static int collider_fsconfig(
    int filesystem,
    unsigned int command,
    const char *key,
    const void *value,
    int auxiliary) {
#if defined(SYS_fsconfig)
    return (int)syscall(
        SYS_fsconfig, filesystem, command, key, value, auxiliary);
#else
    (void)filesystem;
    (void)command;
    (void)key;
    (void)value;
    (void)auxiliary;
    errno = ENOTSUP;
    return -1;
#endif
}

static int collider_fsmount(
    int filesystem,
    unsigned int flags,
    unsigned int mount_attributes) {
#if defined(SYS_fsmount)
    return (int)syscall(
        SYS_fsmount, filesystem, flags, mount_attributes);
#else
    (void)filesystem;
    (void)flags;
    (void)mount_attributes;
    errno = ENOTSUP;
    return -1;
#endif
}

static int collider_move_mount(
    int from_directory,
    const char *from_path,
    int to_directory,
    const char *to_path,
    unsigned int flags) {
#if defined(SYS_move_mount)
    return (int)syscall(
        SYS_move_mount,
        from_directory,
        from_path,
        to_directory,
        to_path,
        flags);
#else
    (void)from_directory;
    (void)from_path;
    (void)to_directory;
    (void)to_path;
    (void)flags;
    errno = ENOTSUP;
    return -1;
#endif
}

static int collider_android_bpf_socket_address(
    const char *socket_path,
    struct sockaddr_un *address,
    socklen_t *length) {
    if (socket_path == NULL || socket_path[0] != '/') {
        errno = EINVAL;
        return -1;
    }
    size_t path_length = strnlen(
        socket_path, sizeof(address->sun_path));
    if (path_length == 0U || path_length >= sizeof(address->sun_path)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    memset(address, 0, sizeof(*address));
    address->sun_family = AF_UNIX;
    memcpy(address->sun_path, socket_path, path_length + 1U);
    *length = (socklen_t)(
        offsetof(struct sockaddr_un, sun_path) + path_length + 1U);
    return 0;
}

static int collider_android_bpf_send_context(
    int socket_descriptor,
    int filesystem_context) {
    char payload = 0;
    struct iovec vector = {
        .iov_base = &payload,
        .iov_len = sizeof(payload),
    };
    union {
        char bytes[CMSG_SPACE(sizeof(filesystem_context))];
        struct cmsghdr alignment;
    } control = {0};
    struct msghdr message = {
        .msg_iov = &vector,
        .msg_iovlen = 1,
        .msg_control = control.bytes,
        .msg_controllen = sizeof(control.bytes),
    };
    struct cmsghdr *header = CMSG_FIRSTHDR(&message);
    header->cmsg_level = SOL_SOCKET;
    header->cmsg_type = SCM_RIGHTS;
    header->cmsg_len = CMSG_LEN(sizeof(filesystem_context));
    memcpy(
        CMSG_DATA(header),
        &filesystem_context,
        sizeof(filesystem_context));
    ssize_t result;
    do {
        result = sendmsg(socket_descriptor, &message, MSG_NOSIGNAL);
    } while (result < 0 && errno == EINTR);
    if (result != (ssize_t)sizeof(payload)) {
        if (result >= 0) {
            errno = EPROTO;
        }
        return -1;
    }
    return 0;
}

static int collider_android_bpf_receive_context(
    int socket_descriptor,
    int *filesystem_context) {
    char payload;
    struct iovec vector = {
        .iov_base = &payload,
        .iov_len = sizeof(payload),
    };
    union {
        char bytes[CMSG_SPACE(sizeof(*filesystem_context))];
        struct cmsghdr alignment;
    } control = {0};
    struct msghdr message = {
        .msg_iov = &vector,
        .msg_iovlen = 1,
        .msg_control = control.bytes,
        .msg_controllen = sizeof(control.bytes),
    };
    ssize_t result;
    do {
        result = recvmsg(socket_descriptor, &message, MSG_CMSG_CLOEXEC);
    } while (result < 0 && errno == EINTR);
    if (result != (ssize_t)sizeof(payload)
        || (message.msg_flags & (MSG_CTRUNC | MSG_TRUNC)) != 0) {
        if (result >= 0) {
            errno = EPROTO;
        }
        return -1;
    }
    struct cmsghdr *header = CMSG_FIRSTHDR(&message);
    if (header == NULL
        || header->cmsg_level != SOL_SOCKET
        || header->cmsg_type != SCM_RIGHTS
        || header->cmsg_len != CMSG_LEN(sizeof(*filesystem_context))) {
        errno = EPROTO;
        return -1;
    }
    memcpy(
        filesystem_context,
        CMSG_DATA(header),
        sizeof(*filesystem_context));
    return 0;
}

static int collider_android_bpf_send_status(
    int socket_descriptor,
    int32_t status) {
    const char *bytes = (const char *)&status;
    size_t remaining = sizeof(status);
    while (remaining > 0U) {
        ssize_t result = send(
            socket_descriptor, bytes, remaining, MSG_NOSIGNAL);
        if (result < 0 && errno == EINTR) {
            continue;
        }
        if (result <= 0) {
            if (result == 0) {
                errno = EPIPE;
            }
            return -1;
        }
        bytes += result;
        remaining -= (size_t)result;
    }
    return 0;
}

static int collider_android_bpf_receive_status(
    int socket_descriptor,
    int32_t *status) {
    char *bytes = (char *)status;
    size_t remaining = sizeof(*status);
    while (remaining > 0U) {
        ssize_t result = recv(socket_descriptor, bytes, remaining, 0);
        if (result < 0 && errno == EINTR) {
            continue;
        }
        if (result <= 0) {
            if (result == 0) {
                errno = ECONNRESET;
            }
            return -1;
        }
        bytes += result;
        remaining -= (size_t)result;
    }
    return 0;
}

static int collider_android_bpf_configure_context(
    int filesystem_context) {
    static const struct {
        const char *key;
        const char *value;
    } options[] = {
        {
            .key = "delegate_cmds",
            .value = "map_create:prog_load:btf_load",
        },
        {
            .key = "delegate_maps",
            .value = "any",
        },
        {
            .key = "delegate_progs",
            .value = "any",
        },
        {
            .key = "delegate_attachs",
            .value = "any",
        },
    };
    for (size_t index = 0U;
        index < sizeof(options) / sizeof(options[0]);
        ++index) {
        if (collider_fsconfig(
                filesystem_context,
                FSCONFIG_SET_STRING,
                options[index].key,
                options[index].value,
                0) != 0) {
            return -1;
        }
    }
    return collider_fsconfig(
        filesystem_context,
        FSCONFIG_CMD_CREATE,
        NULL,
        NULL,
        0);
}
#endif

int32_t collider_android_bpf_delegation_broker(
    const char *socket_path,
    uint32_t expected_peer_uid) {
#if defined(__linux__)
    if (geteuid() != 0 || expected_peer_uid == 0U) {
        errno = EPERM;
        return -1;
    }
    struct sockaddr_un address;
    socklen_t address_length;
    if (collider_android_bpf_socket_address(
            socket_path, &address, &address_length) != 0) {
        return -1;
    }

    int listener = socket(
        AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
    if (listener < 0) {
        return -1;
    }
    (void)unlink(socket_path);
    if (bind(
            listener,
            (const struct sockaddr *)&address,
            address_length) != 0
        || chown(socket_path, (uid_t)expected_peer_uid, (gid_t)-1) != 0
        || chmod(socket_path, 0600) != 0
        || listen(listener, 1) != 0) {
        int saved_errno = errno;
        (void)close(listener);
        (void)unlink(socket_path);
        errno = saved_errno;
        return -1;
    }

    int peer;
    do {
        peer = accept4(listener, NULL, NULL, SOCK_CLOEXEC);
    } while (peer < 0 && errno == EINTR);
    if (peer < 0) {
        int saved_errno = errno;
        (void)close(listener);
        (void)unlink(socket_path);
        errno = saved_errno;
        return -1;
    }

    struct ucred credentials;
    socklen_t credentials_length = sizeof(credentials);
    if (getsockopt(
            peer,
            SOL_SOCKET,
            SO_PEERCRED,
            &credentials,
            &credentials_length) != 0) {
        int saved_errno = errno;
        (void)close(peer);
        (void)close(listener);
        (void)unlink(socket_path);
        errno = saved_errno;
        return -1;
    }
    if (credentials_length != sizeof(credentials)
        || credentials.uid != (uid_t)expected_peer_uid) {
        (void)close(peer);
        (void)close(listener);
        (void)unlink(socket_path);
        errno = EPERM;
        return -1;
    }

    int filesystem_context = -1;
    if (collider_android_bpf_receive_context(
            peer, &filesystem_context) != 0) {
        int saved_errno = errno;
        (void)close(peer);
        (void)close(listener);
        (void)unlink(socket_path);
        errno = saved_errno;
        return -1;
    }
    int result = collider_android_bpf_configure_context(
        filesystem_context);
    int configuration_errno = result == 0 ? 0 : errno;
    int32_t status = result == 0 ? 0 : -configuration_errno;
    int status_result = collider_android_bpf_send_status(peer, status);
    int status_errno = status_result == 0 ? 0 : errno;
    if (close(filesystem_context) != 0 && result == 0
        && status_result == 0) {
        result = -1;
        configuration_errno = errno;
    }
    (void)close(peer);
    (void)close(listener);
    (void)unlink(socket_path);
    if (status_result != 0) {
        errno = status_errno;
        return -1;
    }
    if (result != 0) {
        errno = configuration_errno;
        return -1;
    }
    return 0;
#else
    (void)socket_path;
    (void)expected_peer_uid;
    errno = ENOTSUP;
    return -1;
#endif
}

int32_t collider_android_bpf_delegation_mount(
    const char *socket_path,
    const char *target_path) {
#if defined(__linux__)
    if (target_path == NULL || target_path[0] != '/') {
        errno = EINVAL;
        return -1;
    }
    struct sockaddr_un address;
    socklen_t address_length;
    if (collider_android_bpf_socket_address(
            socket_path, &address, &address_length) != 0) {
        return -1;
    }

    int peer = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
    if (peer < 0) {
        return -1;
    }
    if (connect(
            peer,
            (const struct sockaddr *)&address,
            address_length) != 0) {
        int saved_errno = errno;
        (void)close(peer);
        errno = saved_errno;
        return -1;
    }
    int filesystem_context = collider_fsopen("bpf", FSOPEN_CLOEXEC);
    if (filesystem_context < 0) {
        int saved_errno = errno;
        (void)close(peer);
        errno = saved_errno;
        return -1;
    }
    if (collider_android_bpf_send_context(
            peer, filesystem_context) != 0) {
        int saved_errno = errno;
        (void)close(filesystem_context);
        (void)close(peer);
        errno = saved_errno;
        return -1;
    }

    int32_t status;
    if (collider_android_bpf_receive_status(peer, &status) != 0) {
        int saved_errno = errno;
        (void)close(filesystem_context);
        (void)close(peer);
        errno = saved_errno;
        return -1;
    }
    if (status != 0) {
        (void)close(filesystem_context);
        (void)close(peer);
        errno = status < 0 ? -status : EPROTO;
        return -1;
    }
    int mount_descriptor = collider_fsmount(
        filesystem_context, FSMOUNT_CLOEXEC, 0);
    if (mount_descriptor < 0) {
        int saved_errno = errno;
        (void)close(filesystem_context);
        (void)close(peer);
        errno = saved_errno;
        return -1;
    }
    if (mkdir(target_path, 0755) != 0 && errno != EEXIST) {
        int saved_errno = errno;
        (void)close(mount_descriptor);
        (void)close(filesystem_context);
        (void)close(peer);
        errno = saved_errno;
        return -1;
    }
    int result = collider_move_mount(
        mount_descriptor,
        "",
        AT_FDCWD,
        target_path,
        MOVE_MOUNT_F_EMPTY_PATH);
    int saved_errno = result == 0 ? 0 : errno;
    if (close(mount_descriptor) != 0 && result == 0) {
        result = -1;
        saved_errno = errno;
    }
    if (close(filesystem_context) != 0 && result == 0) {
        result = -1;
        saved_errno = errno;
    }
    if (close(peer) != 0 && result == 0) {
        result = -1;
        saved_errno = errno;
    }
    errno = saved_errno;
    return result;
#else
    (void)socket_path;
    (void)target_path;
    errno = ENOTSUP;
    return -1;
#endif
}

char *collider_copy_loaded_library_path(const char *symbol) {
#if defined(__linux__)
    if (symbol == NULL || symbol[0] == '\0') {
        errno = EINVAL;
        return NULL;
    }
    (void)dlerror();
    void *address = dlsym(RTLD_DEFAULT, symbol);
    const char *symbol_error = dlerror();
    if (symbol_error != NULL || address == NULL) {
        errno = ENOENT;
        return NULL;
    }
    Dl_info information = {0};
    if (dladdr(address, &information) == 0
        || information.dli_fname == NULL
        || information.dli_fname[0] != '/') {
        errno = ENOENT;
        return NULL;
    }
    return strdup(information.dli_fname);
#else
    (void)symbol;
    errno = ENOTSUP;
    return NULL;
#endif
}
