// NucleusSkiaGraphite — a C++ façade over Skia Graphite (Vulkan backend)
// designed for Swift C++ interoperability (Phase 10b.3).
//
// Replaces the `void *` surface of render-cxx/skia/skia_render_bridge.h
// with concrete typed classes. `sk_sp`, `std::unique_ptr`, Skia templates, and
// raw Skia/Vulkan headers stay private to Graphite.cpp; this header exposes only
// Swift-friendly value types (each façade is a small handle holding a shared
// pointer to its hidden Impl). Exceptions are disabled across the boundary;
// failures surface as `Status` / `isValid()` rather than throws.
//
// 10b.3 landed the context-from-Vulkan + recording round-trip (context →
// recorder → offscreen surface → canvas → image snapshot → recording → submit).
// 10b.4a extends the draw vocabulary the Graphite-native renderer composites
// through: a `Paint` value type (alpha, blend mode, Gaussian blur, saturation),
// save/restore/saveLayer + clip rect/rrect, source-rect image draws, a
// runtime-effect `Shader` (foreground vibrancy), and raster readback. The
// backend-texture `Image` (wrapping an imported DMA-BUF `VkImage`) binds in
// 10b.4c alongside the texture registry that imports it.

#pragma once

#include <cstdint>
#include <memory>

namespace nucleus::skia {

/// Borrowed Vulkan handles for Graphite context creation. Every pointer is
/// borrowed: the façade never destroys the instance, device, or queue. The
/// extension name arrays must outlive the `makeGraphiteVulkanContext` call only.
struct VulkanContextDescriptor {
    void *instance = nullptr;        // VkInstance
    void *physicalDevice = nullptr;  // VkPhysicalDevice
    void *device = nullptr;          // VkDevice
    void *queue = nullptr;           // VkQueue
    uint32_t graphicsQueueIndex = 0;
    uint32_t maxApiVersion = 0;
    const char *const *instanceExtensions = nullptr;
    uint32_t instanceExtensionCount = 0;
    const char *const *deviceExtensions = nullptr;
    uint32_t deviceExtensionCount = 0;
};

/// Typed result of a fallible façade operation.
enum class Status : int32_t {
    ok = 0,
    contextCreationFailed = 1,
    surfaceCreationFailed = 2,
    recordingFailed = 3,
    submitFailed = 4,
    invalidArgument = 5,
};

struct Color {
    float r = 0;
    float g = 0;
    float b = 0;
    float a = 1;
};

struct RectF {
    float x = 0;
    float y = 0;
    float width = 0;
    float height = 0;
};

/// Per-corner rounded-rect radii in destination pixels (mirrors the FramePlan
/// `RRectMask` corner layout). All-zero radii degrade to a plain rect.
struct RRectRadii {
    float topLeft = 0;
    float topRight = 0;
    float bottomRight = 0;
    float bottomLeft = 0;
};

/// A filled rounded rectangle with independently colored inset border edges.
/// Border widths are measured inward from `rect`; negative widths clamp to zero.
struct StyledRRect {
    RectF rect;
    RRectRadii radii;
    Color background;
    float borderTopWidth = 0;
    float borderRightWidth = 0;
    float borderBottomWidth = 0;
    float borderLeftWidth = 0;
    Color borderTopColor;
    Color borderRightColor;
    Color borderBottomColor;
    Color borderLeftColor;
};

/// The Porter-Duff / separable blend subset the compositor uses. Mirrors the
/// `FramePlan` quad blend modes; lowered to `SkBlendMode` at the draw call.
enum class BlendMode : int32_t {
    srcOver = 0,
    src = 1,
    multiply = 2,
    screen = 3,
    plus = 4,
    overlay = 5,
    dstIn = 6,
    dstOut = 7,
};

class Shader;

enum class PaintStyle : int32_t {
    fill = 0,
    stroke = 1,
    strokeAndFill = 2,
};

enum class StrokeCap : int32_t {
    butt = 0,
    round = 1,
    square = 2,
};

enum class StrokeJoin : int32_t {
    miter = 0,
    round = 1,
    bevel = 2,
};

/// Value-type draw parameters for the composite. POD + an optional `Shader`
/// reference passed alongside the draw (kept out of the struct so it stays
/// trivially copyable across the interop boundary). `blurSigma > 0` attaches a
/// Gaussian blur image filter; `saturation != 1` attaches a saturation color
/// matrix — both used by the backdrop path.
struct Paint {
    Color color;          // default opaque black; the fill/tint color
    float alpha = 1;      // multiplies the source alpha
    BlendMode blend = BlendMode::srcOver;
    bool antialias = true;
    float blurSigma = 0;  // > 0 → Gaussian blur image filter
    float saturation = 1; // != 1 → saturation color matrix
    // Recolour an image by its alpha, preserving shape and dropping colour.
    // Applies to image draws; a shape already paints in `color`.
    bool tintsImage = false;
    // Stroke parameters. `style` defaults to fill, which is why a command
    // carrying only a `strokeWidth` used to paint solid.
    PaintStyle style = PaintStyle::fill;
    float strokeWidth = 0;
    StrokeCap strokeCap = StrokeCap::butt;
    StrokeJoin strokeJoin = StrokeJoin::miter;
    float miter = 4;
};

class Recorder;
class Recording;
class Surface;
class Canvas;
class Image;
class UploadTexture;

/// A GPU-backed image snapshot. Holds a graphite-backed SkImage privately.
class Image {
public:
    struct Impl;
    explicit Image(std::shared_ptr<Impl> impl);
    bool isValid() const;
    int32_t width() const;
    int32_t height() const;

