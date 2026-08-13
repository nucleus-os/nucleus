import NucleusCompositorInputC

struct TabletDeviceID: Hashable, Comparable {
    let rawValue: UInt64

    init(rawValue: UInt64) {
        precondition(rawValue != 0, "zero is not a valid tablet-device identity")
        self.rawValue = rawValue
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct TabletToolID: Hashable, Comparable {
    let rawValue: UInt64

    init(rawValue: UInt64) {
        precondition(rawValue != 0, "zero is not a valid tablet-tool identity")
        self.rawValue = rawValue
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct TabletDeviceDescriptor: Equatable {
    let id: TabletDeviceID
    let groupID: UInt64
    let name: String
    let vendorID: UInt32
    let productID: UInt32
    let path: String
}

enum TabletToolKind: Equatable {
    case pen
    case eraser
    case brush
    case pencil
    case airbrush
    case finger
    case mouse
    case lens
}

struct TabletToolCapabilities: OptionSet, Equatable {
    let rawValue: UInt8

    static let pressure = Self(rawValue: 1 << 0)
    static let distance = Self(rawValue: 1 << 1)
    static let tilt = Self(rawValue: 1 << 2)
    static let rotation = Self(rawValue: 1 << 3)
    static let slider = Self(rawValue: 1 << 4)
    static let wheel = Self(rawValue: 1 << 5)
}

struct TabletToolDescriptor: Equatable {
    let id: TabletToolID
    let kind: TabletToolKind
    let serial: UInt64
    let hardwareID: UInt64
    let capabilities: TabletToolCapabilities
}

struct TabletAxes: Equatable {
    var x: Double?
    var y: Double?
    var pressure: Double?
    var distance: Double?
    var tiltX: Double?
    var tiltY: Double?
    var rotationDegrees: Double?
    var slider: Double?
    var wheelDegrees: Double?
    var wheelClicks: Int32?

    var isFinite: Bool {
        [x, y, pressure, distance, tiltX, tiltY, rotationDegrees, slider, wheelDegrees]
            .compactMap { $0 }
            .allSatisfy(\.isFinite)
    }
}

struct TabletPadGroupDescriptor: Equatable {
    let index: UInt32
    let modeCount: UInt32
    let buttons: [UInt32]
    let rings: [UInt32]
    let strips: [UInt32]
    let dials: [UInt32]
}

struct TabletPadDescriptor: Equatable {
    let device: TabletDeviceDescriptor
    let buttonCount: UInt32
    let ringCount: UInt32
    let stripCount: UInt32
    let dialCount: UInt32
    let groups: [TabletPadGroupDescriptor]
}

enum TabletPadControlSource: Equatable {
    case finger
    case unknown
}

enum TabletInputSample: Equatable {
    case proximity(
        deviceID: TabletDeviceID,
        tool: TabletToolDescriptor,
        timestampNs: UInt64,
        entered: Bool,
        axes: TabletAxes)
    case axes(
        deviceID: TabletDeviceID,
        toolID: TabletToolID,
        timestampNs: UInt64,
        axes: TabletAxes)
    case tip(
        deviceID: TabletDeviceID,
        toolID: TabletToolID,
        timestampNs: UInt64,
        down: Bool,
        axes: TabletAxes)
    case toolButton(
        deviceID: TabletDeviceID,
        toolID: TabletToolID,
        timestampNs: UInt64,
        button: UInt32,
        down: Bool,
        axes: TabletAxes)
    case padButton(
        deviceID: TabletDeviceID,
        timestampNs: UInt64,
        button: UInt32,
        down: Bool,
        group: UInt32,
        mode: UInt32)
    case padRing(
        deviceID: TabletDeviceID,
        timestampNs: UInt64,
        ring: UInt32,
        positionDegrees: Double?,
        source: TabletPadControlSource,
        group: UInt32,
        mode: UInt32)
    case padStrip(
        deviceID: TabletDeviceID,
        timestampNs: UInt64,
        strip: UInt32,
        position: Double?,
        source: TabletPadControlSource,
        group: UInt32,
        mode: UInt32)
    case padDial(
        deviceID: TabletDeviceID,
        timestampNs: UInt64,
        dial: UInt32,
        deltaV120: Int32,
        group: UInt32,
        mode: UInt32)
}

enum NormalizedTabletEvent: Equatable {
    case proximityIn(
        deviceID: TabletDeviceID,
        tool: TabletToolDescriptor,
        timestampNs: UInt64,
        axes: TabletAxes)
    case axes(
        deviceID: TabletDeviceID,
        toolID: TabletToolID,
        timestampNs: UInt64,
        axes: TabletAxes)
    case tip(
        deviceID: TabletDeviceID,
        toolID: TabletToolID,
        timestampNs: UInt64,
        down: Bool,
        axes: TabletAxes)
    case toolButton(
        deviceID: TabletDeviceID,
        toolID: TabletToolID,
        timestampNs: UInt64,
        button: UInt32,
        down: Bool,
        axes: TabletAxes)
    case proximityOut(
        deviceID: TabletDeviceID,
        toolID: TabletToolID,
        timestampNs: UInt64)
    case padButton(
        deviceID: TabletDeviceID,
        timestampNs: UInt64,
        button: UInt32,
        down: Bool,
        group: UInt32,
        mode: UInt32)
    case padRing(
        deviceID: TabletDeviceID,
        timestampNs: UInt64,
        ring: UInt32,
        positionDegrees: Double?,
        source: TabletPadControlSource,
        group: UInt32,
        mode: UInt32)
    case padStrip(
        deviceID: TabletDeviceID,
        timestampNs: UInt64,
        strip: UInt32,
        position: Double?,
        source: TabletPadControlSource,
        group: UInt32,
        mode: UInt32)
    case padDial(
        deviceID: TabletDeviceID,
        timestampNs: UInt64,
        dial: UInt32,
        deltaV120: Int32,
        group: UInt32,
        mode: UInt32)
}

struct TabletCoordinateSpace {
    let x: Double
    let y: Double
    let width: UInt32
    let height: UInt32
}

struct TabletSequenceNormalizer {
    private struct ActiveTool {
        let deviceID: TabletDeviceID
        let descriptor: TabletToolDescriptor
        var tipDown: Bool
        var lastTimestampNs: UInt64
    }

    private var activeTools: [TabletToolID: ActiveTool] = [:]

    mutating func normalize(_ sample: TabletInputSample) -> [NormalizedTabletEvent] {
        switch sample {
        case .proximity(let deviceID, let tool, let timestampNs, let entered, let axes):
            guard axes.isFinite else { return cancel(tool.id, at: timestampNs) }
            if entered {
                var events = cancel(tool.id, at: timestampNs)
                activeTools[tool.id] = ActiveTool(
                    deviceID: deviceID,
                    descriptor: tool,
                    tipDown: false,
                    lastTimestampNs: timestampNs)
                events.append(
                    .proximityIn(
                        deviceID: deviceID,
                        tool: tool,
                        timestampNs: timestampNs,
                        axes: axes))
                return events
            }
            guard let active = activeTools[tool.id], active.deviceID == deviceID,
                timestampNs >= active.lastTimestampNs
            else { return cancel(tool.id, at: timestampNs) }
            return cancel(tool.id, at: timestampNs)

        case .axes(let deviceID, let toolID, let timestampNs, let axes):
            guard axes.isFinite,
                update(toolID, deviceID: deviceID, timestampNs: timestampNs) != nil
            else { return cancel(toolID, at: timestampNs) }
            return [
                .axes(
                    deviceID: deviceID, toolID: toolID,
                    timestampNs: timestampNs, axes: axes)
            ]

        case .tip(let deviceID, let toolID, let timestampNs, let down, let axes):
            guard axes.isFinite,
                var active = update(toolID, deviceID: deviceID, timestampNs: timestampNs),
                active.tipDown != down
            else { return cancel(toolID, at: timestampNs) }
            active.tipDown = down
            activeTools[toolID] = active
            return [
                .tip(
                    deviceID: deviceID, toolID: toolID,
                    timestampNs: timestampNs, down: down, axes: axes)
            ]

        case .toolButton(
            let deviceID, let toolID, let timestampNs, let button, let down, let axes):
            guard axes.isFinite,
                update(toolID, deviceID: deviceID, timestampNs: timestampNs) != nil
            else { return cancel(toolID, at: timestampNs) }
            return [
                .toolButton(
                    deviceID: deviceID, toolID: toolID,
                    timestampNs: timestampNs, button: button, down: down, axes: axes)
            ]

        case .padButton(
            let deviceID, let timestampNs, let button, let down, let group, let mode):
            return [
                .padButton(
                    deviceID: deviceID, timestampNs: timestampNs,
                    button: button, down: down, group: group, mode: mode)
            ]
        case .padRing(
            let deviceID, let timestampNs, let ring, let positionDegrees, let source,
            let group, let mode):
            guard positionDegrees?.isFinite != false else { return [] }
            return [
                .padRing(
                    deviceID: deviceID, timestampNs: timestampNs, ring: ring,
                    positionDegrees: positionDegrees, source: source, group: group, mode: mode)
            ]
        case .padStrip(
            let deviceID, let timestampNs, let strip, let position, let source,
            let group, let mode):
            guard position?.isFinite != false else { return [] }
            return [
                .padStrip(
                    deviceID: deviceID, timestampNs: timestampNs, strip: strip,
                    position: position, source: source, group: group, mode: mode)
            ]
        case .padDial(
            let deviceID, let timestampNs, let dial, let deltaV120, let group, let mode):
            return [
                .padDial(
                    deviceID: deviceID, timestampNs: timestampNs, dial: dial,
                    deltaV120: deltaV120, group: group, mode: mode)
            ]
        }
    }

    mutating func deviceRemoved(_ deviceID: TabletDeviceID) -> [NormalizedTabletEvent] {
        activeTools.values
            .filter { $0.deviceID == deviceID }
            .map(\.descriptor.id)
            .sorted()
            .flatMap { cancel($0, at: nil) }
    }

    mutating func cancelAll() -> [NormalizedTabletEvent] {
        activeTools.keys.sorted().flatMap { cancel($0, at: nil) }
    }

    private mutating func update(
        _ toolID: TabletToolID,
        deviceID: TabletDeviceID,
        timestampNs: UInt64
    ) -> ActiveTool? {
        guard var active = activeTools[toolID], active.deviceID == deviceID,
            timestampNs >= active.lastTimestampNs
        else { return nil }
        active.lastTimestampNs = timestampNs
        activeTools[toolID] = active
        return active
    }

    private mutating func cancel(
        _ toolID: TabletToolID,
        at timestampNs: UInt64?
    ) -> [NormalizedTabletEvent] {
        guard let active = activeTools.removeValue(forKey: toolID) else { return [] }
        let time = max(timestampNs ?? active.lastTimestampNs, active.lastTimestampNs)
        var events: [NormalizedTabletEvent] = []
        if active.tipDown {
            events.append(
                .tip(
                    deviceID: active.deviceID, toolID: toolID,
                    timestampNs: time, down: false, axes: TabletAxes()))
        }
        events.append(
            .proximityOut(
                deviceID: active.deviceID, toolID: toolID, timestampNs: time))
        return events
    }
}

enum InputTabletNormalize {
    @unsafe static func deviceDescriptor(
        _ device: OpaquePointer
    ) -> TabletDeviceDescriptor {
        let id = unsafe pointerIdentity(device)
        let group = unsafe libinput_device_get_device_group(device)
        let groupID = unsafe pointerIdentity(group) ?? id
        let sysname = unsafe String(cString: libinput_device_get_sysname(device))
        return TabletDeviceDescriptor(
            id: TabletDeviceID(rawValue: id),
            groupID: groupID,
            name: unsafe String(cString: libinput_device_get_name(device)),
            vendorID: unsafe libinput_device_get_id_vendor(device),
            productID: unsafe libinput_device_get_id_product(device),
            path: "/dev/input/\(sysname)")
    }

    @unsafe static func padDescriptor(_ device: OpaquePointer) -> TabletPadDescriptor {
        let descriptor = unsafe deviceDescriptor(device)
        let buttonCount = UInt32(max(0, unsafe libinput_device_tablet_pad_get_num_buttons(device)))
        let ringCount = UInt32(max(0, unsafe libinput_device_tablet_pad_get_num_rings(device)))
        let stripCount = UInt32(max(0, unsafe libinput_device_tablet_pad_get_num_strips(device)))
        let dialCount: UInt32 = 0
        let groupCount = max(0, unsafe libinput_device_tablet_pad_get_num_mode_groups(device))
        var groups: [TabletPadGroupDescriptor] = []
        for index in 0..<groupCount {
            guard
                let group = unsafe libinput_device_tablet_pad_get_mode_group(
                    device, UInt32(index))
            else { continue }
            groups.append(
                TabletPadGroupDescriptor(
                    index: UInt32(index),
                    modeCount: unsafe libinput_tablet_pad_mode_group_get_num_modes(group),
                    buttons: (0..<buttonCount).filter {
                        unsafe libinput_tablet_pad_mode_group_has_button(group, $0) != 0
                    },
                    rings: (0..<ringCount).filter {
                        unsafe libinput_tablet_pad_mode_group_has_ring(group, $0) != 0
                    },
                    strips: (0..<stripCount).filter {
                        unsafe libinput_tablet_pad_mode_group_has_strip(group, $0) != 0
                    },
                    dials: []))
        }
        return TabletPadDescriptor(
            device: descriptor, buttonCount: buttonCount, ringCount: ringCount,
            stripCount: stripCount, dialCount: dialCount, groups: groups)
    }

    @unsafe static func translate(
        _ event: OpaquePointer,
        coordinateSpace: TabletCoordinateSpace?
    ) -> TabletInputSample? {
        let type = unsafe libinput_event_get_type(event)
        guard let device = unsafe libinput_event_get_device(event) else { return nil }
        let deviceID = unsafe deviceDescriptor(device).id

        switch type {
        case LIBINPUT_EVENT_TABLET_TOOL_AXIS,
            LIBINPUT_EVENT_TABLET_TOOL_PROXIMITY,
            LIBINPUT_EVENT_TABLET_TOOL_TIP,
            LIBINPUT_EVENT_TABLET_TOOL_BUTTON:
            guard let toolEvent = unsafe libinput_event_get_tablet_tool_event(event),
                let tool = unsafe libinput_event_tablet_tool_get_tool(toolEvent)
            else { return nil }
            let toolID = TabletToolID(rawValue: unsafe pointerIdentity(tool))
            let time = unsafe libinput_event_tablet_tool_get_time_usec(toolEvent) &* 1_000
            let axes = unsafe axes(toolEvent, coordinateSpace: coordinateSpace)
            switch type {
            case LIBINPUT_EVENT_TABLET_TOOL_PROXIMITY:
                return unsafe .proximity(
                    deviceID: deviceID,
                    tool: toolDescriptor(tool, id: toolID),
                    timestampNs: time,
                    entered: libinput_event_tablet_tool_get_proximity_state(toolEvent)
                        == LIBINPUT_TABLET_TOOL_PROXIMITY_STATE_IN,
                    axes: axes)
            case LIBINPUT_EVENT_TABLET_TOOL_AXIS:
                return .axes(
                    deviceID: deviceID, toolID: toolID,
                    timestampNs: time, axes: axes)
            case LIBINPUT_EVENT_TABLET_TOOL_TIP:
                return unsafe .tip(
                    deviceID: deviceID, toolID: toolID, timestampNs: time,
                    down: libinput_event_tablet_tool_get_tip_state(toolEvent)
                        == LIBINPUT_TABLET_TOOL_TIP_DOWN,
                    axes: axes)
            default:
                return unsafe .toolButton(
                    deviceID: deviceID, toolID: toolID, timestampNs: time,
                    button: libinput_event_tablet_tool_get_button(toolEvent),
                    down: libinput_event_tablet_tool_get_button_state(toolEvent)
                        == LIBINPUT_BUTTON_STATE_PRESSED,
                    axes: axes)
            }

        case LIBINPUT_EVENT_TABLET_PAD_BUTTON,
            LIBINPUT_EVENT_TABLET_PAD_RING,
            LIBINPUT_EVENT_TABLET_PAD_STRIP:
            guard let pad = unsafe libinput_event_get_tablet_pad_event(event) else { return nil }
            let time = unsafe libinput_event_tablet_pad_get_time_usec(pad) &* 1_000
            let mode = unsafe libinput_event_tablet_pad_get_mode(pad)
            let group = unsafe libinput_event_tablet_pad_get_mode_group(pad)
            let groupIndex = unsafe modeGroupIndex(group) ?? 0
            switch type {
            case LIBINPUT_EVENT_TABLET_PAD_BUTTON:
                return unsafe .padButton(
                    deviceID: deviceID, timestampNs: time,
                    button: libinput_event_tablet_pad_get_button_number(pad),
                    down: libinput_event_tablet_pad_get_button_state(pad)
                        == LIBINPUT_BUTTON_STATE_PRESSED,
                    group: groupIndex, mode: mode)
            case LIBINPUT_EVENT_TABLET_PAD_RING:
                let position = unsafe libinput_event_tablet_pad_get_ring_position(pad)
                return unsafe .padRing(
                    deviceID: deviceID, timestampNs: time,
                    ring: libinput_event_tablet_pad_get_ring_number(pad),
                    positionDegrees: position < 0 ? nil : position,
                    source: padSource(libinput_event_tablet_pad_get_ring_source(pad)),
                    group: groupIndex, mode: mode)
            case LIBINPUT_EVENT_TABLET_PAD_STRIP:
                let position = unsafe libinput_event_tablet_pad_get_strip_position(pad)
                return unsafe .padStrip(
                    deviceID: deviceID, timestampNs: time,
                    strip: libinput_event_tablet_pad_get_strip_number(pad),
                    position: position < 0 ? nil : position,
                    source: padSource(libinput_event_tablet_pad_get_strip_source(pad)),
                    group: groupIndex, mode: mode)
            default:
                return nil
            }
        default:
            return nil
        }
    }

    @unsafe private static func toolDescriptor(
        _ tool: OpaquePointer,
        id: TabletToolID
    ) -> TabletToolDescriptor {
        var capabilities: TabletToolCapabilities = []
        if unsafe libinput_tablet_tool_has_pressure(tool) != 0 { capabilities.insert(.pressure) }
        if unsafe libinput_tablet_tool_has_distance(tool) != 0 { capabilities.insert(.distance) }
        if unsafe libinput_tablet_tool_has_tilt(tool) != 0 { capabilities.insert(.tilt) }
        if unsafe libinput_tablet_tool_has_rotation(tool) != 0 { capabilities.insert(.rotation) }
        if unsafe libinput_tablet_tool_has_slider(tool) != 0 { capabilities.insert(.slider) }
        if unsafe libinput_tablet_tool_has_wheel(tool) != 0 { capabilities.insert(.wheel) }
        return unsafe TabletToolDescriptor(
            id: id,
            kind: toolKind(libinput_tablet_tool_get_type(tool)),
            serial: libinput_tablet_tool_get_serial(tool),
            hardwareID: libinput_tablet_tool_get_tool_id(tool),
            capabilities: capabilities)
    }

    @unsafe private static func axes(
        _ event: OpaquePointer,
        coordinateSpace: TabletCoordinateSpace?
    ) -> TabletAxes {
        var result = TabletAxes()
        if unsafe libinput_event_tablet_tool_x_has_changed(event) != 0,
            let coordinateSpace
        {
            result.x =
                unsafe coordinateSpace.x
                + libinput_event_tablet_tool_get_x_transformed(event, coordinateSpace.width)
        }
        if unsafe libinput_event_tablet_tool_y_has_changed(event) != 0,
            let coordinateSpace
        {
            result.y =
                unsafe coordinateSpace.y
                + libinput_event_tablet_tool_get_y_transformed(event, coordinateSpace.height)
        }
        if unsafe libinput_event_tablet_tool_pressure_has_changed(event) != 0 {
            result.pressure = unsafe libinput_event_tablet_tool_get_pressure(event)
        }
        if unsafe libinput_event_tablet_tool_distance_has_changed(event) != 0 {
            result.distance = unsafe libinput_event_tablet_tool_get_distance(event)
        }
        if unsafe libinput_event_tablet_tool_tilt_x_has_changed(event) != 0 {
            result.tiltX = unsafe libinput_event_tablet_tool_get_tilt_x(event)
        }
        if unsafe libinput_event_tablet_tool_tilt_y_has_changed(event) != 0 {
            result.tiltY = unsafe libinput_event_tablet_tool_get_tilt_y(event)
        }
        if unsafe libinput_event_tablet_tool_rotation_has_changed(event) != 0 {
            result.rotationDegrees = unsafe libinput_event_tablet_tool_get_rotation(event)
        }
        if unsafe libinput_event_tablet_tool_slider_has_changed(event) != 0 {
            result.slider = unsafe libinput_event_tablet_tool_get_slider_position(event)
        }
        if unsafe libinput_event_tablet_tool_wheel_has_changed(event) != 0 {
            result.wheelDegrees = unsafe libinput_event_tablet_tool_get_wheel_delta(event)
            result.wheelClicks = unsafe Int32(
                libinput_event_tablet_tool_get_wheel_delta_discrete(event))
        }
        return result
    }

    @unsafe private static func pointerIdentity(_ pointer: OpaquePointer) -> UInt64 {
        unsafe UInt64(UInt(bitPattern: UnsafeRawPointer(pointer)))
    }

    @unsafe private static func pointerIdentity(_ pointer: OpaquePointer?) -> UInt64? {
        guard let pointer = unsafe pointer else { return nil }
        return unsafe pointerIdentity(pointer)
    }

    @unsafe private static func modeGroupIndex(
        _ group: OpaquePointer?
    ) -> UInt32? {
        guard let group = unsafe group else { return nil }
        return unsafe libinput_tablet_pad_mode_group_get_index(group)
    }

    @unsafe private static func toolKind(_ kind: libinput_tablet_tool_type) -> TabletToolKind {
        switch kind {
        case LIBINPUT_TABLET_TOOL_TYPE_ERASER: return .eraser
        case LIBINPUT_TABLET_TOOL_TYPE_BRUSH: return .brush
        case LIBINPUT_TABLET_TOOL_TYPE_PENCIL: return .pencil
        case LIBINPUT_TABLET_TOOL_TYPE_AIRBRUSH: return .airbrush
        case LIBINPUT_TABLET_TOOL_TYPE_MOUSE: return .mouse
        case LIBINPUT_TABLET_TOOL_TYPE_LENS: return .lens
        default: return .pen
        }
    }

    private static func padSource(_ source: libinput_tablet_pad_ring_axis_source)
        -> TabletPadControlSource
    {
        source == LIBINPUT_TABLET_PAD_RING_SOURCE_FINGER ? .finger : .unknown
    }

    private static func padSource(_ source: libinput_tablet_pad_strip_axis_source)
        -> TabletPadControlSource
    {
        source == LIBINPUT_TABLET_PAD_STRIP_SOURCE_FINGER ? .finger : .unknown
    }
}
