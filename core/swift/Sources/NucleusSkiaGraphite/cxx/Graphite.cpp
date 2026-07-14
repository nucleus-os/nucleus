// NucleusSkiaGraphite façade implementation. All Skia/Vulkan types stay here.

#include "NucleusSkiaGraphite/Graphite.hpp"

#include <algorithm>
#include <atomic>
#include <cstring>
#include <mutex>
#include <unordered_map>

#include <vulkan/vulkan_core.h>

#include "modules/skparagraph/include/Paragraph.h"

#include "include/core/SkCanvas.h"
#include "include/core/SkColor.h"
#include "include/core/SkColorFilter.h"
#include "include/core/SkData.h"
#include "include/core/SkImage.h"
#include "include/core/SkImageInfo.h"
#include "include/core/SkPaint.h"
#include "include/core/SkPath.h"
#include "include/core/SkPathBuilder.h"
#include "include/core/SkPixmap.h"
#include "include/core/SkPoint.h"
#include "include/core/SkRRect.h"
#include "include/core/SkRect.h"
#include "include/core/SkRefCnt.h"
#include "include/core/SkSamplingOptions.h"
#include "include/core/SkSize.h"
#include "include/core/SkString.h"
#include "include/core/SkSurface.h"
#include "include/gpu/graphite/BackendSemaphore.h"
#include "include/gpu/graphite/BackendTexture.h"
#include "include/gpu/graphite/Image.h"
#include "include/gpu/MutableTextureState.h"
#include "include/gpu/vk/VulkanMutableTextureState.h"
#include "include/effects/SkColorMatrix.h"
#include "include/effects/SkImageFilters.h"
#include "include/effects/SkRuntimeEffect.h"
#include "include/private/SkTPin.h"
#include "include/gpu/graphite/Context.h"
#include "include/gpu/graphite/ContextOptions.h"
#include "include/gpu/graphite/Recorder.h"
#include "include/gpu/graphite/Recording.h"
#include "include/gpu/graphite/Surface.h"
#include "include/gpu/graphite/vk/VulkanGraphiteContext.h"
#include "include/gpu/graphite/vk/VulkanGraphiteTypes.h"
#include "include/gpu/vk/VulkanBackendContext.h"
#include "include/gpu/vk/VulkanExtensions.h"
#include "include/gpu/vk/VulkanMemoryAllocator.h"
#include "include/gpu/vk/VulkanTypes.h"
#include "src/gpu/GpuTypesPriv.h"
#include "src/gpu/vk/VulkanInterface.h"
#include "src/gpu/vk/vulkanmemoryallocator/VulkanAMDMemoryAllocator.h"

namespace nucleus::skia {

namespace {

struct SubmissionCompletionState {
    std::atomic<uint64_t> completedSerial{0};
    std::mutex mutex;
    std::unordered_map<uint64_t, uint64_t> gpuElapsedNs;
};

struct SubmissionCompletionToken {
    std::shared_ptr<SubmissionCompletionState> state;
    uint64_t serial;
};

void attachSubmissionCompletion(
    skgpu::graphite::InsertRecordingInfo &info,
    const std::shared_ptr<SubmissionCompletionState> &state,
    uint64_t serial) {
    if (serial == 0) return;
    info.fFinishedContext = new SubmissionCompletionToken{state, serial};
    info.fGpuStatsFlags = skgpu::GpuStatsFlags::kElapsedTime;
    info.fFinishedWithStatsProc = [](
        skgpu::graphite::GpuFinishedContext context,
        skgpu::CallbackResult result, const skgpu::GpuStats &stats) {
        std::unique_ptr<SubmissionCompletionToken> token(
            static_cast<SubmissionCompletionToken *>(context));
        if (result != skgpu::CallbackResult::kSuccess) return;
        if (stats.elapsedTime != 0) {
            std::lock_guard<std::mutex> lock(token->state->mutex);
            token->state->gpuElapsedNs[token->serial] = stats.elapsedTime;
        }
        uint64_t completed = token->state->completedSerial.load(std::memory_order_relaxed);
        while (completed < token->serial &&
               !token->state->completedSerial.compare_exchange_weak(
                   completed, token->serial,
                   std::memory_order_release, std::memory_order_relaxed)) {}
    };
}

// Text-layout resolver: installed by the text backend at startup via
// nucleus_skia_set_text_layout_resolver (see skia_text_backend.cpp). Given a
// handle it returns the borrowed skia::textlayout::Paragraph* (as uintptr_t, 0
// if unknown). The render core owns this seam and paints the paragraph itself;
// it has no compile-time dependency on the text backend.
using TextLayoutResolver = uintptr_t (*)(uint64_t);
TextLayoutResolver g_textLayoutResolver = nullptr;

skgpu::VulkanGetProc makeVulkanGetProc() {
    return [](const char *name, VkInstance instance, VkDevice device) -> PFN_vkVoidFunction {
        if (device != VK_NULL_HANDLE) {
            return vkGetDeviceProcAddr(device, name);
        }
        return vkGetInstanceProcAddr(instance, name);
    };
}

SkBlendMode toSkBlendMode(BlendMode mode) {
    switch (mode) {
        case BlendMode::srcOver: return SkBlendMode::kSrcOver;
        case BlendMode::src: return SkBlendMode::kSrc;
        case BlendMode::multiply: return SkBlendMode::kMultiply;
        case BlendMode::screen: return SkBlendMode::kScreen;
        case BlendMode::plus: return SkBlendMode::kPlus;
        case BlendMode::overlay: return SkBlendMode::kOverlay;
        case BlendMode::dstIn: return SkBlendMode::kDstIn;
        case BlendMode::dstOut: return SkBlendMode::kDstOut;
    }
    return SkBlendMode::kSrcOver;
}

SkRRect toSkRRect(RectF rect, RRectRadii radii) {
    const SkRect bounds = SkRect::MakeXYWH(rect.x, rect.y, rect.width, rect.height);
    const SkVector corners[4] = {
        {radii.topLeft, radii.topLeft},
        {radii.topRight, radii.topRight},
        {radii.bottomRight, radii.bottomRight},
        {radii.bottomLeft, radii.bottomLeft},
    };
    SkRRect rrect;
    rrect.setRectRadii(bounds, corners);
    return rrect;
}

/// Lower a façade `Paint` to an `SkPaint`, attaching the saturation color matrix
/// and Gaussian blur image filter when requested.
SkPaint toSkPaint(Paint paint) {
    SkPaint sk;
    sk.setColor(SkColor4f{paint.color.r, paint.color.g, paint.color.b, paint.color.a}, nullptr);
    sk.setAlphaf(SkTPin(paint.color.a * paint.alpha, 0.0f, 1.0f));
    sk.setBlendMode(toSkBlendMode(paint.blend));
    sk.setAntiAlias(paint.antialias);
    if (paint.saturation != 1.0f) {
        SkColorMatrix m;
        m.setSaturation(paint.saturation);
        sk.setColorFilter(SkColorFilters::Matrix(m));
    }
    if (paint.blurSigma > 0.0f) {
        sk.setImageFilter(SkImageFilters::Blur(paint.blurSigma, paint.blurSigma, nullptr));
    }
    return sk;
}

}  // namespace

// MARK: - Impl definitions

struct GraphiteContext::Impl {
    skgpu::VulkanExtensions extensions;
    sk_sp<skgpu::VulkanInterface> interface;
    sk_sp<skgpu::VulkanMemoryAllocator> allocator;
    std::unique_ptr<skgpu::graphite::Context> context;
    std::shared_ptr<SubmissionCompletionState> submissionCompletion =
        std::make_shared<SubmissionCompletionState>();
};

struct Recorder::Impl {
    std::shared_ptr<GraphiteContext::Impl> context;
    std::unique_ptr<skgpu::graphite::Recorder> recorder;
};

struct Surface::Impl {
    std::shared_ptr<Recorder::Impl> recorder;
    sk_sp<SkSurface> surface;
};

struct Canvas::Impl {
    std::shared_ptr<Surface::Impl> surface;
    SkCanvas *canvas = nullptr;  // owned by the surface
};

struct Image::Impl {
    sk_sp<SkImage> image;
    // Optional owner for images that wrap a facade-owned backend allocation.
    std::shared_ptr<void> owner;
};

struct UploadTexture::Impl {
    std::shared_ptr<GraphiteContext::Impl> context;
    std::shared_ptr<Recorder::Impl> recorder;
    skgpu::graphite::BackendTexture texture;
    sk_sp<SkImage> image;
    int32_t width = 0;
    int32_t height = 0;

