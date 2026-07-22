// `TextureRegistry` maps an opaque texture handle (the raw
// `FramePlan` `TextureHandle.raw`) to a sampleable Skia `Image`, with a content
// revision (so a producer can skip re-upload of unchanged content) and a
// refcount (governing eviction). Small paint/decoration nodes pack into a
// guillotine atlas; live client SHM content uses Graphite-owned mutable backend
// textures staged by FrameDriver; client DMA-BUFs wrap borrowed backend textures.
//
// The allocator, atlas, and registry bookkeeping are pure and tested
// hardware-independently (raster images need no GPU). The façade backend-texture
// wrap (`wrapBackendImage`) compiles here; the live DMA-BUF import and Vulkan
// ownership remain in the renderer.

import VulkanC
import Vulkan
import NucleusSkiaGraphiteBridge

/// Reclaimable 2D rect allocator with free-list coalescing: best-fit on the
/// short axis, split along the axis that leaves the larger leftover strip
/// intact, coalesce adjacent free rects on free.
struct GuillotineAllocator {
    struct Rect: Equatable {
        var x: UInt32
        var y: UInt32
        var w: UInt32
        var h: UInt32
    }

    let pageWidth: UInt32
    let pageHeight: UInt32
    private var freeRects: [Rect]
    private(set) var usedArea: UInt64

    init(width: UInt32, height: UInt32) {
        pageWidth = width
        pageHeight = height
        freeRects = [Rect(x: 0, y: 0, w: width, h: height)]
        usedArea = 0
    }

    mutating func allocate(w: UInt32, h: UInt32) -> (x: UInt32, y: UInt32)? {
        if w == 0 || h == 0 { return nil }
        var bestIdx: Int? = nil
        var bestScore: UInt64 = .max
        for (i, r) in freeRects.enumerated() {
            if w > r.w || h > r.h { continue }
            let score = UInt64(min(r.w - w, r.h - h))
            if score < bestScore {
                bestScore = score
                bestIdx = i
                if score == 0 { break }
            }
        }
        guard let idx = bestIdx else { return nil }
        let chosen = freeRects[idx]
        freeRects.swapAt(idx, freeRects.count - 1)
        freeRects.removeLast()

        let leftoverW = chosen.w - w
        let leftoverH = chosen.h - h
        if leftoverW > leftoverH {
            if leftoverW > 0 {
                freeRects.append(Rect(x: chosen.x + w, y: chosen.y, w: leftoverW, h: chosen.h))
            }
            if leftoverH > 0 {
                freeRects.append(Rect(x: chosen.x, y: chosen.y + h, w: w, h: leftoverH))
            }
        } else {
            if leftoverH > 0 {
                freeRects.append(Rect(x: chosen.x, y: chosen.y + h, w: chosen.w, h: leftoverH))
            }
            if leftoverW > 0 {
                freeRects.append(Rect(x: chosen.x + w, y: chosen.y, w: leftoverW, h: h))
            }
        }
        usedArea += UInt64(w) * UInt64(h)
        return (chosen.x, chosen.y)
    }

    mutating func free(x: UInt32, y: UInt32, w: UInt32, h: UInt32) {
        if w == 0 || h == 0 { return }
        freeRects.append(Rect(x: x, y: y, w: w, h: h))
        let area = UInt64(w) * UInt64(h)
        usedArea = usedArea >= area ? usedArea - area : 0
        coalesce()
    }

    private mutating func coalesce() {
        var changed = true
        while changed {
            changed = false
            var i = 0
            outer: while i < freeRects.count {
                var j = i + 1
                while j < freeRects.count {
                    if GuillotineAllocator.tryMerge(&freeRects[i], freeRects[j]) {
                        freeRects.swapAt(j, freeRects.count - 1)
                        freeRects.removeLast()
                        changed = true
                        break outer
                    }
                    j += 1
                }
                i += 1
            }
        }
    }

    private static func tryMerge(_ a: inout Rect, _ b: Rect) -> Bool {
        // Horizontal merge: same y/h, abutting in x.
        if a.y == b.y && a.h == b.h {
            if a.x + a.w == b.x { a.w += b.w; return true }
            if b.x + b.w == a.x { a.x = b.x; a.w += b.w; return true }
        }
        // Vertical merge: same x/w, abutting in y.
        if a.x == b.x && a.w == b.w {
            if a.y + a.h == b.y { a.h += b.h; return true }
            if b.y + b.h == a.y { a.y = b.y; a.h += b.h; return true }
        }
        return false
    }
}

