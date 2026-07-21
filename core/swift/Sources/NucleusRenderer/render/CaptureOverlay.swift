@_spi(NucleusPlatform)
public struct CaptureOverlay: Sendable {
    public var rgbaPixels: [UInt8]
    public var width: Int32
    public var height: Int32
    public var x: Int32
    public var y: Int32

    public init(
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