    ~Impl() {
        image.reset();
        if (context && context->context && texture.isValid()) {
            context->context->deleteBackendTexture(texture);
        }
    }
};

struct Shader::Impl {
    sk_sp<SkShader> shader;
};

struct Recording::Impl {
    std::unique_ptr<skgpu::graphite::Recording> recording;
};

// MARK: - Image

Image::Image(std::shared_ptr<Impl> impl) : impl_(std::move(impl)) {}
bool Image::isValid() const { return impl_ && impl_->image != nullptr; }
int32_t Image::width() const { return isValid() ? impl_->image->width() : 0; }
int32_t Image::height() const { return isValid() ? impl_->image->height() : 0; }
Image::Impl *Image::raw() const { return impl_.get(); }

bool Image::readPixelsRGBA(uint8_t *dst, size_t byteLength, int32_t rowBytes) const {
    if (!isValid() || dst == nullptr) return false;
    SkImageInfo info = SkImageInfo::Make(
        impl_->image->width(), impl_->image->height(),
        kRGBA_8888_SkColorType, kPremul_SkAlphaType);
    const size_t stride = rowBytes > 0 ? static_cast<size_t>(rowBytes) : info.minRowBytes();
    if (byteLength < stride * static_cast<size_t>(info.height())) return false;
    return impl_->image->readPixels(nullptr, info, dst, stride, 0, 0);
}

// MARK: - UploadTexture

UploadTexture::UploadTexture(std::shared_ptr<Impl> impl) : impl_(std::move(impl)) {}
bool UploadTexture::isValid() const {
    return impl_ && impl_->texture.isValid() && impl_->image != nullptr;
}
int32_t UploadTexture::width() const { return isValid() ? impl_->width : 0; }
int32_t UploadTexture::height() const { return isValid() ? impl_->height : 0; }

bool UploadTexture::updateRGBA(const uint8_t *pixels, size_t byteLength) const {
    if (!isValid() || pixels == nullptr || !impl_->recorder || !impl_->recorder->recorder) {
        return false;
    }
    const SkImageInfo info = SkImageInfo::Make(
        impl_->width, impl_->height, kRGBA_8888_SkColorType, kPremul_SkAlphaType);
    if (byteLength < info.computeMinByteSize()) return false;
    const SkPixmap pixmap(info, pixels, info.minRowBytes());
    return impl_->recorder->recorder->updateBackendTexture(impl_->texture, &pixmap, 1);
}

Image UploadTexture::image() const {
    if (!isValid()) return Image(nullptr);
    auto image = std::make_shared<Image::Impl>();
    image->image = impl_->image;
    image->owner = impl_;
    return Image(std::move(image));
}

// MARK: - Shader

Shader::Shader(std::shared_ptr<Impl> impl) : impl_(std::move(impl)) {}
bool Shader::isValid() const { return impl_ && impl_->shader != nullptr; }
Shader::Impl *Shader::raw() const { return impl_.get(); }

Shader makeRuntimeShader(const char *sksl, const float *uniforms, size_t uniformFloatCount) {
    if (sksl == nullptr) return Shader(nullptr);
    auto result = SkRuntimeEffect::MakeForShader(SkString(sksl));
    if (!result.effect) return Shader(nullptr);
    sk_sp<SkRuntimeEffect> effect = result.effect;
    sk_sp<SkData> uniformData;
    if (uniformFloatCount > 0 && uniforms != nullptr) {
        uniformData = SkData::MakeWithCopy(uniforms, uniformFloatCount * sizeof(float));
    } else {
        uniformData = SkData::MakeEmpty();
    }
    if (uniformData->size() != effect->uniformSize()) return Shader(nullptr);
    auto impl = std::make_shared<Shader::Impl>();
    impl->shader = effect->makeShader(std::move(uniformData), {});
    if (!impl->shader) return Shader(nullptr);
    return Shader(std::move(impl));
}

Shader makeRuntimeShaderWithImage(
    const char *sksl, const float *uniforms, size_t uniformFloatCount, const Image &child) {
    if (sksl == nullptr) return Shader(nullptr);
    Image::Impl *childImpl = child.raw();
    if (childImpl == nullptr || childImpl->image == nullptr) return Shader(nullptr);

    auto result = SkRuntimeEffect::MakeForShader(SkString(sksl));
    if (!result.effect) return Shader(nullptr);
    sk_sp<SkRuntimeEffect> effect = result.effect;
    if (effect->children().size() != 1) return Shader(nullptr);

    sk_sp<SkData> uniformData;
    if (uniformFloatCount > 0 && uniforms != nullptr) {
        uniformData = SkData::MakeWithCopy(uniforms, uniformFloatCount * sizeof(float));
    } else {
        uniformData = SkData::MakeEmpty();
    }
    if (uniformData->size() != effect->uniformSize()) return Shader(nullptr);

    sk_sp<SkShader> childShader = childImpl->image->makeShader(
        SkTileMode::kClamp, SkTileMode::kClamp, SkSamplingOptions(SkFilterMode::kLinear));
    if (!childShader) return Shader(nullptr);
    SkRuntimeEffect::ChildPtr children[] = {SkRuntimeEffect::ChildPtr(childShader)};

    auto impl = std::make_shared<Shader::Impl>();
    impl->shader = effect->makeShader(std::move(uniformData), SkSpan(children));
    if (!impl->shader) return Shader(nullptr);
    return Shader(std::move(impl));
}

Image makeRasterImageRGBA(int32_t width, int32_t height, const uint8_t *pixels, size_t byteLength) {
    if (width <= 0 || height <= 0 || pixels == nullptr) return Image(nullptr);
    SkImageInfo info = SkImageInfo::Make(width, height, kRGBA_8888_SkColorType, kPremul_SkAlphaType);
    if (byteLength < info.computeMinByteSize()) return Image(nullptr);
    SkPixmap pixmap(info, pixels, info.minRowBytes());
    auto impl = std::make_shared<Image::Impl>();
    impl->image = SkImages::RasterFromPixmapCopy(pixmap);
    return Image(std::move(impl));
}

Image makeEncodedImageFromFile(const char *path) {
    if (path == nullptr || path[0] == '\0') return Image(nullptr);
    sk_sp<SkData> data = SkData::MakeFromFileName(path);
    if (!data) return Image(nullptr);
    auto impl = std::make_shared<Image::Impl>();
    impl->image = SkImages::DeferredFromEncodedData(std::move(data));
    if (!impl->image) return Image(nullptr);
    return Image(std::move(impl));
}

// MARK: - Canvas

Canvas::Canvas(std::shared_ptr<Impl> impl) : impl_(std::move(impl)) {}
bool Canvas::isValid() const { return impl_ && impl_->canvas != nullptr; }

void Canvas::clear(Color color) const {
    if (!isValid()) return;
    SkPaint paint;
    paint.setColor(SkColor4f{color.r, color.g, color.b, color.a}, nullptr);
    paint.setBlendMode(SkBlendMode::kSrc);
    impl_->canvas->drawPaint(paint);
}

// --- Save / clip stack ---

void Canvas::save() const {
    if (!isValid()) return;
    impl_->canvas->save();
}

void Canvas::restore() const {
    if (!isValid()) return;
    impl_->canvas->restore();
}

void Canvas::saveLayerAlpha(RectF bounds, float alpha) const {
    if (!isValid()) return;
    const uint8_t a = static_cast<uint8_t>(SkTPin(alpha, 0.0f, 1.0f) * 255.0f + 0.5f);
    if (bounds.width > 0 && bounds.height > 0) {
        const SkRect r = SkRect::MakeXYWH(bounds.x, bounds.y, bounds.width, bounds.height);
        impl_->canvas->saveLayerAlpha(&r, a);
    } else {
        impl_->canvas->saveLayerAlpha(nullptr, a);
    }
}

void Canvas::clipRect(RectF rect, bool antialias) const {
    if (!isValid()) return;
    impl_->canvas->clipRect(
        SkRect::MakeXYWH(rect.x, rect.y, rect.width, rect.height), antialias);
}

void Canvas::clipRRect(RectF rect, RRectRadii radii, bool antialias) const {
    if (!isValid()) return;
    impl_->canvas->clipRRect(toSkRRect(rect, radii), antialias);
}

// --- Draws (Paint-carrying) ---

void Canvas::drawRect(RectF rect, Paint paint) const {
    if (!isValid()) return;
    impl_->canvas->drawRect(
        SkRect::MakeXYWH(rect.x, rect.y, rect.width, rect.height), toSkPaint(paint));
}

void Canvas::drawRRect(RectF rect, RRectRadii radii, Paint paint) const {
    if (!isValid()) return;
    impl_->canvas->drawRRect(toSkRRect(rect, radii), toSkPaint(paint));
}

void Canvas::drawStyledRRect(StyledRRect style, float alpha) const {
    if (!isValid() || style.rect.width <= 0 || style.rect.height <= 0 || alpha <= 0) return;

    const SkRect outerRect = SkRect::MakeXYWH(
        style.rect.x, style.rect.y, style.rect.width, style.rect.height);
    const SkRRect outer = toSkRRect(style.rect, style.radii);
    SkPaint background;
    background.setAntiAlias(true);
    background.setColor4f(SkColor4f{style.background.r, style.background.g,
                                    style.background.b, style.background.a}, nullptr);
    background.setAlphaf(SkTPin(style.background.a * alpha, 0.0f, 1.0f));
    impl_->canvas->drawRRect(outer, background);

    const float top = SkTPin(style.borderTopWidth, 0.0f, style.rect.height);
    const float right = SkTPin(style.borderRightWidth, 0.0f, style.rect.width);
    const float bottom = SkTPin(style.borderBottomWidth, 0.0f, style.rect.height);
    const float left = SkTPin(style.borderLeftWidth, 0.0f, style.rect.width);
    if (top <= 0 && right <= 0 && bottom <= 0 && left <= 0) return;

    const SkRect innerRect = SkRect::MakeLTRB(
        outerRect.left() + left, outerRect.top() + top,
        std::max(outerRect.left() + left, outerRect.right() - right),
        std::max(outerRect.top() + top, outerRect.bottom() - bottom));
    RRectRadii innerRadii{
        std::max(0.0f, style.radii.topLeft - std::max(top, left)),
        std::max(0.0f, style.radii.topRight - std::max(top, right)),
        std::max(0.0f, style.radii.bottomRight - std::max(bottom, right)),
        std::max(0.0f, style.radii.bottomLeft - std::max(bottom, left))};
    RectF innerRectF{innerRect.x(), innerRect.y(), innerRect.width(), innerRect.height()};

    impl_->canvas->save();
    impl_->canvas->clipRRect(outer, true);
    if (!innerRect.isEmpty()) {
        impl_->canvas->clipRRect(toSkRRect(innerRectF, innerRadii), SkClipOp::kDifference, true);
    }

    const float midLeft = innerRect.left();
    const float midRight = innerRect.right();
    const float midTop = innerRect.top();
    const float midBottom = innerRect.bottom();
    auto drawEdge = [&](Color color, std::initializer_list<SkPoint> points) {
        if (color.a <= 0) return;
        SkPathBuilder path;
        auto it = points.begin();
        path.moveTo(*it++);
        for (; it != points.end(); ++it) path.lineTo(*it);
        path.close();
        SkPaint paint;
        paint.setAntiAlias(true);
        paint.setColor4f(SkColor4f{color.r, color.g, color.b, color.a}, nullptr);
        paint.setAlphaf(SkTPin(color.a * alpha, 0.0f, 1.0f));
        impl_->canvas->drawPath(path.detach(), paint);
    };
    if (top > 0) drawEdge(style.borderTopColor, {
        {outerRect.left(), outerRect.top()}, {outerRect.right(), outerRect.top()},
        {midRight, midTop}, {midLeft, midTop}});
    if (right > 0) drawEdge(style.borderRightColor, {
        {outerRect.right(), outerRect.top()}, {outerRect.right(), outerRect.bottom()},
        {midRight, midBottom}, {midRight, midTop}});
    if (bottom > 0) drawEdge(style.borderBottomColor, {
        {outerRect.right(), outerRect.bottom()}, {outerRect.left(), outerRect.bottom()},
        {midLeft, midBottom}, {midRight, midBottom}});
    if (left > 0) drawEdge(style.borderLeftColor, {
        {outerRect.left(), outerRect.bottom()}, {outerRect.left(), outerRect.top()},
        {midLeft, midTop}, {midLeft, midBottom}});
    impl_->canvas->restore();
}

void Canvas::drawImageRect(const Image &image, RectF src, RectF dst, Paint paint) const {
    if (!isValid()) return;
    Image::Impl *im = image.raw();
    if (im == nullptr || im->image == nullptr) return;
    SkPaint sk = toSkPaint(paint);
    // The fill color is irrelevant for an image draw; carry only alpha/blend/filters.
    sk.setColor(SkColors::kTransparent);
    sk.setAlphaf(SkTPin(paint.alpha, 0.0f, 1.0f));
    const SkRect dstRect = SkRect::MakeXYWH(dst.x, dst.y, dst.width, dst.height);
    const SkSamplingOptions sampling(SkFilterMode::kLinear);
    if (src.width > 0 && src.height > 0) {
        const SkRect srcRect = SkRect::MakeXYWH(src.x, src.y, src.width, src.height);
        impl_->canvas->drawImageRect(
            im->image, srcRect, dstRect, sampling, &sk,
            SkCanvas::kStrict_SrcRectConstraint);
    } else {
        impl_->canvas->drawImageRect(im->image, dstRect, sampling, &sk);
    }
}

void Canvas::drawShaderRect(RectF rect, const Shader &shader, Paint paint) const {
    if (!isValid()) return;
    Shader::Impl *sh = shader.raw();
    if (sh == nullptr || sh->shader == nullptr) return;
    SkPaint sk = toSkPaint(paint);
    sk.setShader(sh->shader);
    impl_->canvas->drawRect(
        SkRect::MakeXYWH(rect.x, rect.y, rect.width, rect.height), sk);
}

extern "C" void nucleus_skia_set_text_layout_resolver(uintptr_t (*resolve)(uint64_t)) {
    g_textLayoutResolver = resolve;
}

void Canvas::drawTextLayout(uint64_t handle, RectF dst, float alpha) const {
    if (!isValid() || handle == 0 || g_textLayoutResolver == nullptr) return;
    auto *paragraph =
        reinterpret_cast<::skia::textlayout::Paragraph *>(g_textLayoutResolver(handle));
    if (paragraph == nullptr) return;
    SkCanvas *canvas = impl_->canvas;

    // The paragraph was laid out to its own width; scale it to fill dst's width
    // (identical to the former by-handle draw, now painted directly here).
    const float layout_width = paragraph->getMaxWidth();
    const float scale =
        (layout_width > 0.0f && dst.width > 0.0f) ? dst.width / layout_width : 1.0f;
    canvas->save();
    canvas->translate(dst.x, dst.y);
    if (alpha < 1.0f) {
        SkPaint layer_paint;
        layer_paint.setAlphaf(std::clamp(alpha, 0.0f, 1.0f));
        canvas->saveLayer(nullptr, &layer_paint);
    }
    if (scale > 0.0f && scale != 1.0f) {
        canvas->scale(scale, scale);
    }
    paragraph->paint(canvas, 0.0f, 0.0f);
    if (alpha < 1.0f) {
        canvas->restore();
    }
    canvas->restore();
}

// --- Convenience overloads (color-only; preserved from 10b.3) ---

void Canvas::drawRect(RectF rect, Color color) const {
    drawRect(rect, Paint{color, 1, BlendMode::srcOver, true, 0, 1});
}

void Canvas::drawImage(const Image &image, RectF dst, float alpha) const {
    drawImageRect(image, RectF{0, 0, 0, 0}, dst, Paint{Color{}, alpha, BlendMode::srcOver, true, 0, 1});
}

void Canvas::drawRoundRect(RectF rect, float radius, Color color) const {
    drawRRect(rect, RRectRadii{radius, radius, radius, radius},
              Paint{color, 1, BlendMode::srcOver, true, 0, 1});
}

// MARK: - Surface

Surface::Surface(std::shared_ptr<Impl> impl) : impl_(std::move(impl)) {}
bool Surface::isValid() const { return impl_ && impl_->surface != nullptr; }
int32_t Surface::width() const { return isValid() ? impl_->surface->width() : 0; }
int32_t Surface::height() const { return isValid() ? impl_->surface->height() : 0; }

Canvas Surface::getCanvas() const {
    if (!isValid()) return Canvas(nullptr);
    auto impl = std::make_shared<Canvas::Impl>();
    impl->surface = impl_;
    impl->canvas = impl_->surface->getCanvas();
    return Canvas(std::move(impl));
}

Image Surface::snapshotImage() const {
    if (!isValid()) return Image(nullptr);
    auto impl = std::make_shared<Image::Impl>();
    impl->image = impl_->surface->makeImageSnapshot();
    return Image(std::move(impl));
}

Surface::Impl *Surface::raw() const { return impl_.get(); }

// MARK: - Recording

Recording::Recording(std::shared_ptr<Impl> impl) : impl_(std::move(impl)) {}
bool Recording::isValid() const { return impl_ && impl_->recording != nullptr; }
Recording::Impl *Recording::raw() const { return impl_.get(); }

// MARK: - Recorder

Recorder::Recorder(std::shared_ptr<Impl> impl) : impl_(std::move(impl)) {}
bool Recorder::isValid() const { return impl_ && impl_->recorder != nullptr; }

Surface Recorder::makeOffscreenSurface(int32_t width, int32_t height) const {
    if (!isValid() || width <= 0 || height <= 0) return Surface(nullptr);
    SkImageInfo info = SkImageInfo::Make(width, height, kRGBA_8888_SkColorType, kPremul_SkAlphaType);
    sk_sp<SkSurface> surface = SkSurfaces::RenderTarget(impl_->recorder.get(), info);
    if (!surface) return Surface(nullptr);
    auto impl = std::make_shared<Surface::Impl>();
    impl->recorder = impl_;
    impl->surface = std::move(surface);
    return Surface(std::move(impl));
}

UploadTexture Recorder::makeUploadTextureRGBA(int32_t width, int32_t height) const {
    if (!isValid() || width <= 0 || height <= 0) return UploadTexture(nullptr);
    skgpu::graphite::VulkanTextureInfo info;
    info.fSampleCount = skgpu::graphite::SampleCount::k1;
    info.fMipmapped = skgpu::Mipmapped::kNo;
    info.fFormat = VK_FORMAT_R8G8B8A8_UNORM;
    info.fImageTiling = VK_IMAGE_TILING_OPTIMAL;
    info.fImageUsageFlags = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    info.fSharingMode = VK_SHARING_MODE_EXCLUSIVE;

    auto texture = impl_->recorder->createBackendTexture(
        SkISize::Make(width, height), skgpu::graphite::TextureInfos::MakeVulkan(info));
    if (!texture.isValid()) return UploadTexture(nullptr);
    sk_sp<SkImage> image = SkImages::WrapTexture(
        impl_->recorder.get(), texture, kPremul_SkAlphaType, nullptr);
    if (!image) {
        impl_->recorder->deleteBackendTexture(texture);
        return UploadTexture(nullptr);
    }
    auto upload = std::make_shared<UploadTexture::Impl>();
    upload->context = impl_->context;
    upload->recorder = impl_;
    upload->texture = texture;
    upload->image = std::move(image);
    upload->width = width;
    upload->height = height;
    return UploadTexture(std::move(upload));
}

// Graphite currently models Vulkan tiling as a binary optimal/linear choice.
// VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT is neither, but VulkanCaps classifies
// every non-optimal value as linear and consequently tests the image against
// the format's linear-tiling feature bits.  A modifier-backed image is GPU
// tiled and must use the optimal capability bucket for Graphite's bookkeeping;
// the VkImage itself retains its real modifier layout.
static VkImageTiling graphiteImageTiling(uint32_t tiling) {
    const auto vkTiling = static_cast<VkImageTiling>(tiling);
    return vkTiling == VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT
        ? VK_IMAGE_TILING_OPTIMAL
        : vkTiling;
}

Image Recorder::wrapBackendImage(const VulkanImageDescriptor &desc) const {
    if (!isValid() || desc.image == nullptr || desc.width <= 0 || desc.height <= 0) {
        return Image(nullptr);
    }
    const skgpu::graphite::VulkanTextureInfo info(
        static_cast<VkSampleCountFlagBits>(desc.sampleCount == 0 ? 1u : desc.sampleCount),
        skgpu::Mipmapped::kNo,
        /*flags=*/0,
        static_cast<VkFormat>(desc.format),
        graphiteImageTiling(desc.imageTiling),
        static_cast<VkImageUsageFlags>(desc.imageUsageFlags),
        VK_SHARING_MODE_EXCLUSIVE,
        VK_IMAGE_ASPECT_COLOR_BIT,
        skgpu::VulkanYcbcrConversionInfo{});

    skgpu::VulkanAlloc alloc;
    alloc.fMemory = static_cast<VkDeviceMemory>(desc.memory);
    alloc.fOffset = 0;
    alloc.fSize = desc.allocSize;

    skgpu::graphite::BackendTexture backend = skgpu::graphite::BackendTextures::MakeVulkan(
        SkISize::Make(desc.width, desc.height), info,
        static_cast<VkImageLayout>(desc.imageLayout), desc.queueFamilyIndex,
        static_cast<VkImage>(desc.image), alloc);
    if (!backend.isValid()) return Image(nullptr);

    const SkAlphaType alphaType = desc.hasAlpha ? kPremul_SkAlphaType : kOpaque_SkAlphaType;
    auto impl = std::make_shared<Image::Impl>();
    impl->image = SkImages::WrapTexture(impl_->recorder.get(), backend, alphaType, nullptr);
    if (!impl->image) return Image(nullptr);
    return Image(std::move(impl));
}

// The Skia color type a wrapped scanout image is composited/read as. Mirrors the
// channel order of the borrowed VkImage's format; unknown formats fall back to
// RGBA8888 (the offscreen default).
static SkColorType skColorTypeForVkFormat(uint32_t format) {
    switch (format) {
        case VK_FORMAT_B8G8R8A8_UNORM:
        case VK_FORMAT_B8G8R8A8_SRGB:
            return kBGRA_8888_SkColorType;
        case VK_FORMAT_R8G8B8A8_UNORM:
        case VK_FORMAT_R8G8B8A8_SRGB:
            return kRGBA_8888_SkColorType;
        case VK_FORMAT_A2B10G10R10_UNORM_PACK32:
            return kRGBA_1010102_SkColorType;
        case VK_FORMAT_A2R10G10B10_UNORM_PACK32:
            return kBGRA_1010102_SkColorType;
        default:
            return kRGBA_8888_SkColorType;
    }
}

Surface Recorder::wrapBackendSurface(const VulkanImageDescriptor &desc) const {
    if (!isValid() || desc.image == nullptr || desc.width <= 0 || desc.height <= 0) {
        return Surface(nullptr);
    }
    const skgpu::graphite::VulkanTextureInfo info(
        static_cast<VkSampleCountFlagBits>(desc.sampleCount == 0 ? 1u : desc.sampleCount),
        skgpu::Mipmapped::kNo,
        /*flags=*/0,
        static_cast<VkFormat>(desc.format),
        graphiteImageTiling(desc.imageTiling),
        static_cast<VkImageUsageFlags>(desc.imageUsageFlags),
        VK_SHARING_MODE_EXCLUSIVE,
        VK_IMAGE_ASPECT_COLOR_BIT,
        skgpu::VulkanYcbcrConversionInfo{});

    skgpu::VulkanAlloc alloc;
    alloc.fMemory = static_cast<VkDeviceMemory>(desc.memory);
    alloc.fOffset = 0;
    alloc.fSize = desc.allocSize;

    skgpu::graphite::BackendTexture backend = skgpu::graphite::BackendTextures::MakeVulkan(
        SkISize::Make(desc.width, desc.height), info,
        static_cast<VkImageLayout>(desc.imageLayout), desc.queueFamilyIndex,
        static_cast<VkImage>(desc.image), alloc);
    if (!backend.isValid()) return Surface(nullptr);

    const SkColorType colorType = skColorTypeForVkFormat(desc.format);
    auto impl = std::make_shared<Surface::Impl>();
    impl->recorder = impl_;
    impl->surface = SkSurfaces::WrapBackendTexture(
        impl_->recorder.get(), backend, colorType, /*colorSpace=*/nullptr, /*props=*/nullptr);
    if (!impl->surface) return Surface(nullptr);
    return Surface(std::move(impl));
}

Recording Recorder::snapRecording() const {
    if (!isValid()) return Recording(nullptr);
    auto impl = std::make_shared<Recording::Impl>();
    impl->recording = impl_->recorder->snap();
    return Recording(std::move(impl));
}

// MARK: - GraphiteContext

GraphiteContext::GraphiteContext(std::shared_ptr<Impl> impl) : impl_(std::move(impl)) {}
bool GraphiteContext::isValid() const { return impl_ && impl_->context != nullptr; }
void GraphiteContext::reset() { impl_.reset(); }

Recorder GraphiteContext::makeRecorder() const {
    if (!isValid()) return Recorder(nullptr);
    skgpu::graphite::RecorderOptions options;
    auto recorder = impl_->context->makeRecorder(options);
    if (!recorder) return Recorder(nullptr);
    auto impl = std::make_shared<Recorder::Impl>();
    impl->context = impl_;
    impl->recorder = std::move(recorder);
    return Recorder(std::move(impl));
}

Status GraphiteContext::submit(const Recording &recording) const {
    if (!isValid()) return Status::submitFailed;
    Recording::Impl *rec = recording.raw();
    if (!rec || !rec->recording) return Status::invalidArgument;

    skgpu::graphite::InsertRecordingInfo info;
    info.fRecording = rec->recording.get();
    if (!impl_->context->insertRecording(info)) return Status::recordingFailed;
    if (!impl_->context->submit(skgpu::graphite::SyncToCpu::kYes)) return Status::submitFailed;
    return Status::ok;
}

Status GraphiteContext::submitWithUpload(
    const Recording &upload, const Recording &frame) const {
    if (!isValid()) return Status::submitFailed;
    Recording::Impl *up = upload.raw();
    Recording::Impl *fr = frame.raw();
    if (!up || !up->recording || !fr || !fr->recording) return Status::invalidArgument;

    skgpu::graphite::InsertRecordingInfo info;
    info.fRecording = up->recording.get();
    if (!impl_->context->insertRecording(info)) return Status::recordingFailed;
    info.fRecording = fr->recording.get();
    if (!impl_->context->insertRecording(info)) return Status::recordingFailed;
    if (!impl_->context->submit(skgpu::graphite::SyncToCpu::kYes)) return Status::submitFailed;
    return Status::ok;
}

Status GraphiteContext::submitWithSemaphores(
    const Recording &recording, void *const *waitSemaphores,
    size_t waitSemaphoreCount, void *signalSemaphore,
    uint64_t submissionSerial) const {
    if (!isValid()) return Status::invalidArgument;
    Recording::Impl *rec = recording.raw();
    if (!rec || !rec->recording) return Status::invalidArgument;

    std::vector<skgpu::graphite::BackendSemaphore> waits;
    waits.reserve(waitSemaphoreCount);
    for (size_t i = 0; i < waitSemaphoreCount; ++i) {
        if (waitSemaphores[i] != nullptr) waits.push_back(
            skgpu::graphite::BackendSemaphores::MakeVulkan(
                static_cast<VkSemaphore>(waitSemaphores[i])));
    }
    skgpu::graphite::InsertRecordingInfo info;
    info.fRecording = rec->recording.get();
    info.fNumWaitSemaphores = waits.size();
    info.fWaitSemaphores = waits.data();
    skgpu::graphite::BackendSemaphore signal;
    if (signalSemaphore != nullptr) {
        signal = skgpu::graphite::BackendSemaphores::MakeVulkan(
            static_cast<VkSemaphore>(signalSemaphore));
        info.fNumSignalSemaphores = 1;
        info.fSignalSemaphores = &signal;
    }
    attachSubmissionCompletion(info, impl_->submissionCompletion, submissionSerial);
    if (!impl_->context->insertRecording(info)) return Status::recordingFailed;
    if (!impl_->context->submit(skgpu::graphite::SyncToCpu::kNo)) return Status::submitFailed;
    return Status::ok;
}

Status GraphiteContext::submitWithUploadAndSemaphores(
    const Recording &upload, const Recording &frame, void *const *waitSemaphores,
    size_t waitSemaphoreCount, void *signalSemaphore,
    uint64_t submissionSerial) const {
    if (!isValid()) return Status::invalidArgument;
    Recording::Impl *up = upload.raw();
    Recording::Impl *fr = frame.raw();
    if (!up || !up->recording || !fr || !fr->recording) return Status::invalidArgument;

    skgpu::graphite::InsertRecordingInfo uploadInfo;
    uploadInfo.fRecording = up->recording.get();
    if (!impl_->context->insertRecording(uploadInfo)) return Status::recordingFailed;

    std::vector<skgpu::graphite::BackendSemaphore> waits;
    waits.reserve(waitSemaphoreCount);
    for (size_t i = 0; i < waitSemaphoreCount; ++i) {
        if (waitSemaphores[i] != nullptr) waits.push_back(
            skgpu::graphite::BackendSemaphores::MakeVulkan(
                static_cast<VkSemaphore>(waitSemaphores[i])));
    }
    skgpu::graphite::InsertRecordingInfo frameInfo;
    frameInfo.fRecording = fr->recording.get();
    frameInfo.fNumWaitSemaphores = waits.size();
    frameInfo.fWaitSemaphores = waits.data();
    skgpu::graphite::BackendSemaphore signal;
    if (signalSemaphore != nullptr) {
        signal = skgpu::graphite::BackendSemaphores::MakeVulkan(
            static_cast<VkSemaphore>(signalSemaphore));
        frameInfo.fNumSignalSemaphores = 1;
        frameInfo.fSignalSemaphores = &signal;
    }
    attachSubmissionCompletion(
        frameInfo, impl_->submissionCompletion, submissionSerial);
    if (!impl_->context->insertRecording(frameInfo)) return Status::recordingFailed;
    if (!impl_->context->submit(skgpu::graphite::SyncToCpu::kNo)) return Status::submitFailed;
    return Status::ok;
}

Status GraphiteContext::submitForPresent(
    const Surface &targetSurface, const Recording &recording,
    void *const *waitSemaphores, size_t waitSemaphoreCount,
    void *signalSemaphore, uint32_t presentQueueFamily,
    uint64_t submissionSerial) const {
    if (!isValid()) return Status::submitFailed;
    Recording::Impl *rec = recording.raw();
    if (!rec || !rec->recording) return Status::invalidArgument;
    Surface::Impl *surf = targetSurface.raw();
    if (!surf || !surf->surface) return Status::invalidArgument;

    skgpu::graphite::InsertRecordingInfo info;
    info.fRecording = rec->recording.get();

    // The swapchain acquire semaphore gates the GPU work; the present-wait
    // semaphore is signaled when it completes. BackendSemaphore wraps the borrowed
    // VkSemaphore handles (Skia never owns them).
    std::vector<skgpu::graphite::BackendSemaphore> waits;
    skgpu::graphite::BackendSemaphore signalSem;
    waits.reserve(waitSemaphoreCount);
    for (size_t i = 0; i < waitSemaphoreCount; ++i) {
        if (waitSemaphores[i] != nullptr) waits.push_back(
            skgpu::graphite::BackendSemaphores::MakeVulkan(
                static_cast<VkSemaphore>(waitSemaphores[i])));
    }
    info.fNumWaitSemaphores = waits.size();
    info.fWaitSemaphores = waits.data();
    if (signalSemaphore != nullptr) {
        signalSem = skgpu::graphite::BackendSemaphores::MakeVulkan(
            static_cast<VkSemaphore>(signalSemaphore));
        info.fNumSignalSemaphores = 1;
        info.fSignalSemaphores = &signalSem;
    }

    // Transition the swapchain image to PRESENT_SRC on the present queue family as
    // part of this submit, so it is presentable when the signal semaphore fires.
    skgpu::MutableTextureState presentState = skgpu::MutableTextureStates::MakeVulkan(
        VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, presentQueueFamily);
    info.fTargetSurface = surf->surface.get();
    info.fTargetTextureState = &presentState;
    attachSubmissionCompletion(info, impl_->submissionCompletion, submissionSerial);

    if (!impl_->context->insertRecording(info)) return Status::recordingFailed;
    // Async: do NOT sync to CPU — vkQueuePresentKHR orders against the signal
    // semaphore, so a CPU stall here would only hurt frame pacing.
    if (!impl_->context->submit(skgpu::graphite::SyncToCpu::kNo)) return Status::submitFailed;
    return Status::ok;
}

Status GraphiteContext::submitForPresentWithUpload(
    const Surface &targetSurface, const Recording &upload, const Recording &frame,
    void *const *waitSemaphores, size_t waitSemaphoreCount,
    void *signalSemaphore, uint32_t presentQueueFamily,
    uint64_t submissionSerial) const {
    if (!isValid()) return Status::submitFailed;
    Recording::Impl *up = upload.raw();
    Recording::Impl *fr = frame.raw();
    if (!up || !up->recording || !fr || !fr->recording) return Status::invalidArgument;
    Surface::Impl *surf = targetSurface.raw();
    if (!surf || !surf->surface) return Status::invalidArgument;

    skgpu::graphite::InsertRecordingInfo uploadInfo;
    uploadInfo.fRecording = up->recording.get();
    if (!impl_->context->insertRecording(uploadInfo)) return Status::recordingFailed;

    skgpu::graphite::InsertRecordingInfo frameInfo;
    frameInfo.fRecording = fr->recording.get();
    std::vector<skgpu::graphite::BackendSemaphore> waits;
    skgpu::graphite::BackendSemaphore signalSem;
    waits.reserve(waitSemaphoreCount);
    for (size_t i = 0; i < waitSemaphoreCount; ++i) {
        if (waitSemaphores[i] != nullptr) waits.push_back(
            skgpu::graphite::BackendSemaphores::MakeVulkan(
                static_cast<VkSemaphore>(waitSemaphores[i])));
    }
    frameInfo.fNumWaitSemaphores = waits.size();
    frameInfo.fWaitSemaphores = waits.data();
    if (signalSemaphore != nullptr) {
        signalSem = skgpu::graphite::BackendSemaphores::MakeVulkan(
            static_cast<VkSemaphore>(signalSemaphore));
        frameInfo.fNumSignalSemaphores = 1;
        frameInfo.fSignalSemaphores = &signalSem;
    }
    skgpu::MutableTextureState presentState = skgpu::MutableTextureStates::MakeVulkan(
        VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, presentQueueFamily);
    frameInfo.fTargetSurface = surf->surface.get();
    frameInfo.fTargetTextureState = &presentState;
    attachSubmissionCompletion(
        frameInfo, impl_->submissionCompletion, submissionSerial);
    if (!impl_->context->insertRecording(frameInfo)) return Status::recordingFailed;
    if (!impl_->context->submit(skgpu::graphite::SyncToCpu::kNo)) return Status::submitFailed;
    return Status::ok;
}

uint64_t GraphiteContext::pollCompletedSubmissionSerial() const {
    if (!isValid()) return 0;
    impl_->context->checkAsyncWorkCompletion();
    return impl_->submissionCompletion->completedSerial.load(std::memory_order_acquire);
}

uint64_t GraphiteContext::takeCompletedSubmissionGpuElapsedNs(
    uint64_t submissionSerial) const {
    if (!isValid() || submissionSerial == 0) return 0;
    impl_->context->checkAsyncWorkCompletion();
    auto &state = *impl_->submissionCompletion;
    std::lock_guard<std::mutex> lock(state.mutex);
    auto it = state.gpuElapsedNs.find(submissionSerial);
    if (it == state.gpuElapsedNs.end()) return 0;
    const uint64_t elapsed = it->second;
    state.gpuElapsedNs.erase(it);
    return elapsed;
}

namespace {
struct ReadbackCtx {
    bool done = false;
    std::unique_ptr<const SkImage::AsyncReadResult> result;
};
}  // namespace

Status GraphiteContext::readSurfaceRGBA(
    const Surface &surface, uint8_t *dst, size_t byteLength, int32_t rowBytes) const {
    if (!isValid() || dst == nullptr) return Status::invalidArgument;
    Surface::Impl *s = surface.raw();
    if (s == nullptr || !s->surface) return Status::invalidArgument;

    const int w = s->surface->width();
    const int h = s->surface->height();
    const SkImageInfo info = SkImageInfo::Make(w, h, kRGBA_8888_SkColorType, kPremul_SkAlphaType);
    const size_t stride = rowBytes > 0 ? static_cast<size_t>(rowBytes) : info.minRowBytes();
    if (byteLength < stride * static_cast<size_t>(h)) return Status::invalidArgument;

    // The readback context must outlive this function: if the async read has not
    // completed by the time we give up below, Skia still holds a pointer to it and
    // will write into it from a later checkAsyncWorkCompletion (next readback, or
    // context teardown draining pending callbacks). Heap-own it via a shared_ptr and
    // hand Skia an owning box; the callback releases that box. On the give-up path
    // this scope's ref drops but the box keeps the context alive, so the eventual
    // callback writes into live memory rather than a freed stack frame.
    auto ctx = std::make_shared<ReadbackCtx>();
    auto *box = new std::shared_ptr<ReadbackCtx>(ctx);
    auto callback = [](SkImage::ReadPixelsContext c,
                       std::unique_ptr<const SkImage::AsyncReadResult> r) {
        auto *b = static_cast<std::shared_ptr<ReadbackCtx> *>(c);
        (*b)->result = std::move(r);
        (*b)->done = true;
        delete b;
    };
    impl_->context->asyncRescaleAndReadPixels(
        s->surface.get(), info, SkIRect::MakeWH(w, h),
        SkImage::RescaleGamma::kSrc, SkImage::RescaleMode::kNearest, callback, box);
    impl_->context->submit(skgpu::graphite::SyncToCpu::kYes);
    for (int guard = 0; !ctx->done && guard < 1000; ++guard) {
        impl_->context->checkAsyncWorkCompletion();
    }
    if (!ctx->done || !ctx->result) return Status::submitFailed;

    const auto *src = static_cast<const uint8_t *>(ctx->result->data(0));
    const size_t srcStride = ctx->result->rowBytes(0);
    for (int y = 0; y < h; ++y) {
        std::memcpy(dst + static_cast<size_t>(y) * stride,
                    src + static_cast<size_t>(y) * srcStride,
                    static_cast<size_t>(w) * 4);
    }
    return Status::ok;
}

// MARK: - Context factory

GraphiteContext makeGraphiteVulkanContext(const VulkanContextDescriptor &descriptor) {
    auto impl = std::make_shared<GraphiteContext::Impl>();

    auto getProc = makeVulkanGetProc();
    auto instance = static_cast<VkInstance>(descriptor.instance);
    auto physicalDevice = static_cast<VkPhysicalDevice>(descriptor.physicalDevice);
    auto device = static_cast<VkDevice>(descriptor.device);
    auto queue = static_cast<VkQueue>(descriptor.queue);
    const uint32_t apiVersion = descriptor.maxApiVersion;

    impl->extensions.init(
        getProc, instance, physicalDevice,
        descriptor.instanceExtensionCount, descriptor.instanceExtensions,
        descriptor.deviceExtensionCount, descriptor.deviceExtensions);

    impl->interface = sk_make_sp<skgpu::VulkanInterface>(
        getProc, instance, device, apiVersion, apiVersion, &impl->extensions);
    if (!impl->interface->validate(apiVersion, apiVersion, &impl->extensions)) {
        return GraphiteContext(nullptr);
    }

    impl->allocator = skgpu::VulkanAMDMemoryAllocator::Make(
        instance, physicalDevice, device, apiVersion, &impl->extensions,
        impl->interface.get(), skgpu::ThreadSafe::kYes);
    if (!impl->allocator) {
        return GraphiteContext(nullptr);
    }

    skgpu::VulkanBackendContext backend;
    backend.fInstance = instance;
    backend.fPhysicalDevice = physicalDevice;
    backend.fDevice = device;
    backend.fQueue = queue;
    backend.fGraphicsQueueIndex = descriptor.graphicsQueueIndex;
    backend.fMaxAPIVersion = apiVersion;
    backend.fVkExtensions = &impl->extensions;
    backend.fMemoryAllocator = impl->allocator;
    backend.fGetProc = getProc;
    backend.fProtectedContext = skgpu::Protected::kNo;

    skgpu::graphite::ContextOptions options;
    impl->context = skgpu::graphite::ContextFactory::MakeVulkan(backend, options);
    if (!impl->context) {
        return GraphiteContext(nullptr);
    }

    return GraphiteContext(std::move(impl));
}

}  // namespace nucleus::skia