    /// Read the image's pixels into `dst` as tightly-packed (or `rowBytes`-strided)
    /// RGBA8888 premultiplied. Synchronous; valid for raster images (the GPU
    /// surface readback used for screenshots binds in 10b.4i). Returns false on a
    /// size mismatch or an unreadable (GPU-only) image.
    bool readPixelsRGBA(uint8_t *dst, size_t byteLength, int32_t rowBytes) const;

    // Internal: the canvas draw path reads the held SkImage.
    Impl *raw() const;

private:
    std::shared_ptr<Impl> impl_;
};

/// A Graphite-owned, sampleable RGBA8 backend texture whose pixels can be
/// replaced through a dedicated recorder. Copyable facade values share the
/// texture; its backend allocation is deleted when the last value/image drops.
class UploadTexture {
public:
    struct Impl;
    explicit UploadTexture(std::shared_ptr<Impl> impl);
    bool isValid() const;
    int32_t width() const;
    int32_t height() const;
    bool updateRGBA(const uint8_t *pixels, size_t byteLength) const;
    Image image() const;

private:
    std::shared_ptr<Impl> impl_;
};

/// An SkSL runtime-effect shader (the foreground-vibrancy material). Holds an
/// `sk_sp<SkShader>` privately; value-semantic and copyable for Swift.
class Shader {
public:
    struct Impl;
    explicit Shader(std::shared_ptr<Impl> impl);
    bool isValid() const;

    // Internal: the canvas shader-draw path reads the held SkShader.
    Impl *raw() const;

private:
    std::shared_ptr<Impl> impl_;
};

/// How a gradient extends past its defined span.
enum class TileMode : int32_t {
    clamp = 0,
    repeatTile = 1,
    mirror = 2,
    decal = 3,
};

/// Build a gradient shader. `colors` and `stops` are parallel arrays of
/// `count` entries; a null `stops` distributes the colors evenly. Returned
/// invalid on a null/short array or `count < 2`.
Shader makeLinearGradient(
    float x0, float y0, float x1, float y1,
    const Color *colors, const float *stops, size_t count, TileMode tile);
Shader makeRadialGradient(
    float centerX, float centerY, float radius,
    const Color *colors, const float *stops, size_t count, TileMode tile);
Shader makeSweepGradient(
    float centerX, float centerY, float startAngle, float endAngle,
    const Color *colors, const float *stops, size_t count, TileMode tile);

/// A path verb. Each verb consumes a fixed number of points from the parallel
/// point array: `move`/`line` one, `quad` two, `cubic` three, `close` none.
/// `arcTo` consumes three — the oval's origin, the oval's size, and
/// `(startAngle, sweepAngle)` in degrees. There is deliberately no `drawArc`
/// facade call: an arc is a path verb, so a spinner or a countdown ring is a
/// stroked path rather than a bespoke primitive.
enum class PathVerb : uint8_t {
    move = 0,
    line = 1,
    quad = 2,
    cubic = 3,
    arcTo = 4,
    close = 5,
};

/// An immutable geometry path. Holds an `SkPath` privately; value-semantic and
/// copyable for Swift, following the `Shader` pattern.
class Path {
public:
    struct Impl;
    explicit Path(std::shared_ptr<Impl> impl);
    bool isValid() const;

