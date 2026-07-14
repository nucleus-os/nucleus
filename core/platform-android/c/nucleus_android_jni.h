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
