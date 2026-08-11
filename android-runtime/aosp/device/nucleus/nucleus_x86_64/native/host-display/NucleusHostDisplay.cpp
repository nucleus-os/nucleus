#include <android/hardware_buffer.h>
#include <android/log.h>
#include <android/native_window_jni.h>
#include <jni.h>
#include <media/NdkImage.h>
#include <media/NdkImageReader.h>
#include <sys/socket.h>
#include <unistd.h>

#include <atomic>
#include <cerrno>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <optional>
#include <thread>

#include "NucleusAndroidDisplayControlProtocol.h"
#include "NucleusAndroidPresentationProtocol.h"
#include "NucleusGrallocHandle.h"
#include "NucleusIPCTransportC.h"
#include "vndk/hardware_buffer.h"

namespace {

constexpr const char* kTag = "NucleusHostDisplay";
constexpr const char* kControlSocket =
    "/dev/nucleus-runtime/display-control.sock";
constexpr const char* kPresentationSocket =
    "/dev/nucleus-runtime/presentation.sock";
constexpr int32_t kMaximumImages = 4;

void logFailure(const char* operation) {
    __android_log_print(
        ANDROID_LOG_ERROR, kTag, "%s failed: %s", operation, strerror(errno));
}

class Controller {
  public:
    explicit Controller(uint64_t presentation_id)
        : presentation_id_(presentation_id) {
        control_socket_ = nucleus_ipc_connect(kControlSocket);
        if (control_socket_ < 0) {
            logFailure("connecting display-control transport");
            return;
        }
        nucleus_android_display_control_register request = {
            .operation = NUCLEUS_ANDROID_DISPLAY_CONTROL_REGISTER,
            .byte_count = sizeof(request),
            .fd_count = 0,
            .presentation_id = presentation_id_,
        };
        if (nucleus_ipc_send(
                control_socket_, &request, sizeof(request), nullptr, 0) != 0) {
            logFailure("registering host display");
            return;
        }
        size_t descriptor_count = 0;
        const int received = nucleus_ipc_receive(
            control_socket_,
            &configuration_,
            sizeof(configuration_),
            nullptr,
            0,
            &descriptor_count);
        if (!validConfiguration(
                configuration_,
                NUCLEUS_ANDROID_DISPLAY_CONTROL_CONFIGURE,
                received,
                descriptor_count)) {
            errno = EPROTO;
            logFailure("receiving initial host-display configuration");
            return;
        }
        if (!createReader(configuration_.width, configuration_.height)) {
            return;
        }
        generation_.store(configuration_.generation);
        frame_thread_ = std::thread([this] { frameLoop(); });
        valid_ = true;
    }

    ~Controller() {
        stopping_.store(true);
        if (reader_ != nullptr) {
            AImageReader_setImageListener(reader_, nullptr);
        }
        if (control_socket_ >= 0) {
            shutdown(control_socket_, SHUT_RDWR);
        }
        if (presentation_socket_ >= 0) {
            shutdown(presentation_socket_, SHUT_RDWR);
        }
        frame_condition_.notify_all();
        if (control_thread_.joinable()) control_thread_.join();
        if (frame_thread_.joinable()) frame_thread_.join();
        {
            std::lock_guard<std::mutex> lock(frame_mutex_);
            if (pending_frame_) {
                AImage_deleteAsync(
                    pending_frame_->image, pending_frame_->acquire_fence);
                pending_frame_.reset();
            }
        }
        if (reader_ != nullptr) AImageReader_delete(reader_);
        if (control_socket_ >= 0) close(control_socket_);
        if (presentation_socket_ >= 0) close(presentation_socket_);
        if (java_vm_ != nullptr && callback_ != nullptr) {
            JNIEnv* environment = nullptr;
            bool attached = false;
            if (java_vm_->GetEnv(
                    reinterpret_cast<void**>(&environment),
                    JNI_VERSION_1_6) != JNI_OK) {
                attached = java_vm_->AttachCurrentThread(&environment, nullptr)
                        == JNI_OK;
            }
            if (environment != nullptr) {
                environment->DeleteGlobalRef(callback_);
            }
            if (attached) java_vm_->DetachCurrentThread();
        }
    }

    bool valid() const { return valid_; }

    const nucleus_android_display_control_configuration& configuration()
            const {
        return configuration_;
    }