    // Internal: the canvas path-draw path reads the held SkPath.
    Impl *raw() const;

private:
    std::shared_ptr<Impl> impl_;
};

/// Build a path from a verb array plus a flat point array (`pointCount` is a
/// count of *floats*, two per point). `evenOdd` selects the even-odd fill type
/// instead of winding. Returned invalid if the verbs consume more points than
/// were supplied — a malformed encoding fails loudly rather than drawing
/// partial geometry.
Path makePath(
    const uint8_t *verbs, size_t verbCount,
    const float *points, size_t pointCount, bool evenOdd);

/// A compiled SkSL program. Compilation is the expensive half of building a
/// runtime-effect shader and does not depend on uniform values, so it is split
/// out and cached behind a handle: uniforms change every frame, the program
/// does not. Holds an `sk_sp<SkRuntimeEffect>` privately.
class RuntimeEffect {
public:
    struct Impl;
    explicit RuntimeEffect(std::shared_ptr<Impl> impl);
    bool isValid() const;

    /// Bind `uniformFloatCount` floats in declaration order and produce a
    /// drawable shader. Invalid if the uniform byte size does not match.
    Shader makeShader(const float *uniforms, size_t uniformFloatCount) const;

    /// As `makeShader`, additionally binding `child` as the program's single
    /// child shader (declared `uniform shader …;`).
    Shader makeShaderWithImage(
        const float *uniforms, size_t uniformFloatCount, const Image &child) const;

    Impl *raw() const;

private:
    std::shared_ptr<Impl> impl_;
};

/// Compile an SkSL shader source. Returns an invalid effect if it fails to
/// compile. Compilation is GPU-independent, so this is verifiable headless.
RuntimeEffect makeRuntimeEffect(const char *sksl);

/// Compile an SkSL shader source and bind `uniformFloatCount` float uniforms in
/// declaration order. Returns an invalid shader if the source fails to compile or
/// the uniform byte size does not match. Compilation is GPU-independent, so this
/// is verifiable headless.
Shader makeRuntimeShader(const char *sksl, const float *uniforms, size_t uniformFloatCount);

/// Like `makeRuntimeShader`, but binds `child` as the effect's single child
/// shader (declared `uniform shader …;`) — the foreground-vibrancy material
/// samples the backdrop content this way. Invalid if the source declares other
/// than exactly one child, fails to compile, or the uniform size mismatches.
Shader makeRuntimeShaderWithImage(
    const char *sksl, const float *uniforms, size_t uniformFloatCount, const Image &child);

/// Install the resolver the render core uses to turn a text-layout handle into a
/// borrowed `skia::textlayout::Paragraph*` (returned as `uintptr_t`; 0 if
/// unknown), which `Canvas::drawTextLayout` paints directly. The text backend
/// installs this once at startup; the render core has no compile-time dependency
/// on it (dependency inversion — the render core owns the seam, the text layer
/// provides the implementation). Idempotent; last writer wins.
extern "C" void nucleus_skia_set_text_layout_resolver(uintptr_t (*resolve)(uint64_t));

/// A non-owning view of a surface's canvas. Drawing commands are recorded into
/// the surface's recorder until the next recording snap.
class Canvas {
public:
    struct Impl;
    explicit Canvas(std::shared_ptr<Impl> impl);
    bool isValid() const;
    void clear(Color color) const;

