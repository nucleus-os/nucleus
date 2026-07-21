/// The desktop settings consumed by both Nucleus Linux hosts.
public struct DesktopPortalSettings: Sendable, Equatable {
    public var colorScheme: UInt32?
    public var contrast: UInt32?
    public var reducesMotion: Bool?
    public var animationsEnabled: Bool?
    public var reducesTransparency: Bool?
    public var textScale: Double?

    public init(
        colorScheme: UInt32? = nil,
        contrast: UInt32? = nil,
        reducesMotion: Bool? = nil,
        animationsEnabled: Bool? = nil,
        reducesTransparency: Bool? = nil,
        textScale: Double? = nil
    ) {
        self.colorScheme = colorScheme
        self.contrast = contrast
        self.reducesMotion = reducesMotion
        self.animationsEnabled = animationsEnabled
        self.reducesTransparency = reducesTransparency
        self.textScale = textScale
    }
}

public enum DesktopPortalSettingsEndpoint {
    public static let service = "org.freedesktop.portal.Desktop"
    public static let path = "/org/freedesktop/portal/desktop"
    public static let interface = "org.freedesktop.portal.Settings"
    public static let settingChanged = "SettingChanged"
}

/// One cancellable, concurrent read of the desktop settings snapshot.
///
/// Individual settings are optional by portal contract. A missing key, absent
/// backend, or mismatched type therefore records `nil`; only the connection's
/// event-loop owner decides whether a transport failure requires reconnecting.
@MainActor
public final class DesktopPortalSettingsRequest {
    fileprivate enum UInt32Field {
        case colorScheme
        case contrast
    }

    fileprivate enum BooleanField {
        case reducesMotion
        case animationsEnabled
        case reducesTransparency
    }

    fileprivate enum DoubleField {
        case textScale
        case fallbackTextScale
    }

    private var settings = DesktopPortalSettings()
    private var fallbackTextScale: Double?
    private var remaining = 7
    private var pendingCalls: [SDBusPendingCall] = []
    private var completion:
        (@MainActor (DesktopPortalSettings) -> Void)?

    fileprivate init(
        completion: @escaping @MainActor (DesktopPortalSettings) -> Void
    ) {
        self.completion = completion
    }

    public var isFinished: Bool { completion == nil }

    public func cancel() {
        completion = nil
        remaining = 0
        let calls = pendingCalls
        pendingCalls.removeAll(keepingCapacity: false)
        for call in calls { call.cancel() }
    }

    fileprivate func track(_ call: SDBusPendingCall) {
        guard completion != nil else {
            call.cancel()
            return
        }
        pendingCalls.append(call)
    }

    fileprivate func record(
        _ result: Result<UInt32, DBusError>, field: UInt32Field
    ) {
        guard completion != nil else { return }
        switch field {
        case .colorScheme:
            settings.colorScheme = try? result.get()
        case .contrast:
            settings.contrast = try? result.get()
        }
        finishField()
    }

    fileprivate func record(
        _ result: Result<Bool, DBusError>, field: BooleanField
    ) {
        guard completion != nil else { return }
        switch field {
        case .reducesMotion:
            settings.reducesMotion = try? result.get()
        case .animationsEnabled:
            settings.animationsEnabled = try? result.get()
        case .reducesTransparency:
            settings.reducesTransparency = try? result.get()
        }
        finishField()
    }

    fileprivate func record(
        _ result: Result<Double, DBusError>, field: DoubleField
    ) {
        guard completion != nil else { return }
        switch field {
        case .textScale:
            settings.textScale = try? result.get()
        case .fallbackTextScale:
            fallbackTextScale = try? result.get()
        }
        finishField()
    }

    private func finishField() {
        guard remaining > 0 else { return }
        remaining -= 1
        guard remaining == 0 else { return }
        settings.textScale = settings.textScale ?? fallbackTextScale
        let completion = completion
        self.completion = nil
        pendingCalls.removeAll(keepingCapacity: false)
        completion?(settings)
    }

    isolated deinit {
        cancel()
    }
}

extension DBusConnection {
    /// Queue all settings reads without blocking the caller. The returned token
    /// owns the batch and cancellation; `process()` drives its replies.
    public func readDesktopPortalSettings(
        service: String = DesktopPortalSettingsEndpoint.service,
        path: String = DesktopPortalSettingsEndpoint.path,
        interface: String = DesktopPortalSettingsEndpoint.interface,
        completion: @escaping @MainActor (DesktopPortalSettings) -> Void
    ) throws(DBusError) -> DesktopPortalSettingsRequest {
        guard isOpen else { throw DBusError.closed }
        let request = DesktopPortalSettingsRequest(completion: completion)
        let appearance = "org.freedesktop.appearance"
        let gnome = "org.gnome.desktop.interface"

        func uint32(_ namespace: String, _ key: String,
                    _ field: DesktopPortalSettingsRequest.UInt32Field) {
            do {
                request.track(try portalSettingUInt32Async(
                    service: service, path: path, interface: interface,
                    namespace: namespace, key: key
                ) { [weak request] result in
                    request?.record(result, field: field)
                })
            } catch {
                request.record(
                    Result<UInt32, DBusError>.failure(error), field: field)
            }
        }

        func boolean(_ namespace: String, _ key: String,
                     _ field: DesktopPortalSettingsRequest.BooleanField) {
            do {
                request.track(try portalSettingBoolAsync(
                    service: service, path: path, interface: interface,
                    namespace: namespace, key: key
                ) { [weak request] result in
                    request?.record(result, field: field)
                })
            } catch {
                request.record(
                    Result<Bool, DBusError>.failure(error), field: field)
            }
        }

        func double(_ namespace: String, _ key: String,
                    _ field: DesktopPortalSettingsRequest.DoubleField) {
            do {
                request.track(try portalSettingDoubleAsync(
                    service: service, path: path, interface: interface,
                    namespace: namespace, key: key
                ) { [weak request] result in
                    request?.record(result, field: field)
                })
            } catch {
                request.record(
                    Result<Double, DBusError>.failure(error), field: field)
            }
        }

        uint32(appearance, "color-scheme", .colorScheme)
        uint32(appearance, "contrast", .contrast)
        boolean(appearance, "reduced-motion", .reducesMotion)
        boolean(gnome, "enable-animations", .animationsEnabled)
        boolean(appearance, "reduced-transparency", .reducesTransparency)
        double(appearance, "text-scale", .textScale)
        double(gnome, "text-scaling-factor", .fallbackTextScale)
        return request
    }
}
