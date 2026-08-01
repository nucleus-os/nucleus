package struct CaptureOverlay: Sendable {
    package var rgbaPixels: [UInt8]
    package var width: Int32
    package var height: Int32
    package var x: Int32
    package var y: Int32

    package init(
        rgbaPixels: [UInt8],
        width: Int32,
        height: Int32,
        x: Int32,
        y: Int32
    ) {
        self.rgbaPixels = rgbaPixels
        self.width = width
        self.height = height
        self.x = x
        self.y = y
    }
}