    // --- Save / clip stack ---
    void save() const;
    void restore() const;
    /// Begin a transparency layer bounded by `bounds` (whole canvas if
    /// `bounds.width <= 0`), composited at `alpha` on `restore`.
    void saveLayerAlpha(RectF bounds, float alpha) const;
    void clipRect(RectF rect, bool antialias) const;
    void clipRRect(RectF rect, RRectRadii radii, bool antialias) const;
    void clipPath(const Path &path, bool antialias) const;

    // --- Transform ---
    /// Concatenate a row-major 3x3 matrix. `translate`/`scale`/`rotate` are all
    /// expressible through this, so the facade carries only the general form.
    void concat(const float m[9]) const;

    // --- Draws (Paint-carrying) ---
    void drawRect(RectF rect, Paint paint) const;
    void drawRRect(RectF rect, RRectRadii radii, Paint paint) const;
    /// Draw the layer visual-style primitive. The border is the area between the
    /// outer and inset inner rounded rectangles, partitioned into four edge
    /// regions so unequal widths and colors remain exact at the corners.
    void drawStyledRRect(StyledRRect style, float alpha) const;
    /// Draw `src` region of `image` into `dst`. A zero-size `src` draws the whole
    /// image. Honors the paint's alpha, blend mode, blur, and saturation.
    void drawImageRect(const Image &image, RectF src, RectF dst, Paint paint) const;
    /// Fill `rect` with a runtime-effect shader (vibrancy), modulated by the paint.
    void drawShaderRect(RectF rect, const Shader &shader, Paint paint) const;
    /// Fill or stroke `path` per the paint's style.
    void drawPath(const Path &path, Paint paint) const;
    /// Draw `path` with `shader` bound. Unifies gradients and SkSL effects —
    /// both are "a Shader bound to a draw".
    void drawPathWithShader(const Path &path, const Shader &shader, Paint paint) const;
    /// Paint the text-layout paragraph named by `handle` into `dst`. The render
    /// core resolves the handle to a borrowed `skia::textlayout::Paragraph*` via
    /// the resolver installed with `nucleus_skia_set_text_layout_resolver` and
    /// paints it directly. A zero/unknown handle (or no installed resolver) is
    /// ignored; alpha modulates the paragraph's own colors; the paragraph is
    /// scaled from its laid-out width to `dst`'s width.
    void drawTextLayout(uint64_t handle, RectF dst, float alpha) const;