/// A multi-page atlas over guillotine pages for small paint/decoration nodes.
/// Allocations too large for a page are rejected (the caller falls back to a
/// dedicated texture).
struct TextureAtlas {
    struct Allocation: Equatable {
        var page: Int
        var x: UInt32
        var y: UInt32
        var w: UInt32
        var h: UInt32
    }

    let pageSize: UInt32
    private var pages: [GuillotineAllocator]

    init(pageSize: UInt32) {
        self.pageSize = pageSize
        pages = []
    }

    var pageCount: Int { pages.count }

    mutating func allocate(w: UInt32, h: UInt32) -> Allocation? {
        if w == 0 || h == 0 || w > pageSize || h > pageSize { return nil }
        for i in pages.indices {
            if let p = pages[i].allocate(w: w, h: h) {
                return Allocation(page: i, x: p.x, y: p.y, w: w, h: h)
            }
        }
        var page = GuillotineAllocator(width: pageSize, height: pageSize)
        guard let p = page.allocate(w: w, h: h) else { return nil }
        pages.append(page)
        return Allocation(page: pages.count - 1, x: p.x, y: p.y, w: w, h: h)
    }

    mutating func free(_ a: Allocation) {
        guard a.page < pages.count else { return }
        pages[a.page].free(x: a.x, y: a.y, w: a.w, h: a.h)
    }
}

/// Maps opaque texture handles to sampleable Skia images with content-revision
/// reuse + refcounting. Reference type; one per renderer.
final class TextureRegistry {
    struct Entry {
        var image: nucleus.skia.Image
        var width: Int32
        var height: Int32
        var contentRevision: UInt64
        var refcount: Int
    }

    private var entries: [UInt64: Entry] = [:]
    private var nextHandle: UInt64 = 1  // 0 is the invalid sentinel

    var count: Int { entries.count }

    /// Drop every registered texture. GPU-backed images reference their Graphite
    /// context, so the renderer must `clear()` (or release all handles) before the
    /// context is destroyed — destroying a backend-texture image after its device
    /// is gone faults.
    func clear() { entries.removeAll(keepingCapacity: true) }

    /// Allocate a fresh non-zero handle (u64 wrap, skipping 0).
    func allocHandle() -> UInt64 {
        let h = nextHandle
        nextHandle &+= 1
        if nextHandle == 0 { nextHandle = 1 }
        return h
    }

    /// Register (or replace) `handle`'s texture at `contentRevision`, refcount 1.
    func register(handle: UInt64, image: nucleus.skia.Image, width: Int32, height: Int32, contentRevision: UInt64) {
        entries[handle] = Entry(
            image: image, width: width, height: height,
            contentRevision: contentRevision, refcount: 1)
    }

    /// The image to sample for `handle`, or nil if not registered.
    func resolve(_ handle: UInt64) -> nucleus.skia.Image? { entries[handle]?.image }

    /// The pixel size registered for `handle`.
    func size(_ handle: UInt64) -> (width: Int32, height: Int32)? {
        guard let e = entries[handle] else { return nil }
        return (e.width, e.height)
    }

    /// True when `handle` is unregistered or its content predates `revision` — a
    /// producer uses this to skip re-upload of unchanged content.
    func needsUpdate(_ handle: UInt64, revision: UInt64) -> Bool {
        guard let e = entries[handle] else { return true }
        return e.contentRevision < revision
    }

    func retain(_ handle: UInt64) { entries[handle]?.refcount += 1 }

    /// Decrement the refcount; evict (and return true) at zero.
    @discardableResult
    func release(_ handle: UInt64) -> Bool {
        guard var e = entries[handle] else { return false }
        e.refcount -= 1
        if e.refcount <= 0 {
            entries[handle] = nil
            return true
        }
        entries[handle] = e
        return false
    }

    /// Wrap a borrowed Vulkan image (an imported DMA-BUF / compositor render
    /// texture) as a Graphite-sampleable image. The caller owns the underlying
    /// `VkImage`'s lifetime and must keep it alive while the registry entry lives
    func wrapBackendImage(
        recorder: nucleus.skia.Recorder, descriptor: nucleus.skia.VulkanImageDescriptor
    ) -> nucleus.skia.Image? {
        let image = recorder.wrapBackendImage(descriptor)
        return image.isValid() ? image : nil
    }
}