    jobject surface(JNIEnv* environment) {
        ANativeWindow* window = nullptr;
        if (reader_ == nullptr
                || AImageReader_getWindow(reader_, &window) != AMEDIA_OK
                || window == nullptr) {
            return nullptr;
        }
        return ANativeWindow_toSurface(environment, window);
    }

    bool start(JNIEnv* environment, jobject callback) {
        if (java_vm_ != nullptr
                || environment->GetJavaVM(&java_vm_) != JNI_OK) {
            return false;
        }
        callback_ = environment->NewGlobalRef(callback);
        jclass type = environment->GetObjectClass(callback);
        configuration_method_ = environment->GetMethodID(
            type, "onHostDisplayConfiguration", "(JIIII)V");
        environment->DeleteLocalRef(type);
        if (callback_ == nullptr || configuration_method_ == nullptr) {
            return false;
        }
        control_thread_ = std::thread([this] { controlLoop(); });
        return true;
    }

    bool apply(
            uint64_t generation,
            int32_t width,
            int32_t height) {
        if (generation == 0 || width <= 0 || height <= 0) {
            errno = EINVAL;
            return false;
        }
        ANativeWindow* window = nullptr;
        if (reader_ == nullptr
                || AImageReader_getWindow(reader_, &window) != AMEDIA_OK
                || window == nullptr
                || ANativeWindow_setBuffersGeometry(
                        window, width, height, 0) != 0) {
            errno = EIO;
            return false;
        }
        generation_.store(generation);
        return true;
    }

  private:
    struct PendingFrame {
        AImage* image;
        int acquire_fence;
    };

    static bool validConfiguration(
            const nucleus_android_display_control_configuration& configuration,
            uint32_t operation,
            int received,
            size_t descriptor_count) {
        return received == sizeof(configuration)
                && configuration.operation == operation
                && configuration.byte_count == sizeof(configuration)
                && configuration.fd_count == 0
                && descriptor_count == 0
                && configuration.generation > 0
                && configuration.width > 0
                && configuration.height > 0
                && configuration.density_dpi > 0
                && configuration.refresh_millihertz > 0;
    }

    bool createReader(int32_t width, int32_t height) {
        const media_status_t status = AImageReader_newWithUsage(
            width,
            height,
            AIMAGE_FORMAT_RGBX_8888,
            AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE,
            kMaximumImages,
            &reader_);
        if (status != AMEDIA_OK || reader_ == nullptr) {
            __android_log_print(
                ANDROID_LOG_ERROR,
                kTag,
                "creating host-display reader failed: status=%d",
                status);
            return false;
        }
        AImageReader_ImageListener listener = {
            .context = this,
            .onImageAvailable = imageAvailable,
        };
        return AImageReader_setImageListener(reader_, &listener) == AMEDIA_OK;
    }

    static void imageAvailable(void* context, AImageReader* reader) {
        static_cast<Controller*>(context)->acquireLatest(reader);
    }

    void acquireLatest(AImageReader* reader) {
        AImage* image = nullptr;
        int acquire_fence = -1;
        const media_status_t status =
                AImageReader_acquireLatestImageAsync(
                    reader, &image, &acquire_fence);
        if (status == AMEDIA_IMGREADER_NO_BUFFER_AVAILABLE) return;
        if (status != AMEDIA_OK || image == nullptr) {
            if (acquire_fence >= 0) close(acquire_fence);
            return;
        }
        std::optional<PendingFrame> replaced;
        {
            std::lock_guard<std::mutex> lock(frame_mutex_);
            if (stopping_.load()) {
                AImage_deleteAsync(image, acquire_fence);
                return;
            }
            replaced = pending_frame_;
            pending_frame_ = PendingFrame{image, acquire_fence};
        }
        if (replaced) {
            AImage_deleteAsync(replaced->image, replaced->acquire_fence);
        }
        frame_condition_.notify_one();
    }

