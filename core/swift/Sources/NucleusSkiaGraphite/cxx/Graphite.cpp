// NucleusSkiaGraphite façade implementation. All Skia/Vulkan types stay here.

#include "NucleusSkiaGraphite/Graphite.hpp"

#include <algorithm>
#include <cmath>
#include <atomic>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <vector>

#include <vulkan/vulkan_core.h>

#include "modules/skparagraph/include/Paragraph.h"

#include "include/codec/SkCodec.h"

#include "modules/svg/include/SkSVGDOM.h"
#include "modules/svg/include/SkSVGSVG.h"
#include "include/ports/SkFontMgr_fontconfig.h"
#include "include/ports/SkFontScanner_FreeType.h"
#include "include/core/SkFontMgr.h"
#include "include/core/SkStream.h"

#include "include/core/SkBitmap.h"
#include "include/core/SkCanvas.h"
#include "include/core/SkColor.h"
#include "include/core/SkColorFilter.h"
#include "include/core/SkColorSpace.h"
#include "include/core/SkData.h"
#include "include/core/SkImage.h"
#include "include/core/SkImageInfo.h"
#include "include/core/SkPaint.h"
#include "include/core/SkPath.h"
#include "include/core/SkPathBuilder.h"
#include "include/core/SkPixmap.h"
#include "include/core/SkMatrix.h"
#include "include/core/SkPoint.h"
#include "include/core/SkRRect.h"
#include "include/core/SkRect.h"
#include "include/core/SkRefCnt.h"
#include "include/core/SkTileMode.h"
#include "include/core/SkSamplingOptions.h"
#include "include/core/SkSize.h"
#include "include/core/SkString.h"
#include "include/core/SkSurface.h"
#include "include/core/SkCanvas.h"
#include "include/gpu/graphite/BackendSemaphore.h"
#include "include/gpu/graphite/BackendTexture.h"
#include "include/gpu/graphite/Image.h"
#include "include/gpu/MutableTextureState.h"
#include "include/gpu/vk/VulkanMutableTextureState.h"
#include "include/effects/SkColorMatrix.h"
#include "include/effects/SkGradient.h"
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
    sk_sp<SkColorFilter> colorFilter;
    if (paint.saturation != 1.0f) {
        SkColorMatrix m;
        m.setSaturation(paint.saturation);
        colorFilter = SkColorFilters::Matrix(m);
    }
    if (paint.tintsImage) {
        // kSrcIn keeps the source alpha and replaces the colour, which recolours
        // a glyph-like icon by its shape. Composed *after* any saturation so a
        // desaturate-then-tint reads in that order rather than the reverse.
        sk_sp<SkColorFilter> tint = SkColorFilters::Blend(
            SkColor4f{paint.color.r, paint.color.g, paint.color.b, paint.color.a},
            nullptr, SkBlendMode::kSrcIn);
        colorFilter = colorFilter ? tint->makeComposed(std::move(colorFilter))
                                  : std::move(tint);
    }
    if (colorFilter) sk.setColorFilter(std::move(colorFilter));
    if (paint.blurSigma > 0.0f) {
        sk.setImageFilter(SkImageFilters::Blur(paint.blurSigma, paint.blurSigma, nullptr));
    }
    switch (paint.style) {
        case PaintStyle::fill: sk.setStyle(SkPaint::kFill_Style); break;
        case PaintStyle::stroke: sk.setStyle(SkPaint::kStroke_Style); break;
        case PaintStyle::strokeAndFill: sk.setStyle(SkPaint::kStrokeAndFill_Style); break;
    }
    if (paint.style != PaintStyle::fill) {
        sk.setStrokeWidth(paint.strokeWidth);
        sk.setStrokeMiter(paint.miter);
        switch (paint.strokeCap) {
            case StrokeCap::butt: sk.setStrokeCap(SkPaint::kButt_Cap); break;
            case StrokeCap::round: sk.setStrokeCap(SkPaint::kRound_Cap); break;
            case StrokeCap::square: sk.setStrokeCap(SkPaint::kSquare_Cap); break;
        }
        switch (paint.strokeJoin) {
            case StrokeJoin::miter: sk.setStrokeJoin(SkPaint::kMiter_Join); break;
            case StrokeJoin::round: sk.setStrokeJoin(SkPaint::kRound_Join); break;
            case StrokeJoin::bevel: sk.setStrokeJoin(SkPaint::kBevel_Join); break;
        }
    }
    return sk;
}

