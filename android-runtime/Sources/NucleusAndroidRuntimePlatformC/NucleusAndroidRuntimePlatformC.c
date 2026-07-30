#define _GNU_SOURCE
#include "NucleusAndroidRuntimePlatformC.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

extern char **environ;

#if defined(__linux__)
#include <linux/android/binderfs.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#endif

int32_t nucleus_android_runtime_open_raw_pseudo_terminal(
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

int32_t nucleus_android_runtime_binderfs_add_device(
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

int32_t nucleus_android_runtime_pidfd_open(int32_t process_identifier) {
#if defined(__linux__) && defined(SYS_pidfd_open)
    if (process_identifier <= 0) {
        errno = EINVAL;
        return -1;
    }
    return (int32_t)syscall(SYS_pidfd_open, process_identifier, 0U);
#else
    (void)process_identifier;
    errno = ENOTSUP;
    return -1;
#endif
}

int32_t nucleus_android_runtime_pidfd_wait(
    int32_t descriptor,
    int32_t timeout_milliseconds) {
#if defined(__linux__)
    if (descriptor < 0 || timeout_milliseconds < 0) {
        errno = EINVAL;
        return -1;
    }
    struct pollfd poll_descriptor = {
        .fd = descriptor,
        .events = POLLIN,
        .revents = 0,
    };
    int result;
    do {
        result = poll(&poll_descriptor, 1U, timeout_milliseconds);
    } while (result < 0 && errno == EINTR);
    if (result <= 0) {
        return result;
    }
    return (poll_descriptor.revents & (POLLIN | POLLHUP | POLLERR)) != 0
        ? 1
        : 0;
#else
    (void)descriptor;
    (void)timeout_milliseconds;
    errno = ENOTSUP;
    return -1;
#endif
}

static int32_t nucleus_android_runtime_spawn_process(
    const char *executable,
    char *const arguments[],
    int32_t *process_identifier) {
#if defined(__linux__) && defined(__GLIBC__)
    if (executable == NULL || arguments == NULL || arguments[0] == NULL
        || process_identifier == NULL) {
        errno = EINVAL;
        return -1;
    }

    posix_spawn_file_actions_t actions;
    int error = posix_spawn_file_actions_init(&actions);
    if (error != 0) {
        errno = error;
        return -1;
    }
    error = posix_spawn_file_actions_addclosefrom_np(
        &actions, STDERR_FILENO + 1);
    if (error != 0) {
        (void)posix_spawn_file_actions_destroy(&actions);
        errno = error;
        return -1;
    }

    posix_spawnattr_t attributes;
    error = posix_spawnattr_init(&attributes);
    if (error != 0) {
        (void)posix_spawn_file_actions_destroy(&actions);
        errno = error;
        return -1;
    }

    sigset_t empty_mask;
    sigset_t default_signals;
    if (sigemptyset(&empty_mask) != 0
        || sigemptyset(&default_signals) != 0
        || sigaddset(&default_signals, SIGHUP) != 0
        || sigaddset(&default_signals, SIGINT) != 0
        || sigaddset(&default_signals, SIGQUIT) != 0
        || sigaddset(&default_signals, SIGPIPE) != 0
        || sigaddset(&default_signals, SIGTERM) != 0
        || sigaddset(&default_signals, SIGCHLD) != 0) {
        int saved_errno = errno;
        (void)posix_spawnattr_destroy(&attributes);
        (void)posix_spawn_file_actions_destroy(&actions);
        errno = saved_errno;
        return -1;
    }

    error = posix_spawnattr_setsigmask(&attributes, &empty_mask);
    if (error == 0) {
        error = posix_spawnattr_setsigdefault(
            &attributes, &default_signals);
    }
    if (error == 0) {
        error = posix_spawnattr_setflags(
            &attributes,
            POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF);
    }
    if (error != 0) {
        (void)posix_spawnattr_destroy(&attributes);
        (void)posix_spawn_file_actions_destroy(&actions);
        errno = error;
        return -1;
    }

    pid_t child = 0;
    error = posix_spawn(
        &child,
        executable,
        &actions,
        &attributes,
        arguments,
        environ);
    (void)posix_spawnattr_destroy(&attributes);
    (void)posix_spawn_file_actions_destroy(&actions);
    if (error != 0) {
        errno = error;
        return -1;
    }
    *process_identifier = (int32_t)child;
    return 0;
#else
    (void)executable;
    (void)arguments;
    (void)process_identifier;
    errno = ENOTSUP;
    return -1;
#endif
}

static int32_t nucleus_android_runtime_decode_process_status(int status) {
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    if (WIFSIGNALED(status)) {
        return 128 + WTERMSIG(status);
    }
    return -1;
}

static int32_t nucleus_android_runtime_poll_process(
    int32_t process_identifier,
    int32_t *exit_status) {
    if (process_identifier <= 0 || exit_status == NULL) {
        errno = EINVAL;
        return -1;
    }
    int status = 0;
    pid_t result;
    do {
        result = waitpid((pid_t)process_identifier, &status, WNOHANG);
    } while (result < 0 && errno == EINTR);
    if (result <= 0) {
        return (int32_t)result;
    }
    *exit_status = nucleus_android_runtime_decode_process_status(status);
    return 1;
}

static int32_t nucleus_android_runtime_wait_process(
    int32_t process_identifier,
    int32_t *exit_status) {
    if (process_identifier <= 0 || exit_status == NULL) {
        errno = EINVAL;
        return -1;
    }
    int status = 0;
    pid_t result;
    do {
        result = waitpid((pid_t)process_identifier, &status, 0);
    } while (result < 0 && errno == EINTR);
    if (result < 0) {
        return -1;
    }
    *exit_status = nucleus_android_runtime_decode_process_status(status);
    return 0;
}

int32_t nucleus_android_runtime_spawn_container_launcher(
    const char *container_name,
    const char *configuration,
    const char *log_file) {
    if (container_name == NULL || configuration == NULL || log_file == NULL) {
        errno = EINVAL;
        return -1;
    }
    char *arguments[] = {
        (char *)"/usr/bin/systemd-run",
        (char *)"--scope",
        (char *)"--quiet",
        (char *)"--collect",
        (char *)"--unit",
        (char *)container_name,
        (char *)"--property",
        (char *)"Delegate=yes",
        (char *)"--",
        (char *)"/usr/bin/lxc-start",
        (char *)"--foreground",
        (char *)"--name",
        (char *)container_name,
        (char *)"--rcfile",
        (char *)configuration,
        (char *)"--logfile",
        (char *)log_file,
        (char *)"--logpriority",
        (char *)"TRACE",
        NULL,
    };
    int32_t process_identifier = 0;
    if (nucleus_android_runtime_spawn_process(
            arguments[0], arguments, &process_identifier) != 0) {
        return -1;
    }
    return process_identifier;
}

int32_t nucleus_android_runtime_poll_process_status(
    int32_t process_identifier) {
    int32_t exit_status = 0;
    int32_t result = nucleus_android_runtime_poll_process(
        process_identifier, &exit_status);
    if (result <= 0) {
        return result;
    }
    return exit_status + 1;
}

int32_t nucleus_android_runtime_wait_process_status(
    int32_t process_identifier) {
    int32_t exit_status = 0;
    if (nucleus_android_runtime_wait_process(
            process_identifier, &exit_status) != 0) {
        return -1;
    }
    return exit_status;
}

int32_t nucleus_android_runtime_stop_container(
    const char *container_name) {
    if (container_name == NULL) {
        errno = EINVAL;
        return -1;
    }
    char *arguments[] = {
        (char *)"/usr/bin/lxc-stop",
        (char *)"--kill",
        (char *)"--name",
        (char *)container_name,
        NULL,
    };
    int32_t process_identifier = 0;
    if (nucleus_android_runtime_spawn_process(
            arguments[0], arguments, &process_identifier) != 0) {
        return -1;
    }
    return nucleus_android_runtime_wait_process_status(process_identifier);
}