    void controlLoop() {
        JNIEnv* environment = nullptr;
        if (java_vm_->AttachCurrentThread(&environment, nullptr) != JNI_OK) {
            return;
        }
        while (!stopping_.load()) {
            nucleus_android_display_control_configuration configuration = {};
            size_t descriptor_count = 0;
            const int received = nucleus_ipc_receive(
                control_socket_,
                &configuration,
                sizeof(configuration),
                nullptr,
                0,
                &descriptor_count);
            if (!validConfiguration(
                    configuration,
                    NUCLEUS_ANDROID_DISPLAY_CONTROL_RESIZE,
                    received,
                    descriptor_count)) {
                if (!stopping_.load()) {
                    __android_log_print(
                        ANDROID_LOG_ERROR,
                        kTag,
                        "invalid host-display resize packet");
                }
                break;
            }
            environment->CallVoidMethod(
                callback_,
                configuration_method_,
                static_cast<jlong>(configuration.generation),
                static_cast<jint>(configuration.width),
                static_cast<jint>(configuration.height),
                static_cast<jint>(configuration.density_dpi),
                static_cast<jint>(configuration.refresh_millihertz));
            if (environment->ExceptionCheck()) {
                environment->ExceptionDescribe();
                environment->ExceptionClear();
                break;
            }
        }
        java_vm_->DetachCurrentThread();
    }

    bool connectPresentation() {
        if (presentation_socket_ >= 0) return true;
        presentation_socket_ = nucleus_ipc_connect(kPresentationSocket);
        if (presentation_socket_ < 0) {
            logFailure("connecting presentation transport");
            return false;
        }
        return true;
    }

    void frameLoop() {
        while (true) {
            std::optional<PendingFrame> frame;
            {
                std::unique_lock<std::mutex> lock(frame_mutex_);
                frame_condition_.wait(lock, [this] {
                    return stopping_.load() || pending_frame_.has_value();
                });
                if (stopping_.load()) {
                    frame = pending_frame_;
                    pending_frame_.reset();
                    lock.unlock();
                    if (frame) {
                        AImage_deleteAsync(
                            frame->image, frame->acquire_fence);
                    }
                    return;
                }
                frame = pending_frame_;
                pending_frame_.reset();
            }
            present(*frame);
        }
    }

    void present(PendingFrame frame) {
        AHardwareBuffer* hardware_buffer = nullptr;
        if (AImage_getHardwareBuffer(frame.image, &hardware_buffer)
                        != AMEDIA_OK
                || hardware_buffer == nullptr
                || !connectPresentation()) {
            AImage_deleteAsync(frame.image, frame.acquire_fence);
            return;
        }
        const auto* handle = nucleus_gralloc_handle_cast(
            AHardwareBuffer_getNativeHandle(hardware_buffer));
        if (handle == nullptr) {
            AImage_deleteAsync(frame.image, frame.acquire_fence);
            return;
        }
        const uint64_t request_id = next_request_id_++;
        nucleus_android_presentation_frame request = {
            .operation = NUCLEUS_ANDROID_PRESENTATION_PRESENT,
            .byte_count = sizeof(request),
            .fd_count =
                static_cast<uint32_t>(frame.acquire_fence >= 0 ? 3 : 2),
            .request_id = request_id,
            .presentation_id = presentation_id_,
            .configuration_generation = generation_.load(),
            .allocation_id = handle->allocation_id,
            .frame_number = next_frame_number_++,
            .drm_modifier = handle->drm_modifier,
            .allocation_size = handle->allocation_size,
            .width = handle->width,
            .height = handle->height,
            .drm_format = handle->drm_format,
            .plane_offset = handle->plane_offset,
            .plane_stride = handle->plane_stride,
            .damage_left = 0,
            .damage_top = 0,
            .damage_right = static_cast<int32_t>(handle->width),
            .damage_bottom = static_cast<int32_t>(handle->height),
            .android_display_id = 0,
            .has_acquire_fence = frame.acquire_fence >= 0 ? 1u : 0u,
        };
        int descriptors[3] = {
            handle->dmabuf_fd,
            handle->lifetime_fd,
            frame.acquire_fence,
        };
        if (nucleus_ipc_send(
                presentation_socket_,
                &request,
                sizeof(request),
                descriptors,
                request.fd_count) != 0) {
            close(presentation_socket_);
            presentation_socket_ = -1;
            AImage_deleteAsync(frame.image, frame.acquire_fence);
            return;
        }
        if (frame.acquire_fence >= 0) close(frame.acquire_fence);

        nucleus_android_presentation_frame_reply reply = {};
        int release_fence = -1;
        size_t descriptor_count = 0;
        const int received = nucleus_ipc_receive(
            presentation_socket_,
            &reply,
            sizeof(reply),
            &release_fence,
            1,
            &descriptor_count);
        if (received != sizeof(reply)
                || reply.operation != NUCLEUS_ANDROID_PRESENTATION_PRESENT
                || reply.byte_count != sizeof(reply)
                || reply.fd_count != 1
                || reply.request_id != request_id
                || reply.status != NUCLEUS_ANDROID_PRESENTATION_STATUS_OK
                || descriptor_count != 1) {
            if (release_fence >= 0) close(release_fence);
            close(presentation_socket_);
            presentation_socket_ = -1;
            AImage_delete(frame.image);
            return;
        }
        AImage_deleteAsync(frame.image, release_fence);
    }

