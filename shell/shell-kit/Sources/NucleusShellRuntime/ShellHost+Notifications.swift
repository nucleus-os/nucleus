import NucleusShellProduct
import NucleusShellServices
@_spi(NucleusWindowClientImplementation)
import NucleusWindowClientWayland
import NucleusUI
import NucleusUIEmbedder

@MainActor
struct NativeNotificationSurface {
    let layerSurface: NucleusDesktopLayerSurface
    let surfaceID: UInt
    let outputID: UInt32
    let logicalOrigin: Point
}

@MainActor
extension ShellHost {
    func reconcileNotificationSurface(
        _ notifications: [ShellNotification]
    ) {
        destroyNotificationSurface()
        guard !notifications.isEmpty,
              let output = client.outputs.values.sorted(by: {
                  $0.registryName < $1.registryName
              }).first,
              let nativePublicationContext,
              let surfaceRegistry
        else { return }
        let width: UInt32 = 380
        let height = UInt32(min(
            720,
            max(112, notifications.count * 120)))
        let (view, window) = nativePublicationContext
            .withSemanticContext {
                let view = ShellNotificationListView()
                view.update(notifications.map {
                    ShellNoticeContent(
                        id: $0.id,
                        title: $0.applicationName.isEmpty
                            ? $0.summary
                            : "\($0.applicationName): \($0.summary)",
                        body: $0.body)
                })
                view.onDismiss = { [weak self] id in
                    self?.notifications.dismiss(id: id)
                }
                let window = Window(
                    title: "Nucleus Notifications",
                    role: .layer,
                    level: .criticalOverlay)
                window.setContentView(view)
                return (view, window)
            }
        _ = view
        guard let layerSurface = NucleusDesktopLayerSurface(
            client: client,
            config: .shellNotifications(
                width: width,
                height: height,
                namespace: "nucleus-shell.notifications"),
            output: output)
        else { return }
        let surfaceID = surfaceRegistry.register(
            window: window,
            waylandSurface: layerSurface.wlSurface,
            refreshMillihertz: output.refreshMillihertz)
        let origin = Point(
            x: Double(
                output.logicalX
                    + max(0, output.logicalWidth - Int32(width) - 16)),
            y: Double(output.logicalY + 16))
        notificationSurface = NativeNotificationSurface(
            layerSurface: layerSurface,
            surfaceID: surfaceID,
            outputID: output.registryName,
            logicalOrigin: origin)
        layerSurface.onConfigure = { [weak self] configuredWidth,
            configuredHeight in
            guard let self,
                  let record = notificationSurface,
                  let output = client.outputs[record.outputID]
            else { return }
            _ = surfaceRegistry.configure(
                surfaceID: record.surfaceID,
                logicalOrigin: record.logicalOrigin,
                logicalWidth: Double(
                    configuredWidth == 0 ? width : configuredWidth),
                logicalHeight: Double(
                    configuredHeight == 0 ? height : configuredHeight),
                scale: Double(max(1, output.scale)),
                refreshMillihertz: output.refreshMillihertz)
        }
        layerSurface.onClosed = { [weak self] in
            self?.destroyNotificationSurface()
        }
        _ = client.flush()
    }

    func destroyNotificationSurface() {
        guard let record = notificationSurface else { return }
        notificationSurface = nil
        surfaceRegistry?.unregister(surfaceID: record.surfaceID)
        record.layerSurface.destroy()
    }
}
