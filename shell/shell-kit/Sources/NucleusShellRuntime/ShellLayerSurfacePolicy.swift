@_spi(NucleusWindowClientImplementation)
import NucleusWindowClientWayland

extension NucleusDesktopLayerSurfaceConfiguration {
    static func shellBar(
        height: UInt32,
        namespace: String
    ) -> NucleusDesktopLayerSurfaceConfiguration {
        NucleusDesktopLayerSurfaceConfiguration(
            layer: .top,
            anchor: [.top, .left, .right],
            width: 0,
            height: height,
            exclusiveZone: Int32(height),
            keyboard: .none,
            namespace: namespace)
    }

    static func shellWallpaper(
        namespace: String
    ) -> NucleusDesktopLayerSurfaceConfiguration {
        NucleusDesktopLayerSurfaceConfiguration(
            layer: .background,
            anchor: .all,
            width: 0,
            height: 0,
            exclusiveZone: -1,
            keyboard: .none,
            namespace: namespace)
    }

    static func shellFeedback(
        width: UInt32,
        height: UInt32,
        marginTop: Int32,
        marginLeft: Int32,
        namespace: String
    ) -> NucleusDesktopLayerSurfaceConfiguration {
        NucleusDesktopLayerSurfaceConfiguration(
            layer: .overlay,
            anchor: [.top, .left],
            width: width,
            height: height,
            exclusiveZone: -1,
            keyboard: .onDemand,
            namespace: namespace,
            marginTop: marginTop,
            marginLeft: marginLeft)
    }

    static func shellNotifications(
        width: UInt32,
        height: UInt32,
        namespace: String
    ) -> NucleusDesktopLayerSurfaceConfiguration {
        NucleusDesktopLayerSurfaceConfiguration(
            layer: .overlay,
            anchor: [.top, .right],
            width: width,
            height: height,
            exclusiveZone: -1,
            keyboard: .onDemand,
            namespace: namespace,
            marginTop: 16,
            marginRight: 16)
    }
}