    // --- Convenience overloads (color-only; preserved from 10b.3) ---
    void drawRect(RectF rect, Color color) const;
    void drawImage(const Image &image, RectF dst, float alpha) const;
    void drawRoundRect(RectF rect, float radius, Color color) const;

private:
    std::shared_ptr<Impl> impl_;
};

/// Make a raster RGBA8888 image from CPU pixels (tightly packed, premultiplied).
/// Returned invalid on a size/argument error.
Image makeRasterImageRGBA(int32_t width, int32_t height, const uint8_t *pixels, size_t byteLength);

/// Decode an encoded image file into an SkImage, at most `maxWidth` x
/// `maxHeight`. Returned invalid on missing, unreadable, or unsupported files.
///
/// A zero bound means unbounded on that axis, which decodes deferred (Skia
/// decodes on first draw) exactly as an unbounded decode always has. A bounded
/// decode is eager, because the whole point is to never hold the full-size
/// pixels: a 4K wallpaper and a 22px tray icon must not cost the same.
///
/// Aspect ratio is preserved — the bound is a box the result fits inside, not
/// the result's size.
Image makeEncodedImageFromFile(const char *path, int32_t maxWidth, int32_t maxHeight);

/// Decode encoded image bytes already in memory — a `data:` URI, or any blob
/// with no path to point at. Same formats, same bounds behaviour, same SVG
/// detection as the file entry point.
Image makeEncodedImageFromMemory(
    const uint8_t *bytes, size_t byteLength, int32_t maxWidth, int32_t maxHeight);

/// A borrowed Vulkan image to wrap as a Graphite-sampleable `Image` (an imported
/// client DMA-BUF or a compositor render texture). The façade never owns the
/// image or its memory — the Swift `VkOwned` owner outlives the wrap. Mirrors
/// the fields `BackendTextures::MakeVulkan` + `VulkanTextureInfo` require.
struct VulkanImageDescriptor {
    void *image = nullptr;          // VkImage (borrowed)
    void *memory = nullptr;         // VkDeviceMemory (borrow semantics; may be null for RTs)
    uint64_t allocSize = 0;         // bound memory size (0 → indeterminate / borrowed)
    uint32_t format = 0;            // VkFormat
    int32_t width = 0;
    int32_t height = 0;
    uint32_t imageTiling = 0;       // VkImageTiling
    uint32_t imageLayout = 0;       // current VkImageLayout
    uint32_t imageUsageFlags = 0;   // VkImageUsageFlags
    uint32_t sampleCount = 1;       // VkSampleCountFlagBits (1 for scanout/imports)
    uint32_t queueFamilyIndex = 0;  // VK_QUEUE_FAMILY_FOREIGN_EXT / _IGNORED for imports
    bool hasAlpha = true;           // premultiplied RGBA vs opaque
};

/// A Graphite render target. Offscreen here; window/scanout targets bind in 10b.5.
class Surface {
public:
    struct Impl;
    explicit Surface(std::shared_ptr<Impl> impl);
    bool isValid() const;
    int32_t width() const;
    int32_t height() const;
    Canvas getCanvas() const;
    Image snapshotImage() const;
    /// Read the surface's pixels as tightly-packed (or `rowBytes`-strided)
    /// RGBA8888 premultiplied. Valid for CPU raster surfaces; a GPU-backed
    /// surface reads back through `GraphiteContext::readSurfaceRGBA` instead.
    bool readPixelsRGBA(uint8_t *dst, size_t byteLength, int32_t rowBytes) const;

    // Internal: the context readback path reads the held SkSurface.
    Impl *raw() const;

private:
    std::shared_ptr<Impl> impl_;
};

/// Make a CPU raster render target. Needs no Graphite context or GPU, so the
/// drawing façade — paths, strokes, gradients, blend modes — is verifiable
/// headless, the same property `makeRuntimeShader` already has.
Surface makeRasterSurface(int32_t width, int32_t height);

/// An immutable recorded sequence of GPU work, produced by `Recorder::snap`.
class Recording {
public:
    struct Impl;
    explicit Recording(std::shared_ptr<Impl> impl);
    bool isValid() const;

