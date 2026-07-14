#include "nucleus_android_jni.h"

#include <jni.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>
#include <android/asset_manager.h>
#include <android/asset_manager_jni.h>

const char *nucleus_jni_get_string_utf_chars(void *env, void *value) {
    JNIEnv *e = (JNIEnv *)env;
    if (e == 0 || value == 0) {
        return 0;
    }
    return (*e)->GetStringUTFChars(e, (jstring)value, 0);
}

void nucleus_jni_release_string_utf_chars(void *env, void *value, const char *chars) {
    JNIEnv *e = (JNIEnv *)env;
    if (e == 0 || value == 0 || chars == 0) {
        return;
    }
    (*e)->ReleaseStringUTFChars(e, (jstring)value, chars);
}

void *nucleus_android_window_from_surface(void *env, void *surface) {
    if (env == 0 || surface == 0) {
        return 0;
    }
    return ANativeWindow_fromSurface((JNIEnv *)env, (jobject)surface);
}

void nucleus_android_window_release(void *window) {
    if (window) {
        ANativeWindow_release((ANativeWindow *)window);
    }
}

int32_t nucleus_android_window_get_width(void *window) {
    return ANativeWindow_getWidth((ANativeWindow *)window);
}

int32_t nucleus_android_window_get_height(void *window) {
    return ANativeWindow_getHeight((ANativeWindow *)window);
}

int32_t nucleus_android_window_get_format(void *window) {
    return ANativeWindow_getFormat((ANativeWindow *)window);
}


void *nucleus_android_asset_manager_from_java(void *env, void *asset_manager) {
    if (env == 0 || asset_manager == 0) {
        return 0;
    }
    return AAssetManager_fromJava((JNIEnv *)env, (jobject)asset_manager);
}

void *nucleus_android_asset_open(void *manager, const char *filename, int32_t mode) {
    return AAssetManager_open((AAssetManager *)manager, filename, mode);
}

void nucleus_android_asset_close(void *asset) {
    if (asset) {
        AAsset_close((AAsset *)asset);
    }
}

int64_t nucleus_android_asset_get_length64(void *asset) {
    return AAsset_getLength64((AAsset *)asset);
}

int32_t nucleus_android_asset_read(void *asset, void *buffer, size_t count) {
    return AAsset_read((AAsset *)asset, buffer, count);
}