    const uint64_t presentation_id_;
    bool valid_ = false;
    std::atomic<bool> stopping_{false};
    std::atomic<uint64_t> generation_{0};
    nucleus_android_display_control_configuration configuration_ = {};
    AImageReader* reader_ = nullptr;
    int control_socket_ = -1;
    int presentation_socket_ = -1;
    JavaVM* java_vm_ = nullptr;
    jobject callback_ = nullptr;
    jmethodID configuration_method_ = nullptr;
    std::thread control_thread_;
    std::thread frame_thread_;
    std::mutex frame_mutex_;
    std::condition_variable frame_condition_;
    std::optional<PendingFrame> pending_frame_;
    uint64_t next_request_id_ = 1;
    uint64_t next_frame_number_ = 1;
};

Controller* fromHandle(jlong handle) {
    return reinterpret_cast<Controller*>(static_cast<uintptr_t>(handle));
}

void throwIllegalState(JNIEnv* environment, const char* message) {
    jclass type = environment->FindClass("java/lang/IllegalStateException");
    if (type != nullptr) environment->ThrowNew(type, message);
}

}  // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_com_android_server_display_NucleusHostDisplayAdapter_nativeCreate(
        JNIEnv*, jclass, jlong presentation_id) {
    auto* controller =
            new Controller(static_cast<uint64_t>(presentation_id));
    if (!controller->valid()) {
        delete controller;
        return 0;
    }
    return static_cast<jlong>(reinterpret_cast<uintptr_t>(controller));
}

extern "C" JNIEXPORT jlongArray JNICALL
Java_com_android_server_display_NucleusHostDisplayAdapter_nativeGetInitialConfiguration(
        JNIEnv* environment, jclass, jlong handle) {
    Controller* controller = fromHandle(handle);
    if (controller == nullptr) return nullptr;
    const auto& configuration = controller->configuration();
    const jlong values[5] = {
        static_cast<jlong>(configuration.generation),
        static_cast<jlong>(configuration.width),
        static_cast<jlong>(configuration.height),
        static_cast<jlong>(configuration.density_dpi),
        static_cast<jlong>(configuration.refresh_millihertz),
    };
    jlongArray result = environment->NewLongArray(5);
    if (result != nullptr) {
        environment->SetLongArrayRegion(result, 0, 5, values);
    }
    return result;
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_android_server_display_NucleusHostDisplayAdapter_nativeGetSurface(
        JNIEnv* environment, jclass, jlong handle) {
    Controller* controller = fromHandle(handle);
    return controller == nullptr ? nullptr : controller->surface(environment);
}

extern "C" JNIEXPORT void JNICALL
Java_com_android_server_display_NucleusHostDisplayAdapter_nativeStart(
        JNIEnv* environment, jclass, jlong handle, jobject callback) {
    Controller* controller = fromHandle(handle);
    if (controller == nullptr || !controller->start(environment, callback)) {
        throwIllegalState(environment, "starting host-display control failed");
    }
}

extern "C" JNIEXPORT void JNICALL
Java_com_android_server_display_NucleusHostDisplayAdapter_nativeApplyConfiguration(
        JNIEnv* environment,
        jclass,
        jlong handle,
        jlong generation,
        jint width,
        jint height) {
    Controller* controller = fromHandle(handle);
    if (controller == nullptr
            || !controller->apply(
                    static_cast<uint64_t>(generation), width, height)) {
        throwIllegalState(environment, "applying host-display resize failed");
    }
}

extern "C" JNIEXPORT void JNICALL
Java_com_android_server_display_NucleusHostDisplayAdapter_nativeDestroy(
        JNIEnv*, jclass, jlong handle) {
    delete fromHandle(handle);
}