    // Internal: the context's submit path reads the held recording.
    Impl *raw() const;

private:
    std::shared_ptr<Impl> impl_;
};

/// Records drawing into surfaces and snaps the result into a Recording.
class Recorder {
public:
    struct Impl;
    explicit Recorder(std::shared_ptr<Impl> impl);
    bool isValid() const;
    Surface makeOffscreenSurface(int32_t width, int32_t height) const;
    /// Allocate a non-renderable sampled RGBA8 texture. `updateRGBA` records its
    /// transfer into this recorder; callers must snap and submit before sampling.
    UploadTexture makeUploadTextureRGBA(int32_t width, int32_t height) const;
    /// Wrap a borrowed Vulkan image as a sampleable `Image` (DMA-BUF import /
    /// compositor render texture). Invalid on an unusable descriptor.
    Image wrapBackendImage(const VulkanImageDescriptor &descriptor) const;
    /// Wrap a borrowed Vulkan image as a render-target `Surface` — the GBM scanout
    /// BO the compositor composites into and KMS flips. The façade never owns the
    /// image or its memory; the Swift owner outlives the surface. Invalid on an
    /// unusable descriptor (10b.6d). The `VulkanImageDescriptor.imageUsageFlags`
    /// must include `VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT`.
    Surface wrapBackendSurface(const VulkanImageDescriptor &descriptor) const;
    Recording snapRecording() const;

private:
    std::shared_ptr<Impl> impl_;
};

/// The Graphite context bound to a borrowed Swift-owned Vulkan device. Owns the
/// Skia Vulkan interface/allocator/context; never destroys the Vulkan handles.
class GraphiteContext {
public:
    struct Impl;
    explicit GraphiteContext(std::shared_ptr<Impl> impl);
    bool isValid() const;
    /// Release Skia's Graphite context, Vulkan allocator, and interface while the
    /// borrowed Vulkan device is still alive. Idempotent.
    void reset();
    Recorder makeRecorder() const;
    /// Insert a recording and submit, syncing to the CPU. Returns ok on success.
    Status submit(const Recording &recording) const;
    /// Insert upload work before frame work and submit them as one ordered GPU
    /// batch, syncing to the CPU (compatibility and test use).
    Status submitWithUpload(const Recording &upload, const Recording &frame) const;
    /// Insert frame work (and optional preceding upload work), signal the borrowed
    /// Vulkan binary semaphore, and submit without waiting on the CPU. The Linux
    /// DRM backend exports that semaphore as a sync_file for KMS IN_FENCE_FD.
    Status submitWithSemaphores(
        const Recording &recording, void *const *waitSemaphores,
        size_t waitSemaphoreCount, void *signalSemaphore,
        uint64_t submissionSerial) const;
    Status submitWithUploadAndSemaphores(
        const Recording &upload, const Recording &frame, void *const *waitSemaphores,
        size_t waitSemaphoreCount, void *signalSemaphore,
        uint64_t submissionSerial) const;
    /// Submit a recording that renders into a Vulkan swapchain image for
    /// presentation (the Android WSI path): the GPU work waits on `waitSemaphore`
    /// (the swapchain acquire) before executing and signals `signalSemaphore` (the
    /// present wait) when done, and `targetSurface`'s image is transitioned to
    /// `VK_IMAGE_LAYOUT_PRESENT_SRC_KHR` on `presentQueueFamily`. Does NOT sync to
    /// the CPU — `vkQueuePresentKHR` orders against `signalSemaphore`. The semaphore
    /// args are `VkSemaphore` handles as `void *` (0/null skips that semaphore).
    /// Returns ok on success.
    Status submitForPresent(
        const Surface &targetSurface, const Recording &recording,
        void *const *waitSemaphores, size_t waitSemaphoreCount,
        void *signalSemaphore, uint32_t presentQueueFamily,
        uint64_t submissionSerial) const;
    Status submitForPresentWithUpload(
        const Surface &targetSurface, const Recording &upload, const Recording &frame,
        void *const *waitSemaphores, size_t waitSemaphoreCount,
        void *signalSemaphore, uint32_t presentQueueFamily,
        uint64_t submissionSerial) const;
    /// Poll internal submission fences without waiting and return the greatest
    /// serial whose GPU-finished callback has completed.
    uint64_t pollCompletedSubmissionSerial() const;
    /// Poll completion and consume the Vulkan timestamp-query duration for exactly
    /// `submissionSerial`. Returns zero when that submission has not completed or
    /// elapsed-time queries are unavailable. Consumption is exact-keyed because
    /// different outputs may deliver pageflips out of submission-serial order.
    uint64_t takeCompletedSubmissionGpuElapsedNs(uint64_t submissionSerial) const;
    /// Read `surface`'s full extent into `dst` as RGBA8888 premultiplied (the
    /// screenshot/screencopy raw readback). Synchronous: issues the Graphite async
    /// read then drains it under a CPU sync. Returns ok on success.
    Status readSurfaceRGBA(const Surface &surface, uint8_t *dst, size_t byteLength, int32_t rowBytes) const;

private:
    std::shared_ptr<Impl> impl_;
};

/// Create a Graphite context over the borrowed Vulkan handles. The returned
/// context is invalid (`isValid() == false`) if creation failed; no exception
/// is thrown.
GraphiteContext makeGraphiteVulkanContext(const VulkanContextDescriptor &descriptor);

}  // namespace nucleus::skia
