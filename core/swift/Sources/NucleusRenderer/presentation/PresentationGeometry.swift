// The shared output/target geometry value types the presentation pipeline reads
// and the FramePlan carries: `DisplayID`, `PhysicalRect`,
// `LogicalRect`, `PixelSize` — no protocol or backend dependency. Nothing
// throughout the live presentation path.

/// Stable per-output identity. Mirrors `Display.DisplayID` (`u64`).
typealias DisplayID = UInt64

import NucleusTypes

typealias PhysicalRect = OutputPixelRect
typealias LogicalRect = GlobalLogicalRect
typealias PixelSize = OutputPixelSize

/// Output-local usable area (signed origin + signed extent). Mirrors
/// `Display.UsableArea`.
struct UsableArea: Equatable {
    var x: Int32 = 0
    var y: Int32 = 0
    var w: Int32 = 0
    var h: Int32 = 0
}
