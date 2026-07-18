#ifndef NUCLEUS_SHELL_PAM_C_H
#define NUCLEUS_SHELL_PAM_C_H

#include <errno.h>
#include <pwd.h>
#include <security/pam_appl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

// `pam_conv.conv` is a function pointer taking `const struct pam_message **`.
// Swift imports the double pointer awkwardly, and the response array must be
// allocated with malloc because PAM frees it. Both are easier to get right in C.
//
// The reply buffer is filled by the Swift side through this setter, one entry at
// a time, so no pointer arithmetic on a malloc'd array happens in Swift.
static inline struct pam_response *nucleus_pam_alloc_responses(int count) {
    if (count <= 0) { return NULL; }
    return (struct pam_response *)calloc((size_t)count, sizeof(struct pam_response));
}

static inline int nucleus_pam_message_style(const struct pam_message **msgs, int index) {
    if (msgs == NULL || msgs[index] == NULL) { return -1; }
    return msgs[index]->msg_style;
}

// strdup so PAM owns the copy and frees it with the response array.
static inline int nucleus_pam_set_response(struct pam_response *responses, int index,
                                           const char *value) {
    if (responses == NULL) { return -1; }
    char *copy = strdup(value != NULL ? value : "");
    if (copy == NULL) { return -1; }
    responses[index].resp = copy;
    responses[index].resp_retcode = 0;
    return 0;
}

static inline void nucleus_pam_free_responses(struct pam_response *responses, int count) {
    if (responses == NULL) { return; }
    for (int i = 0; i < count; ++i) {
        if (responses[i].resp != NULL) { free(responses[i].resp); }
    }
    free(responses);
}

// The login name for the real uid. getpwuid_r's retry-on-ERANGE loop is
// mechanical and clearer in C than through the Swift importer.
static inline int nucleus_pam_current_username(char *out, size_t out_size) {
    if (out == NULL || out_size == 0) { return -1; }
    uid_t uid = getuid();
    size_t size = 4096;
    for (;;) {
        char *buf = (char *)malloc(size);
        if (buf == NULL) { return -1; }
        struct passwd pwd;
        struct passwd *result = NULL;
        int rc = getpwuid_r(uid, &pwd, buf, size, &result);
        if (rc == 0 && result != NULL && result->pw_name != NULL) {
            size_t len = strlen(result->pw_name);
            if (len + 1 > out_size) { free(buf); return -1; }
            memcpy(out, result->pw_name, len + 1);
            free(buf);
            return 0;
        }
        free(buf);
        if (rc != ERANGE) { return -1; }
        size *= 2;
        if (size > (1u << 20)) { return -1; }
    }
}

static inline void nucleus_pam_scrub(void *ptr, size_t len) {
    if (ptr != NULL && len > 0) { explicit_bzero(ptr, len); }
}

#endif