SkTileMode toSkTileMode(TileMode tile) {
    switch (tile) {
        case TileMode::clamp: return SkTileMode::kClamp;
        case TileMode::repeatTile: return SkTileMode::kRepeat;
        case TileMode::mirror: return SkTileMode::kMirror;
        case TileMode::decal: return SkTileMode::kDecal;
    }
    return SkTileMode::kClamp;
}

/// Shared validation + color conversion for the three gradient factories.
/// `stops` is optional; when supplied it must be one position per color, which
/// is also what `SkGradient::Colors` requires (it silently drops a mismatched
/// position span, so the check is enforced here where it can fail visibly).
bool gradientColors(
    const Color *colors, size_t count, std::vector<SkColor4f> &out) {
    if (colors == nullptr || count < 2) return false;
    out.reserve(count);
    for (size_t i = 0; i < count; ++i) {
        out.push_back(SkColor4f{colors[i].r, colors[i].g, colors[i].b, colors[i].a});
    }
    return true;
}

SkGradient makeSkGradient(
    const std::vector<SkColor4f> &colors, const float *stops, size_t count, TileMode tile) {
    SkSpan<const SkColor4f> colorSpan(colors.data(), colors.size());
    if (stops != nullptr) {
        return SkGradient(
            SkGradient::Colors(colorSpan, SkSpan<const float>(stops, count), toSkTileMode(tile)),
            SkGradient::Interpolation{});
    }
    return SkGradient(
        SkGradient::Colors(colorSpan, toSkTileMode(tile)), SkGradient::Interpolation{});
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

struct Path::Impl {
    SkPath path;
};

struct RuntimeEffect::Impl {
    sk_sp<SkRuntimeEffect> effect;
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

// MARK: - Path

Path::Path(std::shared_ptr<Impl> impl) : impl_(std::move(impl)) {}
bool Path::isValid() const { return impl_ != nullptr; }
Path::Impl *Path::raw() const { return impl_.get(); }

Path makePath(
    const uint8_t *verbs, size_t verbCount,
    const float *points, size_t pointCount, bool evenOdd) {
    if ((verbs == nullptr && verbCount > 0) ||
        (points == nullptr && pointCount > 0)) {
        return Path(nullptr);
    }

    SkPathBuilder builder;
    builder.setFillType(evenOdd ? SkPathFillType::kEvenOdd : SkPathFillType::kWinding);

    size_t f = 0;  // cursor into the flat float array
    // Each verb consumes a fixed number of floats; running past the supplied
    // points means the encoding is malformed, so fail rather than emit partial
    // geometry that would silently render wrong.
    auto take = [&](size_t floats) -> const float * {
        if (f + floats > pointCount) return nullptr;
        const float *p = points + f;
        f += floats;
        return p;
    };

    for (size_t i = 0; i < verbCount; ++i) {
        switch (static_cast<PathVerb>(verbs[i])) {
            case PathVerb::move: {
                const float *p = take(2);
                if (!p) return Path(nullptr);
                builder.moveTo(p[0], p[1]);
                break;
            }
            case PathVerb::line: {
                const float *p = take(2);
                if (!p) return Path(nullptr);
                builder.lineTo(p[0], p[1]);
                break;
            }
            case PathVerb::quad: {
                const float *p = take(4);
                if (!p) return Path(nullptr);
                builder.quadTo(p[0], p[1], p[2], p[3]);
                break;
            }
            case PathVerb::cubic: {
                const float *p = take(6);
                if (!p) return Path(nullptr);
                builder.cubicTo(p[0], p[1], p[2], p[3], p[4], p[5]);
                break;
            }
            case PathVerb::arcTo: {
                const float *p = take(6);
                if (!p) return Path(nullptr);
                const SkRect oval = SkRect::MakeXYWH(p[0], p[1], p[2], p[3]);
                // A full sweep is emitted as two connected half-arcs. `arcTo`
                // degenerates at 360 degrees, while `addOval` discards the
                // authored start angle and therefore changes the current point
                // seen by a following segment.
                if (std::abs(p[5]) >= 360.0f) {
                    const float halfSweep = p[5] < 0 ? -180.0f : 180.0f;
                    builder.arcTo(oval, p[4], halfSweep, /*forceMoveTo=*/false);
                    builder.arcTo(
                        oval, p[4] + halfSweep, halfSweep,
                        /*forceMoveTo=*/false);
                } else {
                    builder.arcTo(oval, p[4], p[5], /*forceMoveTo=*/false);
                }
                break;
            }
            case PathVerb::close:
                builder.close();
                break;
            default:
                return Path(nullptr);  // unknown verb: malformed encoding
        }
    }

    auto impl = std::make_shared<Path::Impl>();
    impl->path = builder.detach();
    return Path(std::move(impl));
}

// MARK: - Gradients

Shader makeLinearGradient(
    float x0, float y0, float x1, float y1,
    const Color *colors, const float *stops, size_t count, TileMode tile) {
    std::vector<SkColor4f> cs;
    if (!gradientColors(colors, count, cs)) return Shader(nullptr);
    const SkPoint pts[2] = {{x0, y0}, {x1, y1}};
    auto impl = std::make_shared<Shader::Impl>();
    impl->shader = SkShaders::LinearGradient(pts, makeSkGradient(cs, stops, count, tile));
    if (!impl->shader) return Shader(nullptr);
    return Shader(std::move(impl));
}

Shader makeRadialGradient(
    float centerX, float centerY, float radius,
    const Color *colors, const float *stops, size_t count, TileMode tile) {
    std::vector<SkColor4f> cs;
    if (!gradientColors(colors, count, cs)) return Shader(nullptr);
    if (!(radius > 0)) return Shader(nullptr);
    auto impl = std::make_shared<Shader::Impl>();
    impl->shader = SkShaders::RadialGradient(
        SkPoint{centerX, centerY}, radius, makeSkGradient(cs, stops, count, tile));
    if (!impl->shader) return Shader(nullptr);
    return Shader(std::move(impl));
}

Shader makeSweepGradient(
    float centerX, float centerY, float startAngle, float endAngle,
    const Color *colors, const float *stops, size_t count, TileMode tile) {
    std::vector<SkColor4f> cs;
    if (!gradientColors(colors, count, cs)) return Shader(nullptr);
    // SkShaders::SweepGradient returns null unless startAngle < endAngle.
    if (!(startAngle < endAngle)) return Shader(nullptr);
    auto impl = std::make_shared<Shader::Impl>();
    impl->shader = SkShaders::SweepGradient(
        SkPoint{centerX, centerY}, startAngle, endAngle,
        makeSkGradient(cs, stops, count, tile));
    if (!impl->shader) return Shader(nullptr);
    return Shader(std::move(impl));
}

// MARK: - RuntimeEffect

RuntimeEffect::RuntimeEffect(std::shared_ptr<Impl> impl) : impl_(std::move(impl)) {}
bool RuntimeEffect::isValid() const { return impl_ && impl_->effect != nullptr; }
RuntimeEffect::Impl *RuntimeEffect::raw() const { return impl_.get(); }

RuntimeEffect makeRuntimeEffect(const char *sksl) {
    if (sksl == nullptr) return RuntimeEffect(nullptr);
    auto result = SkRuntimeEffect::MakeForShader(SkString(sksl));
    if (!result.effect) return RuntimeEffect(nullptr);
    auto impl = std::make_shared<RuntimeEffect::Impl>();
    impl->effect = result.effect;
    return RuntimeEffect(std::move(impl));
}

namespace {
sk_sp<SkData> uniformDataFor(
    const SkRuntimeEffect &effect, const float *uniforms, size_t uniformFloatCount) {
    sk_sp<SkData> data;
    if (uniformFloatCount > 0 && uniforms != nullptr) {
        data = SkData::MakeWithCopy(uniforms, uniformFloatCount * sizeof(float));
    } else {
        data = SkData::MakeEmpty();
    }
    if (data->size() != effect.uniformSize()) return nullptr;
    return data;
}
}  // namespace

Shader RuntimeEffect::makeShader(const float *uniforms, size_t uniformFloatCount) const {
    if (!isValid()) return Shader(nullptr);
    sk_sp<SkData> data = uniformDataFor(*impl_->effect, uniforms, uniformFloatCount);
    if (!data) return Shader(nullptr);
    auto impl = std::make_shared<Shader::Impl>();
    impl->shader = impl_->effect->makeShader(std::move(data), {});
    if (!impl->shader) return Shader(nullptr);
    return Shader(std::move(impl));
}

Shader RuntimeEffect::makeShaderWithImage(
    const float *uniforms, size_t uniformFloatCount, const Image &child) const {
    if (!isValid()) return Shader(nullptr);
    Image::Impl *childImpl = child.raw();
    if (childImpl == nullptr || childImpl->image == nullptr) return Shader(nullptr);
    if (impl_->effect->children().size() != 1) return Shader(nullptr);
    sk_sp<SkData> data = uniformDataFor(*impl_->effect, uniforms, uniformFloatCount);
    if (!data) return Shader(nullptr);
    sk_sp<SkShader> childShader = childImpl->image->makeShader(
        SkTileMode::kClamp, SkTileMode::kClamp, SkSamplingOptions(SkFilterMode::kLinear));
    if (!childShader) return Shader(nullptr);
    SkRuntimeEffect::ChildPtr children[] = {SkRuntimeEffect::ChildPtr(childShader)};
    auto impl = std::make_shared<Shader::Impl>();
    impl->shader = impl_->effect->makeShader(std::move(data), SkSpan(children));
    if (!impl->shader) return Shader(nullptr);
    return Shader(std::move(impl));
}

// Retained for `Backdrop.swift`, which compiles and binds in one step because
// it holds no handle. Expressed through the split so there is one code path.
Shader makeRuntimeShader(const char *sksl, const float *uniforms, size_t uniformFloatCount) {
    return makeRuntimeEffect(sksl).makeShader(uniforms, uniformFloatCount);
}

// Retained for `Backdrop.swift`. Expressed through the compile/bind split so
// there is one code path.
Shader makeRuntimeShaderWithImage(
    const char *sksl, const float *uniforms, size_t uniformFloatCount, const Image &child) {
    return makeRuntimeEffect(sksl).makeShaderWithImage(uniforms, uniformFloatCount, child);
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

namespace {

Image wrapImage(sk_sp<SkImage> image) {
    if (!image) return Image(nullptr);
    auto impl = std::make_shared<Image::Impl>();
    impl->image = std::move(image);
    return Image(std::move(impl));
}

// Decode target: RGBA8888, and explicitly sRGB.
//
// The colour space must be stated rather than inherited. An untagged file (most
// PNGs, every icon theme) decodes with a null colour space, which Skia reads as
// "unmanaged" and skips conversion for — silently defeating the linear
// downscale below. Untagged means sRGB, so say so.
SkImageInfo decodeInfo(const SkCodec &codec, int32_t width, int32_t height) {
    return codec.getInfo()
        .makeWH(width, height)
        .makeColorType(kRGBA_8888_SkColorType)
        .makeColorSpace(SkColorSpace::MakeSRGB());
}

// Resample an image to `info`'s size through a raster surface.
//
// A surface draw rather than `SkImage::scalePixels`, because scalePixels does
// not colour-manage: handed an sRGB source and a linear destination it moves the
// values across unconverted, which defeats the whole point of the halving below.
sk_sp<SkImage> resampleThroughSurface(const sk_sp<SkImage> &source, const SkImageInfo &info) {
    sk_sp<SkSurface> surface = SkSurfaces::Raster(info);
    if (!surface) return nullptr;
    SkPaint paint;
    paint.setBlendMode(SkBlendMode::kSrc);
    surface->getCanvas()->drawImageRect(
        source, SkRect::MakeIWH(info.width(), info.height()),
        SkSamplingOptions(SkFilterMode::kLinear), &paint);
    return surface->makeImageSnapshot();
}

// Downscale in *linear* space, by repeated halving.
//
// Two independent things are being got right here. Image bytes are sRGB-encoded,
// so averaging them directly darkens and muddies the result — most visibly on
// exactly the small icons this path exists to serve. And a single large
// downscale step aliases badly: a linear or cubic filter reads a fixed handful
// of taps regardless of the ratio, so shrinking 64x in one step samples a few
// source pixels and discards the rest. Halving until the last step is within 2x
// means every source pixel contributes to the result.
sk_sp<SkImage> linearDownscale(const sk_sp<SkImage> &source, int32_t width, int32_t height) {
    SkImageInfo linearInfo = SkImageInfo::Make(
        source->width(), source->height(), kRGBA_F16_SkColorType, kPremul_SkAlphaType,
        SkColorSpace::MakeSRGBLinear());

    // Convert to linear *first*, at full size and with no resampling.
    //
    // This step is the whole trick, and it is not optional: Skia filters in the
    // source image's colour space and converts to the destination's afterwards.
    // A linear destination therefore buys nothing on its own — the averaging has
    // already happened in sRGB by the time the conversion runs. Only a source
    // that is already linear makes the filtering linear.
    sk_sp<SkImage> current = resampleThroughSurface(source, linearInfo);
    if (!current) return nullptr;

    while (current->width() / 2 > width || current->height() / 2 > height) {
        int32_t nextWidth = std::max(width, current->width() / 2);
        int32_t nextHeight = std::max(height, current->height() / 2);
        current = resampleThroughSurface(current, linearInfo.makeWH(nextWidth, nextHeight));
        if (!current) return nullptr;
    }

    // The final step lands on the target size and encodes back to sRGB.
    return resampleThroughSurface(
        current,
        SkImageInfo::Make(width, height, kRGBA_8888_SkColorType, kPremul_SkAlphaType,
                          SkColorSpace::MakeSRGB()));
}

}  // namespace

namespace {

// SVG is identified by content, not by extension. Icon themes ship `.svg` files
// that are really PNGs and `.png` files that are really SVGs often enough that
// trusting the name produces a blank icon for no visible reason. The reference
// sniffs the same way and for the same reason.
bool looksLikeSvg(const sk_sp<SkData> &data) {
    constexpr size_t kSniffBytes = 256;
    const char *bytes = reinterpret_cast<const char *>(data->bytes());
    size_t length = std::min(data->size(), kSniffBytes);
    // An XML declaration, a doctype, or a comment can precede the root element,
    // so search the window rather than testing the prefix.
    for (size_t i = 0; i + 4 <= length; ++i) {
        if (bytes[i] == '<' && (bytes[i + 1] == 's' || bytes[i + 1] == 'S') &&
            (bytes[i + 2] == 'v' || bytes[i + 2] == 'V') &&
            (bytes[i + 3] == 'g' || bytes[i + 3] == 'G')) {
            return true;
        }
    }
    return false;
}

// One system font manager, for <text> inside SVG documents. Without it Skia
// renders SVG text as nothing at all, silently. Most icons are pure shapes, but
// a logo or a wallpaper is exactly where text shows up, and fontconfig is
// already linked.
sk_sp<SkFontMgr> svgFontManager() {
    static sk_sp<SkFontMgr> manager =
        SkFontMgr_New_FontConfig(nullptr, SkFontScanner_Make_FreeType());
    return manager;
}

// A vector has no natural size, so an unbounded SVG needs *a* raster size and
// there is no correct one to pick. This is the size used when the document
// declares no absolute dimensions and the caller asked for no bounds.
constexpr int32_t kDefaultSvgRasterSize = 512;

// Rasterize an SVG at the size it will be drawn.
//
// This is where decode bounds stop being an optimization and become
// correctness: rasterizing at the wrong size and rescaling throws away the one
// advantage a vector has.
Image rasterizeSvg(const sk_sp<SkData> &data, int32_t maxWidth, int32_t maxHeight) {
    auto stream = SkMemoryStream::Make(data);
    sk_sp<SkSVGDOM> dom = SkSVGDOM::Builder()
                              .setFontManager(svgFontManager())
                              .make(*stream);
    if (!dom) return Image(nullptr);

    // The document's own size, when it states one in absolute units. Relative
    // units ("100%") resolve to zero here, which is the document saying it will
    // take whatever it is given.
    SkSize intrinsic = dom->containerSize();

    float width = 0;
    float height = 0;
    if (maxWidth > 0 && maxHeight > 0) {
        if (intrinsic.width() > 0 && intrinsic.height() > 0) {
            // Fit the document's aspect ratio inside the box, matching how a
            // bitmap of the same shape would be bounded.
            float scale = std::min(static_cast<float>(maxWidth) / intrinsic.width(),
                                   static_cast<float>(maxHeight) / intrinsic.height());
            width = intrinsic.width() * scale;
            height = intrinsic.height() * scale;
        } else {
            width = static_cast<float>(maxWidth);
            height = static_cast<float>(maxHeight);
        }
    } else if (intrinsic.width() > 0 && intrinsic.height() > 0) {
        width = intrinsic.width();
        height = intrinsic.height();
    } else {
        width = kDefaultSvgRasterSize;
        height = kDefaultSvgRasterSize;
    }

    int32_t pixelWidth = std::max(1, static_cast<int32_t>(std::lround(width)));
    int32_t pixelHeight = std::max(1, static_cast<int32_t>(std::lround(height)));

    SkImageInfo info = SkImageInfo::Make(pixelWidth, pixelHeight, kRGBA_8888_SkColorType,
                                         kPremul_SkAlphaType, SkColorSpace::MakeSRGB());
    sk_sp<SkSurface> surface = SkSurfaces::Raster(info);
    if (!surface) return Image(nullptr);
    // Transparent, not opaque: an icon is a shape on whatever is behind it.
    surface->getCanvas()->clear(SK_ColorTRANSPARENT);

    if (intrinsic.width() > 0 && intrinsic.height() > 0) {
        // A document sized in absolute units has a fixed viewport, and
        // `setContainerSize` cannot move it — so scaling the canvas is the only
        // thing that scales the drawing. Setting the container size alone
        // renders the document at 1:1 and crops it to the surface, which looks
        // right for any art that happens to fill its viewport and wrong for
        // everything else.
        surface->getCanvas()->scale(width / intrinsic.width(), height / intrinsic.height());
        dom->setContainerSize(intrinsic);
    } else {
        // Relative units resolve against whatever viewport they are given, so
        // here the container size is the whole mechanism.
        dom->setContainerSize(SkSize::Make(width, height));
    }
    dom->render(surface->getCanvas());
    return wrapImage(surface->makeImageSnapshot());
}

}  // namespace

namespace {

// The shared body of every encoded decode, whether the bytes came from a file or
// from memory. A `data:` URI holds exactly what a file holds, so it must decode
// exactly the same way.
Image decodeEncodedData(sk_sp<SkData> data, int32_t maxWidth, int32_t maxHeight) {
    if (!data) return Image(nullptr);

    // SVG has its own path: there is nothing to decode, only something to draw,
    // and it must be drawn at the size it will be shown.
    if (looksLikeSvg(data)) return rasterizeSvg(data, maxWidth, maxHeight);

    // Unbounded stays deferred: nothing is known about the draw size, so there
    // is nothing to decide and no reason to decode before the first draw.
    if (maxWidth <= 0 || maxHeight <= 0) {
        return wrapImage(SkImages::DeferredFromEncodedData(std::move(data)));
    }

    std::unique_ptr<SkCodec> codec = SkCodec::MakeFromData(std::move(data));
    if (!codec) return Image(nullptr);

    SkISize full = codec->dimensions();
    if (full.isEmpty()) return Image(nullptr);
    float scale = std::min(static_cast<float>(maxWidth) / static_cast<float>(full.width()),
                           static_cast<float>(maxHeight) / static_cast<float>(full.height()));

    // Already inside the box. Enlarging to fill it would burn memory to blur.
    if (scale >= 1.0f) {
        SkBitmap bitmap;
        if (!bitmap.tryAllocPixels(decodeInfo(*codec, full.width(), full.height()))) {
            return Image(nullptr);
        }
        if (codec->getPixels(bitmap.pixmap()) != SkCodec::kSuccess) return Image(nullptr);
        bitmap.setImmutable();
        return wrapImage(SkImages::RasterFromBitmap(bitmap));
    }

    // Ask the codec what it can decode natively — JPEG scales during the DCT,
    // which is both faster and better than decoding full and resampling. The
    // answer is never smaller than asked for, so a resample may still follow.
    SkISize decoded = codec->getScaledDimensions(scale);
    SkBitmap bitmap;
    if (!bitmap.tryAllocPixels(decodeInfo(*codec, decoded.width(), decoded.height()))) {
        return Image(nullptr);
    }
    if (codec->getPixels(bitmap.pixmap()) != SkCodec::kSuccess) return Image(nullptr);
    bitmap.setImmutable();

    sk_sp<SkImage> image = SkImages::RasterFromBitmap(bitmap);
    if (!image) return Image(nullptr);

    int32_t targetWidth = std::max(1, static_cast<int32_t>(std::lround(full.width() * scale)));
    int32_t targetHeight = std::max(1, static_cast<int32_t>(std::lround(full.height() * scale)));
    if (decoded.width() <= targetWidth && decoded.height() <= targetHeight) {
        return wrapImage(std::move(image));
    }

    sk_sp<SkImage> resized = linearDownscale(image, targetWidth, targetHeight);
    // A failed resample is a memory failure, not a decode failure — the
    // correctly-decoded oversized image beats showing nothing.
    return wrapImage(resized ? std::move(resized) : std::move(image));
}

}  // namespace

Image makeEncodedImageFromFile(const char *path, int32_t maxWidth, int32_t maxHeight) {
    if (path == nullptr || path[0] == '\0') return Image(nullptr);
    return decodeEncodedData(SkData::MakeFromFileName(path), maxWidth, maxHeight);
}

Image makeEncodedImageFromMemory(
    const uint8_t *bytes, size_t byteLength, int32_t maxWidth, int32_t maxHeight) {
    if (bytes == nullptr || byteLength == 0) return Image(nullptr);
    return decodeEncodedData(
        SkData::MakeWithCopy(bytes, byteLength), maxWidth, maxHeight);
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

void Canvas::drawPath(const Path &path, Paint paint) const {
    if (!isValid()) return;
    Path::Impl *p = path.raw();
    if (p == nullptr) return;
    impl_->canvas->drawPath(p->path, toSkPaint(paint));
}

void Canvas::drawPathWithShader(const Path &path, const Shader &shader, Paint paint) const {
    if (!isValid()) return;
    Path::Impl *p = path.raw();
    Shader::Impl *sh = shader.raw();
    if (p == nullptr || sh == nullptr || sh->shader == nullptr) return;
    SkPaint sk = toSkPaint(paint);
    sk.setShader(sh->shader);
    impl_->canvas->drawPath(p->path, sk);
}

void Canvas::clipPath(const Path &path, bool antialias) const {
    if (!isValid()) return;
    Path::Impl *p = path.raw();
    if (p == nullptr) return;
    impl_->canvas->clipPath(p->path, SkClipOp::kIntersect, antialias);
}

void Canvas::clipPathTransformed(
    const Path &path, const float matrix[9], bool antialias) const {
    if (!isValid() || matrix == nullptr) return;
    Path::Impl *p = path.raw();
    if (p == nullptr) return;
    const SkMatrix transform = SkMatrix::MakeAll(
        matrix[0], matrix[1], matrix[2],
        matrix[3], matrix[4], matrix[5],
        matrix[6], matrix[7], matrix[8]);
    const SkPath mapped = p->path.makeTransform(transform);
    impl_->canvas->clipPath(mapped, SkClipOp::kIntersect, antialias);
}

void Canvas::concat(const float m[9]) const {
    if (!isValid() || m == nullptr) return;
    impl_->canvas->concat(
        SkMatrix::MakeAll(m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8]));
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

bool Surface::readPixelsRGBA(uint8_t *dst, size_t byteLength, int32_t rowBytes) const {
    if (!isValid() || dst == nullptr) return false;
    const SkImageInfo info = SkImageInfo::Make(
        impl_->surface->width(), impl_->surface->height(),
        kRGBA_8888_SkColorType, kPremul_SkAlphaType);
    const size_t stride = rowBytes > 0 ? static_cast<size_t>(rowBytes) : info.minRowBytes();
    if (byteLength < stride * static_cast<size_t>(info.height())) return false;
    return impl_->surface->readPixels(info, dst, stride, 0, 0);
}

Surface makeRasterSurface(int32_t width, int32_t height) {
    if (width <= 0 || height <= 0) return Surface(nullptr);
    const SkImageInfo info = SkImageInfo::Make(
        width, height, kRGBA_8888_SkColorType, kPremul_SkAlphaType);
    auto impl = std::make_shared<Surface::Impl>();
    impl->surface = SkSurfaces::Raster(info);
    if (!impl->surface) return Surface(nullptr);
    return Surface(std::move(impl));
}

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

Status GraphiteContext::submitAsync(
    const Recording &recording, uint64_t submissionSerial) const {
    if (!isValid() || submissionSerial == 0) return Status::invalidArgument;
    Recording::Impl *rec = recording.raw();
    if (!rec || !rec->recording) return Status::invalidArgument;

    skgpu::graphite::InsertRecordingInfo info;
    info.fRecording = rec->recording.get();
    attachSubmissionCompletion(
        info, impl_->submissionCompletion, submissionSerial);
    if (!impl_->context->insertRecording(info)) return Status::recordingFailed;
    if (!impl_->context->submit(skgpu::graphite::SyncToCpu::kNo)) {
        return Status::submitFailed;
    }
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

struct SurfaceReadback::Impl {
    std::atomic<bool> done{false};
    int32_t width = 0;
    int32_t height = 0;
    std::mutex mutex;
    std::unique_ptr<const SkImage::AsyncReadResult> result;
};

SurfaceReadback::SurfaceReadback(std::shared_ptr<Impl> impl)
    : impl_(std::move(impl)) {}

bool SurfaceReadback::isValid() const { return impl_ != nullptr; }

bool SurfaceReadback::isComplete() const {
    return impl_ && impl_->done.load(std::memory_order_acquire);
}

Status SurfaceReadback::copyPixels(
    uint8_t *dst, size_t byteLength, int32_t rowBytes) const {
    if (!isComplete() || dst == nullptr) return Status::invalidArgument;
    if (impl_->width <= 0 || impl_->height <= 0) {
        return Status::invalidArgument;
    }
    const size_t width = static_cast<size_t>(impl_->width);
    const size_t height = static_cast<size_t>(impl_->height);
    if (width > std::numeric_limits<size_t>::max() / 4) {
        return Status::invalidArgument;
    }
    const size_t tightStride = width * 4;
    const size_t stride = rowBytes > 0
        ? static_cast<size_t>(rowBytes) : tightStride;
    if (stride < tightStride || height > std::numeric_limits<size_t>::max() / stride ||
        byteLength < stride * height) {
        return Status::invalidArgument;
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (!impl_->result || impl_->result->count() < 1) {
        return Status::submitFailed;
    }
    const auto *src = static_cast<const uint8_t *>(impl_->result->data(0));
    const size_t srcStride = impl_->result->rowBytes(0);
    if (src == nullptr || srcStride < tightStride) {
        return Status::submitFailed;
    }
    for (int y = 0; y < impl_->height; ++y) {
        std::memcpy(dst + static_cast<size_t>(y) * stride,
                    src + static_cast<size_t>(y) * srcStride,
                    tightStride);
    }
    return Status::ok;
}

namespace {
SurfaceReadback beginSurfaceReadback(
    skgpu::graphite::Context *context,
    const Surface &surface,
    SkColorType colorType,
    int32_t x = 0,
    int32_t y = 0,
    int32_t requestedWidth = 0,
    int32_t requestedHeight = 0) {
    if (context == nullptr) return SurfaceReadback(nullptr);
    Surface::Impl *s = surface.raw();
    if (s == nullptr || !s->surface) return SurfaceReadback(nullptr);

    const int surfaceWidth = s->surface->width();
    const int surfaceHeight = s->surface->height();
    const int w = requestedWidth > 0 ? requestedWidth : surfaceWidth;
    const int h = requestedHeight > 0 ? requestedHeight : surfaceHeight;
    if (surfaceWidth <= 0 || surfaceHeight <= 0 || x < 0 || y < 0 ||
        w <= 0 || h <= 0 || x > surfaceWidth - w || y > surfaceHeight - h) {
        return SurfaceReadback(nullptr);
    }
    const SkImageInfo info = SkImageInfo::Make(
        w, h, colorType, kPremul_SkAlphaType);
    auto state = std::make_shared<SurfaceReadback::Impl>();
    state->width = w;
    state->height = h;
    auto *box = new std::shared_ptr<SurfaceReadback::Impl>(state);
    auto callback = [](SkImage::ReadPixelsContext context,
                       std::unique_ptr<const SkImage::AsyncReadResult> result) {
        std::unique_ptr<std::shared_ptr<SurfaceReadback::Impl>> owner(
            static_cast<std::shared_ptr<SurfaceReadback::Impl> *>(context));
        {
            std::lock_guard<std::mutex> lock((*owner)->mutex);
            (*owner)->result = std::move(result);
        }
        (*owner)->done.store(true, std::memory_order_release);
    };
    context->asyncRescaleAndReadPixels(
        s->surface.get(), info, SkIRect::MakeXYWH(x, y, w, h),
        SkImage::RescaleGamma::kSrc, SkImage::RescaleMode::kNearest,
        callback, box);
    if (!context->submit(skgpu::graphite::SyncToCpu::kNo)) {
        return SurfaceReadback(nullptr);
    }
    return SurfaceReadback(std::move(state));
}
}  // namespace

SurfaceReadback GraphiteContext::beginSurfaceReadbackRGBA(
    const Surface &surface) const {
    return beginSurfaceReadback(
        isValid() ? impl_->context.get() : nullptr,
        surface,
        kRGBA_8888_SkColorType);
}

SurfaceReadback GraphiteContext::beginSurfaceReadbackBGRA(
    const Surface &surface) const {
    return beginSurfaceReadback(
        isValid() ? impl_->context.get() : nullptr,
        surface,
        kBGRA_8888_SkColorType);
}

SurfaceReadback GraphiteContext::beginSurfaceReadbackBGRARegion(
    const Surface &surface, int32_t x, int32_t y,
    int32_t width, int32_t height) const {
    return beginSurfaceReadback(
        isValid() ? impl_->context.get() : nullptr,
        surface,
        kBGRA_8888_SkColorType,
        x, y, width, height);
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
