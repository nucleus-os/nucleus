// First-party C façade for the Android JNI + NDK boundary.
//
// All JNI (JNIEnv / jstring) and NDK (ANativeWindow / AAssetManager) mechanics are
// confined here, behind plain-C functions over `void*` opaque handles and
// fixed-width scalars. The Swift Android host (platform-android/swift/*) owns every
// runtime fact and the `Java_dev_nucleus_android_*` JNI entry points; it reaches
// the platform only through these wrappers, never raw jni.h / NDK types.
#ifndef NUCLEUS_ANDROID_JNI_H
#define NUCLEUS_ANDROID_JNI_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// JNI string marshalling. `env`/`value` are the opaque JNIEnv*/jstring handed to a
// native method. Returns a NUL-terminated UTF-8 view owned by the JVM until release.
const char *nucleus_jni_get_string_utf_chars(void *env, void *value);
void nucleus_jni_release_string_utf_chars(void *env, void *value, const char *chars);

// ANativeWindow: acquire from a Surface jobject, query geometry, and software-render.
void *nucleus_android_window_from_surface(void *env, void *surface);
void nucleus_android_window_release(void *window);
int32_t nucleus_android_window_get_width(void *window);
int32_t nucleus_android_window_get_height(void *window);
int32_t nucleus_android_window_get_format(void *window);

// Vulkan Android WSI. Keep the platform-only ABI behind opaque pointers so the
// Android host core remains type-checkable by Linux host-side tests without
// importing Android-gated Vulkan declarations.
typedef int32_t (*nucleus_vk_create_android_surface_fn)(
    void *instance,
    const void *create_info,
    const void *allocator,
    void **surface);

struct nucleus_vk_android_surface_create_info {
    int32_t s_type;
    const void *p_next;
    uint32_t flags;
    void *window;
};

static inline int32_t nucleus_vk_create_android_surface(
    void *function,
    void *instance,
    void *window,
    void **surface) {
    struct nucleus_vk_android_surface_create_info info = {
        .s_type = 1000008000,
        .p_next = 0,
        .flags = 0,
        .window = window,
    };
    return ((nucleus_vk_create_android_surface_fn)function)(
        instance, &info, 0, surface);
}

// Owner-thread identity and directed diagnostics for the Swift host boundary.
int64_t nucleus_android_current_thread_id(void);
void nucleus_android_log_thread_violation(const char *operation);

// AAssetManager + AAsset.
void *nucleus_android_asset_manager_from_java(void *env, void *asset_manager);
void *nucleus_android_asset_open(void *manager, const char *filename, int32_t mode);
void nucleus_android_asset_close(void *asset);
int64_t nucleus_android_asset_get_length64(void *asset);
int32_t nucleus_android_asset_read(void *asset, void *buffer, size_t count);

#ifdef __cplusplus
}
#endif

#endif // NUCLEUS_ANDROID_JNI_H
